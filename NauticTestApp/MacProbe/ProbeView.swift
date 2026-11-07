#if os(macOS)
import SwiftUI

struct ProbeView: View {
    @Bindable var model: ProbeModel

    var body: some View {
        Form {
            environmentSection
            serialSection
            driversSection
            bridgeSection
            hidSection
            usbSection
            bleSection
            garminSection
            eventsSection
        }
        .formStyle(.grouped)
        .navigationTitle("DC Tester Probe")
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                Button("Run open tests", systemImage: "play") {
                    Task { await model.runAllOpenTests() }
                }
                .disabled(model.busy.contains("all"))
                .help(Self.runAllHelp)
                Button("Copy report", systemImage: "doc.on.clipboard") { model.copyReport() }
                    .help("Copies the markdown matrix for Docs/MAC_SANDBOX_PROBE.md")
            }
        }
        .task { model.start() }
    }

    static let runAllHelp = "Opens known cable bridges, Bluetooth SPP and system ports, known dive-computer HID devices, and any Atomic Cobalt. "
        + "First unplug any dev board or debug adapter on an FTDI, CP210x, PL2303 or CH34x chip "
        + "(ESP32/ESP8266, Arduino clones, JTAG/SWD probes): the DTR/RTS toggles reset them."

    @ViewBuilder
    private var environmentSection: some View {
        Section("Environment") {
            if let env = model.environment {
                LabeledContent("macOS", value: env.osVersion)
                LabeledContent("Hardware", value: env.hardwareSummary)
                LabeledContent("Binary slice", value: env.archSummary)
                LabeledContent("Sandboxed", value: env.sandboxed ? "yes" : "NO")
                LabeledContent("Launched", value: env.launchedByLaunchd ? "LaunchServices" : "from a shell (TCC goes to the terminal)")
                LabeledContent("Container") {
                    Text(env.containerPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("libdivecomputer", value: env.libdcVersion)
                LabeledContent("App", value: env.appVersion)
                LabeledContent("Probe commit", value: env.probeCommit)
                ForEach(env.entitlements, id: \.key) { entitlement in
                    LabeledContent(entitlement.key.replacingOccurrences(of: "com.apple.security.", with: "")) {
                        Text(entitlement.granted ? "granted" : "missing")
                            .foregroundStyle(entitlement.granted ? Color.secondary : Color.red)
                    }
                }
                ForEach(env.extraEntitlements, id: \.self) { key in
                    LabeledContent(key.replacingOccurrences(of: "com.apple.security.", with: "")) {
                        Text("also present").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Input Monitoring") {
                    Text("\(model.inputMonitoringAtLaunch) at launch" + (model.inputMonitoringAfterHID.map { ", \($0) after HID tests" } ?? ""))
                }
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var serialSection: some View {
        Section {
            if let error = model.serial.error {
                Text(error).foregroundStyle(.red)
            }
            if model.serial.ports.isEmpty {
                Text("No IOSerialBSDClient ports.").foregroundStyle(.secondary)
            }
            TextField("Find model", text: $model.identifyFilter, prompt: Text("Vendor or model, e.g. i770R"))
            Picker("Identify as", selection: $model.identifyTarget) {
                if model.identifyTarget == nil {
                    Text("No libdc serial descriptors").tag(SerialIdentifyTarget?.none)
                }
                let shown = model.shownIdentifyTargets
                Section("HIL models") {
                    ForEach(shown.filter(\.isHILModel)) { target in
                        Text(target.label).tag(Optional(target))
                    }
                }
                Section("Other libdc serial descriptors") {
                    ForEach(shown.filter { !$0.isHILModel }) { target in
                        Text(target.label).tag(Optional(target))
                    }
                }
            }
            ForEach(model.serial.ports) { port in
                ProbeRow(
                    title: port.displayName,
                    badge: port.kind.rawValue,
                    lines: serialLines(port),
                    warning: serialWarning(port),
                    steps: serialSteps(port),
                    actions: serialActions(port),
                    isBusy: model.busy.contains("serial:\(port.id)")
                )
            }
        } header: {
            Text("Serial ports (IOKit)")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open test: POSIX open, TIOCEXCL, termios set and restored (USB ports also try IOSSIOSPEED 460800 and 850000), then libdc's own dc_serial_open with 2400 8O1, 9600, 38400 and 115200 8N1, 115200 8E1, DTR, RTS, purge, break and a 300 ms read. On Bluetooth SPP only Shearwater's steps decide the result. Identify runs dc_device_open with the descriptor picked above, from \(model.identifyTargets.count) libdc serial descriptors.")
                let dev = model.devListing
                Text(dev.error.map { "opendir /dev failed: \($0)" } ?? "opendir /dev: \(dev.cu.count) cu.*, \(dev.tty.count) tty.*")
                if let iteration = model.libdcIteration {
                    Text("libdc dc_serial_iterator: \(iteration.status), \(iteration.names.joined(separator: ", "))")
                }
                ForEach(model.hotplugErrors, id: \.self) { Text("Hot-plug: \($0)").foregroundStyle(.red) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func serialLines(_ port: SerialPort) -> [String] {
        var lines = [port.calloutPath]
        if port.hasUSBParent {
            var usb = "USB \(ProbeText.vidPid(port.vendorID, port.productID))"
            if let product = port.usbProduct { usb += " \(product)" }
            if let vendor = port.usbVendor { usb += ", \(vendor)" }
            if let serial = port.usbSerial { usb += ", serial \(serial)" }
            lines.append(usb)
        }
        if !port.ancestry.isEmpty {
            lines.append("providers: " + port.ancestry.joined(separator: " < "))
        }
        return lines
    }

    private func serialWarning(_ port: SerialPort) -> String? {
        if port.hiddenInProductUI { return "No USB parent: hidden in the product UI" }
        if !port.autoTestable {
            let device = port.hint == nil ? "Unknown USB serial device" : "FTDI multi-channel chip, used by JTAG/SWD adapters"
            return "\(device): Run open tests skips it, since a DTR drop can reset it"
        }
        return nil
    }

    private func serialSteps(_ port: SerialPort) -> [ProbeStep] {
        let open = model.serialResults[port.id]?.steps ?? []
        guard let identify = model.serialIdentify[port.id] else { return open }
        return open + identify.steps.map { $0.renamed("identify") }
    }

    private func serialActions(_ port: SerialPort) -> [RowAction] {
        var actions = [RowAction(title: "Open test") { Task { await model.testSerial(port) } }]
        if port.appliesTermios {
            actions.append(RowAction(title: "Identify") { Task { await model.identifySerial(port) } })
        }
        return actions
    }

    @ViewBuilder
    private var driversSection: some View {
        Section {
            ForEach(model.builtInDrivers, id: \.name) { table in
                Text(table.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(table.error == nil ? Color.secondary : Color.red)
            }
            ForEach(model.cableCoverage, id: \.self) { entry in
                Text(entry.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.coveredBy.isEmpty ? Color.orange : Color.secondary)
            }
        } header: {
            Text("Built-in serial drivers")
        } footer: {
            Text("Read from each DriverKit dext's IOKitPersonalities, so it holds without the cable attached.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bridgeSection: some View {
        Section {
            if model.bridgeDevices.isEmpty {
                Text("No FTDI, CP210x, PL2303 or CH34x device attached.").foregroundStyle(.secondary)
            }
            ForEach(model.bridgeDevices) { device in
                ProbeRow(
                    title: device.displayName,
                    badge: device.driverMissing ? "driverMissing" : "driver ok",
                    lines: [device.calloutPaths.isEmpty ? "no IOSerialBSDClient" : device.calloutPaths.joined(separator: " ")]
                        + device.driverLines,
                    warning: device.driverMissing ? "Known cable chip with no serial driver bound" : nil,
                    steps: []
                )
            }
        } header: {
            Text("USB-serial bridges")
        }
    }

    @ViewBuilder
    private var hidSection: some View {
        Section {
            if model.hidDevices.isEmpty {
                Text("No HID device with VID 1493, 2e6c or c251.").foregroundStyle(.secondary)
            }
            ForEach(model.hidDevices) { device in
                ProbeRow(
                    title: device.displayName,
                    badge: device.transport ?? "HID",
                    lines: [device.usageSummary, device.reportSummary] + [device.manufacturer, device.serial.map { "serial \($0)" }].compactMap { $0 },
                    warning: device.autoSkipReason.map { "Run open tests skips it: \($0). Its Open test seizes it for 2 s, then opens it shared" },
                    steps: (model.hidResults[device.id] ?? []).flatMap { result in
                        let kind = result.identify == nil ? "" : " identify"
                        return result.steps.map { $0.renamed("\(result.mode.rawValue)\(kind)") }
                            + (result.firstReport.map { [ProbeStep.ok("\(result.mode.rawValue)\(kind) first report", $0)] } ?? [])
                    },
                    actions: hidActions(device),
                    isBusy: model.busy.contains("hid:\(device.id)")
                )
            }
        } header: {
            Text("USB-HID (IOHIDManager, dive-computer vendors only)")
        } footer: {
            Text("Open test runs seize, then shared: IOHIDDeviceOpen, dispatch queue, 2 s input listen, cancel, close. A quiet device sending 0 reports is normal. Run open tests opens only Suunto and Scubapro VIDs and c251:2006, never a keyboard or mouse usage page. Send identify, offered only for known models, replaces the listen with libdc's read-only first commands (EON Steel init; G2 handshake and model) through IOHIDDeviceSetReport and waits for the reply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hidActions(_ device: HIDDeviceInfo) -> [RowAction] {
        var actions = [RowAction(title: "Open test") { Task { await model.testHID(device, identify: false) } }]
        if device.identify != nil {
            actions.append(RowAction(title: "Send identify") { Task { await model.testHID(device, identify: true) } })
        }
        return actions
    }

    @ViewBuilder
    private var usbSection: some View {
        Section {
            if let error = model.usb.error {
                Text(error).foregroundStyle(.red)
            }
            if model.cobaltDevices.isEmpty {
                Text("No Atomic Cobalt (0471:0888) attached. \(model.usb.devices.count) USB devices seen via \(model.usb.className).")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cobaltDevices) { device in
                usbRow(device)
            }
            DisclosureGroup("All USB devices (\(model.usb.devices.count))") {
                ForEach(model.usb.devices) { device in
                    usbRow(device)
                }
            }
        } header: {
            Text("USB raw (IOUSBLib)")
        } footer: {
            Text("Plug-in test: USBDeviceOpen, configuration (set only on a Cobalt), interface 0 claimed with USBInterfaceOpen and its pipes listed. A Cobalt must show bulk 0x82 in and 0x02 out. The list refreshes 2 s later, and a test that set the configuration runs once more on the configured device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func usbRow(_ device: USBDeviceInfo) -> some View {
        ProbeRow(
            title: device.displayName,
            badge: device.deviceClass.map { String(format: "class 0x%02x", $0) } ?? "USB",
            lines: [device.product, device.vendor].compactMap { $0 } + device.driverLines,
            warning: nil,
            steps: (model.usbResults[device.id] ?? []) + (model.usbSecondRuns[device.id] ?? []).map { $0.renamed("second run") },
            actions: [RowAction(title: "Plug-in test") { Task { await model.testUSB(device) } }],
            isBusy: model.busy.contains("usb:\(device.id)")
        )
    }

    @ViewBuilder
    private var bleSection: some View {
        Section("Bluetooth LE") {
            LabeledContent("State", value: model.ble.state)
            LabeledContent("Authorization", value: model.ble.authorization)
            if model.ble.scanned {
                LabeledContent("Peripherals seen", value: "\(model.ble.peripheralsSeen)")
                LabeledContent("Dive computers", value: model.ble.diveComputers.isEmpty ? "none" : model.ble.diveComputers.joined(separator: ", "))
            }
            if let note = model.ble.note {
                Text(note).foregroundStyle(.orange)
            }
            HStack {
                Button("Scan 10 s") { model.startBLEScan() }
                    .disabled(model.ble.running)
                if model.ble.running { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder
    private var garminSection: some View {
        Section("Garmin volume") {
            HStack {
                Button("Choose volume…") { Task { await model.chooseGarminVolume() } }
                Button("Resolve saved bookmark") { Task { await model.resolveSavedBookmark() } }
                    .disabled(!model.hasSavedBookmark)
                if model.busy.contains("garmin") { ProgressView().controlSize(.small) }
            }
            .disabled(model.busy.contains("garmin"))
            if let garmin = model.garmin {
                LabeledContent("Volume", value: garmin.volumePath)
                LabeledContent("FIT files", value: garmin.listing.summary)
                StepList(steps: [garmin.bookmarkCreate] + [garmin.bookmarkResolve].compactMap { $0 })
                if let resolved = garmin.resolvedListing {
                    LabeledContent("After resolve", value: resolved.summary)
                }
            }
            if let saved = model.savedBookmarkResolve {
                StepList(steps: [saved.step])
                if let listing = saved.listing {
                    LabeledContent("Saved bookmark", value: listing.summary)
                }
            }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        Section("Events") {
            if let copied = model.lastCopied {
                Text("Report copied at \(copied.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
            }
            ForEach(model.events.prefix(60)) { event in
                Text("\(event.date.formatted(date: .omitted, time: .standard))  \(event.text)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private struct RowAction {
    let title: String
    let run: () -> Void
}

private struct ProbeRow: View {
    let title: String
    let badge: String
    let lines: [String]
    let warning: String?
    let steps: [ProbeStep]
    var actions: [RowAction] = []
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title, action: action.run).disabled(isBusy)
                }
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            StepList(steps: steps)
        }
        .padding(.vertical, 2)
    }
}

private struct StepList: View {
    let steps: [ProbeStep]

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            Text(step.line)
                .font(.caption.monospaced())
                .foregroundStyle(color(step.outcome))
                .textSelection(.enabled)
        }
    }

    private func color(_ outcome: ProbeStep.Outcome) -> Color {
        switch outcome {
        case .ok: return .green
        case .failed: return .red
        case .informational: return .orange
        case .skipped: return .secondary
        }
    }
}
#endif
