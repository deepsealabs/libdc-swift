#if os(macOS)
import Foundation
import IOKit
import IOKit.serial
import IOKit.usb
import Clibdivecomputer

struct CableHint: Hashable {
    let label: String
    let needsVendorDriver: Bool
    var autoOpen = true

    static let bridgeVendors: [(Int, String)] = [
        (0x0403, "FTDI"), (0x10c4, "Silicon Labs"), (0x067b, "Prolific"), (0x1a86, "WCH")
    ]

    static let known: [(Int, Int, CableHint)] = [
        (0x0403, 0xf680, CableHint(label: "Suunto USB cable (FTDI)", needsVendorDriver: false)),
        (0x0403, 0x87d0, CableHint(label: "Cressi USB cable (FTDI)", needsVendorDriver: false)),
        (0x0403, 0xf460, CableHint(label: "Oceanic/Pelagic USB cable (FTDI)", needsVendorDriver: true)),
        (0x0403, 0x6015, CableHint(label: "FTDI FT-X, e.g. HW OSTC", needsVendorDriver: false)),
        (0x0403, 0x6001, CableHint(label: "FTDI FT232R, e.g. HW OSTC", needsVendorDriver: false)),
        // Multi-channel and MPSSE chips are JTAG/SWD adapters; no known dive cable uses them.
        (0x0403, 0x6010, CableHint(label: "FTDI FT2232", needsVendorDriver: false, autoOpen: false)),
        (0x0403, 0x6011, CableHint(label: "FTDI FT4232", needsVendorDriver: false, autoOpen: false)),
        (0x0403, 0x6014, CableHint(label: "FTDI FT232H", needsVendorDriver: false, autoOpen: false)),
        (0x10c4, 0xea60, CableHint(label: "Silicon Labs CP210x", needsVendorDriver: false)),
        (0x10c4, 0xea70, CableHint(label: "Silicon Labs CP2105", needsVendorDriver: false)),
        (0x067b, 0x2303, CableHint(label: "Prolific PL2303", needsVendorDriver: false)),
        (0x067b, 0x2304, CableHint(label: "Prolific PL2303", needsVendorDriver: false)),
        (0x1a86, 0x7523, CableHint(label: "WCH CH340", needsVendorDriver: false)),
        (0x1a86, 0x55d4, CableHint(label: "WCH CH9102", needsVendorDriver: false))
    ]

    static func lookup(vendorID: Int?, productID: Int?) -> CableHint? {
        guard let vendorID, let productID else { return nil }
        if let hit = known.first(where: { $0.0 == vendorID && $0.1 == productID }) { return hit.2 }
        guard let vendor = bridgeVendors.first(where: { $0.0 == vendorID }) else { return nil }
        return CableHint(label: "\(vendor.1) bridge, PID not in the built-in driver table", needsVendorDriver: true)
    }

    static func isBridge(vendorID: Int) -> Bool {
        bridgeVendors.contains { $0.0 == vendorID }
    }
}

struct SerialPort: Identifiable, Hashable {
    enum Kind: String {
        case usb = "USB"
        case bluetoothSPP = "Bluetooth SPP"
        case bluetoothIncoming = "Bluetooth incoming"
        case builtIn = "built-in"

        // SPP opens can page the paired device; system ports must not have their termios changed.
        var appliesTermios: Bool { self == .usb || self == .bluetoothSPP }
    }

    var id: String { calloutPath }
    let calloutPath: String
    let dialinPath: String?
    let baseName: String
    let kind: Kind
    let vendorID: Int?
    let productID: Int?
    let usbSerial: String?
    let usbProduct: String?
    let usbVendor: String?
    let ancestry: [String]

    var hasUSBParent: Bool { kind == .usb }
    var hiddenInProductUI: Bool { kind == .bluetoothIncoming || kind == .builtIn }
    var hint: CableHint? { CableHint.lookup(vendorID: vendorID, productID: productID) }
    var appliesTermios: Bool { kind.appliesTermios }
    // Unknown USB serial devices (Arduinos, printers, UPSes) and JTAG adapters reset or misbehave on a DTR drop.
    var autoTestable: Bool { kind != .usb || hint?.autoOpen == true }

    var displayName: String {
        switch kind {
        case .usb:
            let name = hint?.label ?? usbProduct ?? "USB serial"
            return "\(name) \(ProbeText.vidPid(vendorID, productID))"
        case .bluetoothSPP: return "Bluetooth SPP \(baseName)"
        case .bluetoothIncoming: return "Bluetooth incoming port"
        case .builtIn: return "Built-in \(baseName)"
        }
    }
}

struct SerialScan: Hashable {
    var ports: [SerialPort] = []
    var error: String?
}

struct DevListing: Hashable {
    var cu: [String] = []
    var tty: [String] = []
    var error: String?
}

struct LibDCSerialIteration: Hashable {
    var status: String
    var names: [String]
}

struct SerialOpenResult: Hashable {
    let kind: SerialPort.Kind
    let raw: [ProbeStep]
    /// nil on system ports, which never get termios or line changes.
    let libdc: [ProbeStep]?

    var steps: [ProbeStep] { raw + (libdc ?? []) }
    var opened: Bool { raw.first { $0.name == "open" }?.outcome == .ok }
    var customBaud: [ProbeStep] { raw.filter { SerialProbe.isCustomBaud($0.name) } }
    var openSteps: [ProbeStep] { raw.filter { !SerialProbe.isCustomBaud($0.name) } }
}

/// One libdc descriptor with a serial transport, as the Identify picker offers it.
struct SerialIdentifyTarget: Hashable, Identifiable {
    let vendor: String
    let product: String
    let family: UInt32
    let model: UInt32
    // libdc reuses some names across models, e.g. two "Aqualung i200C".
    let sharesName: Bool

    var id: String { "\(family):\(model):\(name)" }
    var name: String { "\(vendor) \(product)" }
    var title: String { sharesName ? name + String(format: " (model 0x%x)", model) : name }
    var readsVersionAtOpen: Bool? { Self.openReadsVersion[family] }
    var isHILModel: Bool { Self.hilModels.contains(name) }

    var openBehaviour: String {
        switch readsVersionAtOpen {
        case true?: return "open reads the version"
        case false?: return "open only configures the line"
        case nil: return "open behaviour unknown"
        }
    }

    var label: String { "\(title): \(openBehaviour)" }

    func matches(_ query: String) -> Bool {
        query.split(separator: " ").allSatisfy { title.localizedCaseInsensitiveContains($0) }
    }

    static let defaultName = "Suunto D9"

    // The serial models on the HIL bench, listed first.
    static let hilModels: Set<String> = [
        "Suunto D9", "Suunto Vyper", "Suunto Vyper 2", "Oceanic Atom 2.0", "Aqualung i770R",
        "Mares Icon HD", "Heinrichs Weikamp OSTC", "Cressi Leonardo", "Shearwater Petrel"
    ]

    // Checked against each family's *_device_open in libdivecomputer/src.
    private static let openReadsVersion: [UInt32: Bool] = [
        DC_FAMILY_SUUNTO_VYPER.rawValue: false,
        DC_FAMILY_SUUNTO_VYPER2.rawValue: true,
        DC_FAMILY_SUUNTO_D9.rawValue: true,
        DC_FAMILY_OCEANIC_ATOM2.rawValue: true,
        DC_FAMILY_MARES_ICONHD.rawValue: true,
        DC_FAMILY_HW_OSTC.rawValue: false,
        DC_FAMILY_CRESSI_LEONARDO.rawValue: false,
        DC_FAMILY_SHEARWATER_PETREL.rawValue: false
    ]
}

struct SerialIdentifyResult: Hashable {
    let target: SerialIdentifyTarget
    let steps: [ProbeStep]
}

struct DriverMatch: Hashable {
    let vendorID: Int
    let productID: Int
    let interface: Int?
}

struct DriverTable: Hashable {
    let name: String
    var version: String?
    var matches: [DriverMatch] = []
    var error: String?

    var summary: String {
        if let error { return "\(name): \(error)" }
        return "\(name) (\(version ?? "version ?")): \(Set(matches.map { "\($0.vendorID):\($0.productID)" }).count) VID:PID"
    }
}

struct CableCoverage: Hashable {
    let label: String
    let vendorID: Int
    let productID: Int
    let coveredBy: [String]
    // A personality pinned to interface 1+ never binds a single-interface cable with that PID.
    let matchesInterfaceZero: Bool

    var summary: String {
        let vidPid = ProbeText.vidPid(vendorID, productID)
        return coveredBy.isEmpty ? "\(vidPid) \(label): NOT covered" : "\(vidPid) \(label): \(coveredBy.joined(separator: ", "))"
    }
}

/// Owns one dc_context and its log, so each SYSERROR's errno text lands on the step that raised it.
private final class LibDCSession {
    let context: OpaquePointer
    private var pending: [String] = []

    init?() {
        var created: OpaquePointer?
        guard dc_context_new(&created) == DC_STATUS_SUCCESS, let created else { return nil }
        context = created
        dc_context_set_loglevel(context, DC_LOGLEVEL_WARNING)
        dc_context_set_logfunc(context, { _, _, _, _, function, message, userdata in
            guard let userdata, let message else { return }
            let session = Unmanaged<LibDCSession>.fromOpaque(userdata).takeUnretainedValue()
            let origin = function.map { String(cString: $0) } ?? "libdc"
            session.pending.append("\(origin): \(String(cString: message))")
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { dc_context_free(context) }

    func run(_ name: String, accepting accepted: [dc_status_t] = [DC_STATUS_SUCCESS],
             note: (dc_status_t) -> String? = { _ in nil }, _ call: () -> dc_status_t) -> ProbeStep {
        pending.removeAll()
        let status = call()
        let detail = ([SerialProbe.statusName(status), note(status)].compactMap { $0 } + pending).joined(separator: "; ")
        pending.removeAll()
        return accepted.contains(status) ? .ok(name, detail) : .failed(name, detail)
    }
}

enum SerialProbe {
    static func enumerate() -> SerialScan {
        var scan = SerialScan()
        let kr = Registry.matching(IOServiceMatching(kIOSerialBSDServiceValue)) { service in
            if let port = port(from: service) { scan.ports.append(port) }
        }
        if kr != KERN_SUCCESS { scan.error = "IOServiceGetMatchingServices: \(ProbeText.ioReturn(kr))" }
        scan.ports.sort { $0.calloutPath < $1.calloutPath }
        return scan
    }

    static func calloutPath(of service: io_service_t) -> String? {
        Registry.string(service, kIOCalloutDeviceKey)
    }

    private static func port(from service: io_service_t) -> SerialPort? {
        guard let callout = calloutPath(of: service) else { return nil }
        let baseName = Registry.string(service, kIOTTYBaseNameKey) ?? (callout as NSString).lastPathComponent
        let (kind, ancestry) = classify(service, baseName: baseName)
        let usb = kind == .usb
        return SerialPort(
            calloutPath: callout,
            dialinPath: Registry.string(service, kIODialinDeviceKey),
            baseName: baseName,
            kind: kind,
            vendorID: usb ? (Registry.searchParents(service, kUSBVendorID) as? NSNumber)?.intValue : nil,
            productID: usb ? (Registry.searchParents(service, kUSBProductID) as? NSNumber)?.intValue : nil,
            usbSerial: usb ? parentString(service, kUSBSerialNumberString, "kUSBSerialNumberString") : nil,
            usbProduct: usb ? parentString(service, kUSBProductString, "kUSBProductString") : nil,
            usbVendor: usb ? parentString(service, kUSBVendorString, "kUSBVendorString") : nil,
            ancestry: ancestry
        )
    }

    private static func parentString(_ service: io_service_t, _ keys: String...) -> String? {
        keys.lazy.compactMap { Registry.searchParents(service, $0) as? String }.first
    }

    // Walks providers instead of trusting a parent idVendor: on Intel the BT controller is itself a USB device.
    private static func classify(_ service: io_service_t, baseName: String) -> (SerialPort.Kind, [String]) {
        var ancestry: [String] = []
        var kind = SerialPort.Kind.builtIn
        var entry = service
        IOObjectRetain(entry)
        for _ in 0..<32 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry)
            entry = parent
            let label = Registry.label(entry)
            if ancestry.count < 5 { ancestry.append(label) }
            if Registry.conforms(entry, to: kIOUSBHostDeviceClassName) || Registry.conforms(entry, to: "IOUSBDevice") {
                kind = .usb
                break
            }
            if label.contains("Bluetooth") {
                kind = baseName == "Bluetooth-Incoming-Port" ? .bluetoothIncoming : .bluetoothSPP
                break
            }
        }
        IOObjectRelease(entry)
        return (kind, ancestry)
    }

    static func listDev() -> DevListing {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: "/dev")
            return DevListing(
                cu: names.filter { $0.hasPrefix("cu.") }.sorted(),
                tty: names.filter { $0.hasPrefix("tty.") }.sorted()
            )
        } catch {
            return DevListing(error: (error as NSError).localizedDescription)
        }
    }

    /// What libdc's current C path sees: opendir /dev, tty.* only.
    static func libdcIterator() -> LibDCSerialIteration {
        var context: OpaquePointer?
        let contextStatus = dc_context_new(&context)
        guard contextStatus == DC_STATUS_SUCCESS else {
            return LibDCSerialIteration(status: "dc_context_new \(statusName(contextStatus))", names: [])
        }
        defer { dc_context_free(context) }

        var iterator: OpaquePointer?
        let status = dc_serial_iterator_new(&iterator, context, nil)
        guard status == DC_STATUS_SUCCESS, let iterator else {
            return LibDCSerialIteration(status: "dc_serial_iterator_new \(statusName(status))", names: [])
        }
        defer { dc_iterator_free(iterator) }

        var names: [String] = []
        var device: OpaquePointer?
        while dc_iterator_next(iterator, &device) == DC_STATUS_SUCCESS, let current = device {
            if let name = dc_serial_device_get_name(current) { names.append(String(cString: name)) }
            dc_serial_device_free(current)
            device = nil
        }
        return LibDCSerialIteration(status: statusName(DC_STATUS_SUCCESS), names: names)
    }

    static func statusName(_ status: dc_status_t) -> String {
        switch status {
        case DC_STATUS_SUCCESS: return "DC_STATUS_SUCCESS"
        case DC_STATUS_DONE: return "DC_STATUS_DONE"
        case DC_STATUS_UNSUPPORTED: return "DC_STATUS_UNSUPPORTED"
        case DC_STATUS_INVALIDARGS: return "DC_STATUS_INVALIDARGS"
        case DC_STATUS_NOMEMORY: return "DC_STATUS_NOMEMORY"
        case DC_STATUS_NODEVICE: return "DC_STATUS_NODEVICE"
        case DC_STATUS_NOACCESS: return "DC_STATUS_NOACCESS"
        case DC_STATUS_IO: return "DC_STATUS_IO"
        case DC_STATUS_TIMEOUT: return "DC_STATUS_TIMEOUT"
        case DC_STATUS_PROTOCOL: return "DC_STATUS_PROTOCOL"
        case DC_STATUS_DATAFORMAT: return "DC_STATUS_DATAFORMAT"
        case DC_STATUS_CANCELLED: return "DC_STATUS_CANCELLED"
        default: return "dc_status \(status.rawValue)"
        }
    }

    static func openTest(path: String, kind: SerialPort.Kind) -> SerialOpenResult {
        let raw = rawOpenTest(path: path, kind: kind)
        let opened = raw.first?.outcome == .ok
        return SerialOpenResult(kind: kind, raw: raw, libdc: kind.appliesTermios && opened ? libdcLineTest(path: path, kind: kind) : nil)
    }

    static let customBaudRates = [460_800, 850_000]
    static func isCustomBaud(_ name: String) -> Bool { name.hasPrefix("IOSSIOSPEED ") }

    /// The POSIX half of dc_serial_open and dc_serial_close, step by step, for errno detail.
    static func rawOpenTest(path: String, kind: SerialPort.Kind) -> [ProbeStep] {
        var steps: [ProbeStep] = []
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            return [.failed("open", ProbeText.errno(errno))]
        }
        steps.append(.ok("open", "O_RDWR|O_NOCTTY|O_NONBLOCK"))

        steps.append(ioctl(fd, TIOCEXCL) == 0 ? .ok("TIOCEXCL") : .failed("TIOCEXCL", ProbeText.errno(errno)))

        var original = termios()
        if tcgetattr(fd, &original) != 0 {
            steps.append(.failed("tcgetattr", ProbeText.errno(errno)))
        } else {
            steps.append(.ok("tcgetattr", "speed \(cfgetospeed(&original))"))
            var settings = original
            if !kind.appliesTermios {
                steps.append(.skipped("tcsetattr", "system port"))
            } else if cfsetspeed(&settings, speed_t(B9600)) != 0 {
                steps.append(.failed("cfsetspeed", ProbeText.errno(errno)))
            } else if tcsetattr(fd, TCSANOW, &settings) != 0 {
                steps.append(.failed("tcsetattr", ProbeText.errno(errno)))
            } else {
                steps.append(.ok("tcsetattr", "9600 applied"))
                if kind == .usb {
                    // Swift can't import the IOSSIOSPEED macro; this is _IOW('T', 2, speed_t) on 64-bit.
                    let iossiospeed: UInt = 0x8008_5402
                    for rate in customBaudRates {
                        var speed = speed_t(rate)
                        let result = withUnsafeMutablePointer(to: &speed) { ioctl(fd, iossiospeed, $0) }
                        let code = errno
                        steps.append(result == 0
                            ? .ok("IOSSIOSPEED \(rate)", "custom rate accepted")
                            : .failed("IOSSIOSPEED \(rate)", ProbeText.errno(code)))
                    }
                }
                steps.append(tcsetattr(fd, TCSANOW, &original) == 0
                    ? .ok("tcsetattr restore", "original termios")
                    : .failed("tcsetattr restore", ProbeText.errno(errno)))
            }
        }

        steps.append(ioctl(fd, TIOCNXCL) == 0 ? .ok("TIOCNXCL") : .failed("TIOCNXCL", ProbeText.errno(errno)))
        steps.append(close(fd) == 0 ? .ok("close") : .failed("close", ProbeText.errno(errno)))
        return steps
    }

    // 115200 8N1 goes last so the read runs on Shearwater's framing.
    private static let framings: [(name: String, baud: UInt32, parity: dc_parity_t)] = [
        ("2400 8O1", 2400, DC_PARITY_ODD),
        ("9600 8N1", 9600, DC_PARITY_NONE),
        ("38400 8N1", 38400, DC_PARITY_NONE),
        ("115200 8E1", 115_200, DC_PARITY_EVEN),
        ("115200 8N1", 115_200, DC_PARITY_NONE)
    ]

    // What shearwater_common_setup does; on Bluetooth SPP every other step is informational.
    private static let shearwaterSequence: Set<String> = [
        "dc_serial_open", "configure 115200 8N1", "set_timeout(300)", "purge(ALL)", "read 1 byte", "dc_iostream_close"
    ]

    /// The libdc families whose open needs a step, from each driver's dc_iostream_* calls.
    static func families(needing step: String) -> String? {
        switch step {
        case "configure 2400 8O1": return "Suunto Vyper"
        case "configure 9600 8N1": return "Suunto D9/Vyper 2, Mares Nemo/Darwin, Oceanic VT Pro/Veo 250"
        case "configure 38400 8N1": return "Oceanic Atom 2, Mares Puck"
        case "configure 115200 8E1": return "Mares Icon HD"
        case "configure 115200 8N1": return "Shearwater, HW OSTC/OSTC3, Cressi Leonardo, iDive, Pelagic VTX/i750TC/Pro Plus X/i770R"
        case "set_dtr(1)", "set_rts(1)", "set_rts(0)": return "Suunto, Pelagic, Mares, Cressi"
        case "set_break(1)", "set_break(0)": return "Cochran, Reefnet Sensus Pro"
        case "IOSSIOSPEED 460800": return "Sporasub SP2"
        case "IOSSIOSPEED 850000": return "Cochran"
        default: return nil
        }
    }

    /// The serial_posix calls a download makes: each family's framing, DTR/RTS (cable power and direction), purge, break, a timed read.
    static func libdcLineTest(path: String, kind: SerialPort.Kind) -> [ProbeStep] {
        guard let session = LibDCSession() else { return [.failed("dc_context_new", "no context")] }
        var iostream: OpaquePointer?
        let open = session.run("dc_serial_open") { dc_serial_open(&iostream, session.context, path) }
        guard open.outcome == .ok, let iostream else { return [open] }

        var steps = [open]
        for framing in framings {
            steps.append(session.run("configure \(framing.name)") {
                dc_iostream_configure(iostream, framing.baud, 8, framing.parity, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE)
            })
        }
        steps.append(session.run("set_dtr(1)") { dc_iostream_set_dtr(iostream, 1) })
        steps.append(session.run("set_rts(1)") { dc_iostream_set_rts(iostream, 1) })
        steps.append(session.run("set_rts(0)") { dc_iostream_set_rts(iostream, 0) })
        steps.append(session.run("purge(ALL)") { dc_iostream_purge(iostream, DC_DIRECTION_ALL) })
        steps.append(session.run("set_break(1)") { dc_iostream_set_break(iostream, 1) })
        steps.append(session.run("set_break(0)") { dc_iostream_set_break(iostream, 0) })
        steps.append(session.run("set_timeout(300)") { dc_iostream_set_timeout(iostream, 300) })

        var byte: UInt8 = 0
        var actual = 0
        let start = DispatchTime.now()
        steps.append(session.run("read 1 byte", accepting: [DC_STATUS_SUCCESS, DC_STATUS_TIMEOUT], note: { status in
            let elapsed = "\(ProbeText.milliseconds(since: start)) ms"
            return status == DC_STATUS_SUCCESS ? "\(actual) byte (\(ProbeText.hex([byte], limit: 1))) in \(elapsed)" : "after \(elapsed)"
        }) {
            dc_iostream_read(iostream, &byte, 1, &actual)
        })
        steps.append(session.run("dc_iostream_close", note: { _ in "restores termios" }) { dc_iostream_close(iostream) })
        guard kind == .bluetoothSPP else { return steps }
        return steps.map { shearwaterSequence.contains($0.name) ? $0 : $0.informational }
    }

    /// dc_device_open on the port with a chosen descriptor; for most families that open is a real version read.
    static func identify(path: String, target: SerialIdentifyTarget) -> [ProbeStep] {
        guard let session = LibDCSession() else { return [.failed("dc_context_new", "no context")] }
        guard let descriptor = descriptor(target, context: session.context) else {
            return [.failed("descriptor", "\(target.title) is not in libdc's table")]
        }
        defer { dc_descriptor_free(descriptor) }

        var iostream: OpaquePointer?
        let open = session.run("dc_serial_open") { dc_serial_open(&iostream, session.context, path) }
        guard open.outcome == .ok, let iostream else { return [open] }

        var steps = [open]
        var device: OpaquePointer?
        let start = DispatchTime.now()
        steps.append(session.run("dc_device_open \(target.title)", note: { _ in "\(ProbeText.milliseconds(since: start)) ms" }) {
            dc_device_open(&device, session.context, descriptor, iostream)
        })
        if let device {
            steps.append(session.run("dc_device_close") { dc_device_close(device) })
        }
        steps.append(session.run("dc_iostream_close") { dc_iostream_close(iostream) })
        return steps
    }

    /// Every libdc descriptor with a serial transport, HIL models first, then libdc's order.
    static func identifyTargets() -> [SerialIdentifyTarget] {
        var context: OpaquePointer?
        guard dc_context_new(&context) == DC_STATUS_SUCCESS, let context else { return [] }
        defer { dc_context_free(context) }
        var found: [(vendor: String, product: String, family: UInt32, model: UInt32)] = []
        eachDescriptor(context) { descriptor in
            guard dc_descriptor_get_transports(descriptor) & DC_TRANSPORT_SERIAL.rawValue != 0 else { return false }
            found.append((
                vendor: dc_descriptor_get_vendor(descriptor).map { String(cString: $0) } ?? "?",
                product: dc_descriptor_get_product(descriptor).map { String(cString: $0) } ?? "?",
                family: dc_descriptor_get_type(descriptor).rawValue,
                model: dc_descriptor_get_model(descriptor)
            ))
            return false
        }
        let nameCounts = Dictionary(found.map { ("\($0.vendor) \($0.product)", 1) }, uniquingKeysWith: +)
        let targets = found.map { entry in
            SerialIdentifyTarget(vendor: entry.vendor, product: entry.product, family: entry.family, model: entry.model,
                                 sharesName: nameCounts["\(entry.vendor) \(entry.product)", default: 0] > 1)
        }
        return targets.filter(\.isHILModel) + targets.filter { !$0.isHILModel }
    }

    private static func descriptor(_ target: SerialIdentifyTarget, context: OpaquePointer) -> OpaquePointer? {
        var match: OpaquePointer?
        eachDescriptor(context) { descriptor in
            let vendor = dc_descriptor_get_vendor(descriptor).map { String(cString: $0) }
            let product = dc_descriptor_get_product(descriptor).map { String(cString: $0) }
            guard vendor == target.vendor, product == target.product,
                  dc_descriptor_get_type(descriptor).rawValue == target.family,
                  dc_descriptor_get_model(descriptor) == target.model else { return false }
            match = descriptor
            return true
        }
        return match
    }

    /// Frees each descriptor unless `body` returns true, which keeps it for the caller and stops.
    private static func eachDescriptor(_ context: OpaquePointer, _ body: (OpaquePointer) -> Bool) {
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, context) == DC_STATUS_SUCCESS, let iterator else { return }
        defer { dc_iterator_free(iterator) }
        var item: OpaquePointer?
        while dc_iterator_next(iterator, &item) == DC_STATUS_SUCCESS, let current = item {
            if body(current) { return }
            dc_descriptor_free(current)
            item = nil
        }
    }

    static let driverExtensions = ["FTDI", "SLCOM", "PLCOM", "CHCOM", "Serial"].map { "AppleUSB\($0)" }

    /// Reads the built-in serial dexts' match tables, so a Mac without every cable still records what it would bind.
    static func builtInDrivers() -> [DriverTable] {
        driverExtensions.map { name in
            var table = DriverTable(name: name)
            let url = URL(fileURLWithPath: "/System/Library/DriverExtensions/com.apple.DriverKit-\(name).dext/Info.plist")
            do {
                let data = try Data(contentsOf: url)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    table.error = "Info.plist is not a dictionary"
                    return table
                }
                let build = plist["DTPlatformBuild"] as? String
                table.version = "CFBundleVersion \(plist["CFBundleVersion"] as? String ?? "?")" + (build.map { ", build \($0)" } ?? "")
                let personalities = plist["IOKitPersonalities"] as? [String: [String: Any]] ?? [:]
                for personality in personalities.values {
                    guard let vendor = (personality["idVendor"] as? NSNumber)?.intValue else { continue }
                    let interface = (personality["bInterfaceNumber"] as? NSNumber)?.intValue
                    var products = (personality["idProductArray"] as? [NSNumber] ?? []).map(\.intValue)
                    if let product = (personality["idProduct"] as? NSNumber)?.intValue { products.append(product) }
                    table.matches += products.map { DriverMatch(vendorID: vendor, productID: $0, interface: interface) }
                }
            } catch {
                let ns = error as NSError
                table.error = "read FAILED, \(ns.domain) \(ns.code): \(ns.localizedDescription)"
            }
            return table
        }
    }

    static func coverage(_ tables: [DriverTable]) -> [CableCoverage] {
        CableHint.known.map { vendor, product, hint in
            let matches = tables.flatMap { table in
                table.matches.filter { $0.vendorID == vendor && $0.productID == product }.map { (table.name, $0.interface) }
            }
            let names = matches.map { name, interface in interface.map { "\(name) on interface \($0)" } ?? name }
            return CableCoverage(label: hint.label, vendorID: vendor, productID: product, coveredBy: Array(Set(names)).sorted(),
                                 matchesInterfaceZero: matches.contains { ($0.1 ?? 0) == 0 })
        }
    }
}
#endif
