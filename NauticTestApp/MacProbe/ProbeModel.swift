#if os(macOS)
import AppKit
import Foundation
import IOKit
import IOKit.hid
import Observation
import os

struct ProbeEvent: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let text: String
}

@MainActor
@Observable
final class ProbeModel {
    var environment: EnvironmentInfo?
    var serial = SerialScan()
    var devListing = DevListing()
    var libdcIteration: LibDCSerialIteration?
    var builtInDrivers: [DriverTable] = []
    var serialResults: [String: SerialOpenResult] = [:]
    var serialIdentify: [String: SerialIdentifyResult] = [:]
    var identifyTargets: [SerialIdentifyTarget]
    var identifyTarget: SerialIdentifyTarget?
    var identifyFilter = ""
    var usb = USBScan()
    var usbResults: [UInt64: [ProbeStep]] = [:]
    var usbSecondRuns: [UInt64: [ProbeStep]] = [:]
    var hidDevices: [HIDDeviceInfo] = []
    var hidResults: [UInt64: [HIDOpenResult]] = [:]
    var inputMonitoringAtLaunch = "not checked"
    var inputMonitoringAfterHID: String?
    var ble = BLEScanResult()
    var garmin: GarminResult?
    var savedBookmarkResolve: (step: ProbeStep, listing: FITListing?)?
    var hasSavedBookmark = GarminProbe.hasSavedBookmark
    var hotplugErrors: [String] = []
    var events: [ProbeEvent] = []
    var busy: Set<String> = []
    var lastCopied: Date?

    // Everything ever enumerated, so the report can scrub events about ports that have since gone.
    @ObservationIgnored private(set) var seenUSBSerials: Set<String> = []
    @ObservationIgnored private(set) var seenSPPNames: Set<String> = []

    @ObservationIgnored private var notifier: IOKitNotifier?
    @ObservationIgnored private var hidWatcher: HIDWatcher?
    @ObservationIgnored private let bleScanner = BLEScanner()
    @ObservationIgnored private var started = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.deepsealabs.DCTesterMac", category: "probe")

    var cobaltDevices: [USBDeviceInfo] { usb.devices.filter(\.isAtomicCobalt) }
    var bridgeDevices: [USBDeviceInfo] { usb.devices.filter(\.isSerialBridge) }
    var cableCoverage: [CableCoverage] { SerialProbe.coverage(builtInDrivers) }
    var report: String { ProbeReport.markdown(self) }

    // The selection stays listed so the picker never loses its tag.
    var shownIdentifyTargets: [SerialIdentifyTarget] {
        let query = identifyFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return identifyTargets }
        let shown = identifyTargets.filter { $0.matches(query) }
        guard let identifyTarget, !shown.contains(identifyTarget) else { return shown }
        return [identifyTarget] + shown
    }

    // Loaded here, not in start(), so the picker's first render already has a tagged selection.
    init() {
        let targets = SerialProbe.identifyTargets()
        identifyTargets = targets
        identifyTarget = targets.first { $0.name == SerialIdentifyTarget.defaultName } ?? targets.first
    }

    func start() {
        guard !started else { return }
        started = true
        environment = EnvironmentProbe.collect()
        inputMonitoringAtLaunch = HIDProbe.inputMonitoringAccess()
        builtInDrivers = SerialProbe.builtInDrivers()
        if let environment {
            log("launch: macOS \(environment.osVersion), \(environment.archSummary), sandboxed \(environment.sandboxed)")
        }
        log("Input Monitoring at launch: \(inputMonitoringAtLaunch)")
        log("identify picker: \(identifyTargets.count) libdc descriptors with a serial transport")
        bleScanner.onUpdate = { [weak self] result in
            MainActor.assumeIsolated { self?.ble = result }
        }
        startHotplug()
        startHID()
        refresh()

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--autorun") {
            Task {
                // HID matching callbacks land asynchronously after activation.
                try? await Task.sleep(for: .seconds(1))
                await runAllOpenTests(identify: arguments.contains("--identify"))
                if arguments.contains("--ble") { await scanBLEToEnd() }
                print(report)
                fflush(stdout)
                exit(0)
            }
        }
    }

    func refresh() {
        serial = SerialProbe.enumerate()
        devListing = SerialProbe.listDev()
        libdcIteration = SerialProbe.libdcIterator()
        usb = USBProbe.enumerate()
        hidDevices = hidWatcher?.snapshot().sorted { $0.id < $1.id } ?? []
        remember()
        let ports = serial.ports.map { "\($0.calloutPath) [\($0.kind.rawValue)]" }.joined(separator: ", ")
        log("enumerated: serial \(serial.ports.count) (\(ports)), USB \(usb.devices.count), HID \(hidDevices.count)")
        if let error = serial.error { log("serial enumeration error: \(error)") }
        if let error = usb.error { log("USB enumeration error: \(error)") }
        for device in usb.devices where device.driverMissing {
            log("driverMissing: \(device.displayName) has no IOSerialBSDClient")
        }
    }

    private func remember() {
        for port in serial.ports {
            if let serial = port.usbSerial { seenUSBSerials.insert(serial) }
            if port.kind == .bluetoothSPP { seenSPPNames.insert(port.baseName) }
        }
        seenUSBSerials.formUnion(usb.devices.compactMap(\.serial))
        seenUSBSerials.formUnion(hidDevices.compactMap(\.serial))
    }

    private func startHotplug() {
        let notifier = IOKitNotifier()
        let serialError = notifier.watch(className: kIOSerialBSDServiceValue) { [weak self] event, service in
            let path = SerialProbe.calloutPath(of: service) ?? "?"
            MainActor.assumeIsolated { self?.hotplug("serial \(event == .added ? "added" : "removed") \(path)") }
        }
        let usbError = notifier.watch(className: kIOUSBHostDeviceClassName) { [weak self] event, service in
            let vidPid = ProbeText.vidPid(Registry.int(service, kUSBVendorID), Registry.int(service, kUSBProductID))
            let name = Registry.string(service, kUSBProductString, "kUSBProductString") ?? ""
            MainActor.assumeIsolated {
                self?.hotplug("USB \(event == .added ? "added" : "removed") \(vidPid) \(name)")
                // Serial drivers attach after the device appears; recheck so driverMissing settles.
                if event == .added {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
                }
            }
        }
        hotplugErrors = [serialError, usbError].compactMap { $0 }
        hotplugErrors.forEach { log("hot-plug setup failed: \($0)") }
        self.notifier = notifier
    }

    private func startHID() {
        hidWatcher = HIDWatcher { [weak self] device, matched in
            let info = HIDDeviceInfo(device)
            MainActor.assumeIsolated {
                guard let self else { return }
                if matched {
                    self.hidDevices.removeAll { $0.id == info.id }
                    self.hidDevices.append(info)
                    self.hidDevices.sort { $0.id < $1.id }
                    if let serial = info.serial { self.seenUSBSerials.insert(serial) }
                } else {
                    self.hidDevices.removeAll { $0.id == info.id }
                }
                self.log("HID \(matched ? "matched" : "removed") \(info.displayName), \(info.usageSummary)")
            }
        }
    }

    private func hotplug(_ text: String) {
        log(text)
        refresh()
    }

    func testSerial(_ port: SerialPort) async {
        let key = "serial:\(port.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        let path = port.calloutPath
        let kind = port.kind
        let result = await Task.detached { SerialProbe.openTest(path: path, kind: kind) }.value
        serialResults[port.id] = result
        log("serial open \(path): \(result.steps.firstFailure?.line ?? "ok")")
    }

    func identifySerial(_ port: SerialPort) async {
        let key = "serial:\(port.id)"
        guard !busy.contains(key), let target = identifyTarget else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        let path = port.calloutPath
        let steps = await Task.detached { SerialProbe.identify(path: path, target: target) }.value
        serialIdentify[port.id] = SerialIdentifyResult(target: target, steps: steps)
        log("serial identify \(path) as \(target.title): \(steps.firstFailure?.line ?? "ok")")
    }

    func testHID(_ device: HIDDeviceInfo, identify: Bool) async {
        let key = "hid:\(device.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        let family = identify ? device.identify : nil
        guard !identify || family != nil else { return }
        for mode in HIDOpenMode.allCases {
            let result = await HIDProbe.openTest(registryID: device.id, mode: mode, identify: family)
            var results = hidResults[device.id] ?? []
            results.removeAll { $0.mode == mode && ($0.identify != nil) == identify }
            results.append(result)
            hidResults[device.id] = results
            inputMonitoringAfterHID = result.inputMonitoring
            log("HID \(identify ? "identify" : "open") \(device.displayName) \(mode.rawValue): \(result.steps.firstFailure?.line ?? result.readSummary)")
        }
    }

    func testUSB(_ device: USBDeviceInfo) async {
        let key = "usb:\(device.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        let id = device.id
        let cobalt = device.isAtomicCobalt
        let steps = await Task.detached { USBProbe.plugInTest(registryID: id, expectCobaltPipes: cobalt) }.value
        usbResults[id] = steps
        usbSecondRuns[id] = nil
        log("USB plug-in \(device.displayName): \(steps.firstFailure?.line ?? "ok")")

        // Interfaces a SetConfiguration creates, and their drivers, attach later and raise no notification.
        try? await Task.sleep(for: .seconds(2))
        refresh()
        guard steps.contains(where: { $0.name == "SetConfiguration" && $0.outcome != .skipped }) else { return }
        let second = await Task.detached { USBProbe.plugInTest(registryID: id, expectCobaltPipes: cobalt) }.value
        usbSecondRuns[id] = second
        log("USB plug-in second run (configured) \(device.displayName): \(second.firstFailure?.line ?? "ok")")
    }

    /// Opens known cable bridges, Bluetooth SPP, system ports and known dive-computer HID devices; no raw USB device but a Cobalt.
    func runAllOpenTests(identify: Bool = false) async {
        guard !busy.contains("all") else { return }
        busy.insert("all")
        defer { busy.remove("all") }
        refresh()
        log("run all open tests" + (identify ? " with HID identify" : ""))
        for port in serial.ports {
            if port.autoTestable {
                await testSerial(port)
            } else {
                log("skipped auto open of \(port.calloutPath): not a known dive-cable bridge, use its Open test button")
            }
        }
        for device in hidDevices {
            if let reason = device.autoSkipReason {
                log("skipped auto open of HID \(device.displayName): \(reason), use its Open test button")
                continue
            }
            await testHID(device, identify: false)
            if identify, device.identify != nil { await testHID(device, identify: true) }
        }
        for device in cobaltDevices { await testUSB(device) }
    }

    func startBLEScan() {
        log("BLE scan started")
        bleScanner.start(seconds: 10)
    }

    private func scanBLEToEnd() async {
        startBLEScan()
        while !ble.finished {
            try? await Task.sleep(for: .milliseconds(250))
        }
        log("BLE scan finished: state \(ble.state), \(ble.peripheralsSeen) peripherals")
    }

    // Listing a large FAT volume would stall the UI, so only the panel runs on the main actor.
    func chooseGarminVolume() async {
        guard !busy.contains("garmin"), let url = GarminProbe.chooseVolume() else { return }
        busy.insert("garmin")
        defer { busy.remove("garmin") }
        let result = await Task.detached { GarminProbe.probe(url) }.value
        garmin = result
        hasSavedBookmark = GarminProbe.hasSavedBookmark
        log("Garmin \(url.path): \(result.listing.summary); \(result.bookmarkCreate.line); \(result.bookmarkResolve?.line ?? "")")
    }

    func resolveSavedBookmark() async {
        guard !busy.contains("garmin") else { return }
        busy.insert("garmin")
        defer { busy.remove("garmin") }
        let resolved = await Task.detached { GarminProbe.resolveSaved() }.value
        savedBookmarkResolve = resolved
        log("saved bookmark: \(resolved.step.line); \(resolved.listing?.summary ?? "")")
    }

    func copyReport() {
        let text = report
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastCopied = Date()
        log("report copied (\(text.count) characters)")
    }

    private func log(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        events.insert(ProbeEvent(date: Date(), text: text), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
}
#endif
