#if os(macOS)
import Foundation

/// What a USB VID:PID says about the cable on the other end: a dive computer maker's own cable, or a common USB-serial chip.
public struct CableHint: Hashable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    /// "Suunto USB cable", "Silicon Labs CP210x".
    public let name: String
    /// The brand the cable is sold for; nil for a USB-serial chip any maker uses.
    public let brand: String?
    /// The families the cable is sold for, most likely first; empty for a chip any maker uses.
    public let families: [DeviceConfiguration.DeviceFamily]
    /// The PID is the brand's own, so only `families` can be on the other end.
    public let exclusive: Bool
    /// macOS 26.4's built-in drivers don't match it, so it shows no port until the chip maker's driver is installed.
    public let needsVendorDriver: Bool
    /// The chip maker's driver: needed when `needsVendorDriver`, else the fallback when macOS's own driver made no port.
    public let driverURL: URL?

    public init(vendorID: UInt16, productID: UInt16, name: String, brand: String? = nil,
                families: [DeviceConfiguration.DeviceFamily] = [], exclusive: Bool = false,
                needsVendorDriver: Bool = false, driverURL: URL? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.brand = brand
        self.families = families
        self.exclusive = exclusive
        self.needsVendorDriver = needsVendorDriver
        self.driverURL = driverURL
    }

    /// The serial models to offer for a port behind this cable: only `families` when `exclusive`, else every serial model with `families` first.
    public var candidates: [DCModel] {
        let serial = DeviceCatalog.models(for: .serial)
        let ranked = families.flatMap { family in serial.filter { $0.family == family } }
        if exclusive { return ranked }
        let rankedFamilies = Set(families)
        return ranked + serial.filter { !rankedFamilies.contains($0.family) }
    }
}

/// The USB-serial cables and chips dive computers are known to use, by VID:PID; which ones macOS drives itself was read from macOS 26.4's driver personalities.
public enum CableHints {
    private static let ftdiDriver = URL(string: "https://ftdichip.com/drivers/vcp-drivers/")

    private static let ostcFamilies: [DeviceConfiguration.DeviceFamily] = [.hwOstc, .hwOstc3, .hwFrog]
    private static let suuntoFamilies: [DeviceConfiguration.DeviceFamily] = [.suuntoD9, .suuntoVyper2, .suuntoVyper, .suuntoEon, .suuntoSolution]

    public static let all: [CableHint] = [
        CableHint(vendorID: 0x0403, productID: 0xF680, name: "Suunto USB cable", brand: "Suunto",
                  families: suuntoFamilies, exclusive: true, driverURL: ftdiDriver),
        CableHint(vendorID: 0x0403, productID: 0x87D0, name: "Cressi USB cable", brand: "Cressi",
                  families: [.cressiLeonardo, .cressiGoa, .cressiEdy], exclusive: true, driverURL: ftdiDriver),
        CableHint(vendorID: 0x0403, productID: 0xF460, name: "Oceanic/Pelagic USB cable", brand: "Pelagic",
                  families: [.oceanicAtom2, .oceanicVeo250, .oceanicVtpro], exclusive: true,
                  needsVendorDriver: true, driverURL: ftdiDriver),
        CableHint(vendorID: 0x0403, productID: 0x6015, name: "FTDI FT-X USB-serial", brand: "Heinrichs Weikamp",
                  families: ostcFamilies, driverURL: ftdiDriver),
        CableHint(vendorID: 0x0403, productID: 0x6001, name: "FTDI FT232R USB-serial", brand: "Heinrichs Weikamp",
                  families: ostcFamilies, driverURL: ftdiDriver),
        // Subsurface's table lists the multi-channel FTDI chips for Suunto and OSTC interfaces too; ranking only.
        CableHint(vendorID: 0x0403, productID: 0x6010, name: "FTDI FT2232 USB-serial",
                  families: ostcFamilies + suuntoFamilies, driverURL: ftdiDriver),
        CableHint(vendorID: 0x0403, productID: 0x6011, name: "FTDI FT4232 USB-serial",
                  families: ostcFamilies + suuntoFamilies, driverURL: ftdiDriver),
        // Prolific chips with Epson's VID, which macOS 26.4 has no driver for; the cable maker supplies one.
        CableHint(vendorID: 0x04B8, productID: 0x0521, name: "Mares/Cressi USB cable (Prolific)", brand: "Mares",
                  families: [.maresNemo, .maresPuck, .maresDarwin, .cressiEdy, .cressiLeonardo], needsVendorDriver: true),
        CableHint(vendorID: 0x04B8, productID: 0x0522, name: "Zeagle USB cable (Prolific)", brand: "Zeagle",
                  families: [.zeagleN2ition3], needsVendorDriver: true),
        // The Icon HD family's own USB-CDC interface; macOS's CDC driver gives it a port.
        CableHint(vendorID: 0xFFFF, productID: 0x0005, name: "Mares USB interface", brand: "Mares", families: [.maresIconHD]),
        CableHint(vendorID: 0x10C4, productID: 0xEA60, name: "Silicon Labs CP210x"),
        CableHint(vendorID: 0x10C4, productID: 0xEA70, name: "Silicon Labs CP2105"),
        CableHint(vendorID: 0x10C4, productID: 0xEA71, name: "Silicon Labs CP2108", needsVendorDriver: true,
                  driverURL: URL(string: "https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers")),
        CableHint(vendorID: 0x067B, productID: 0x2303, name: "Prolific PL2303"),
        CableHint(vendorID: 0x067B, productID: 0x2304, name: "Prolific PL2303"),
        CableHint(vendorID: 0x1A86, productID: 0x7523, name: "WCH CH340"),
        CableHint(vendorID: 0x1A86, productID: 0x55D4, name: "WCH CH9102"),
    ]

    public static func hint(vendorID: UInt16, productID: UInt16) -> CableHint? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// The USB vendors in `all`, for matching USB devices that come and go.
    static var vendorIDs: Set<UInt16> { Set(all.map(\.vendorID)) }
}

/// A serial port (or a known cable with none), or a USB HID or raw USB dive computer, a host can offer for a download.
public struct CableEndpoint: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case ready
        /// A known cable is plugged in but macOS made no port for it.
        case driverMissing
        /// A `DiveComputerSession` in this process has the port or device open.
        case busy
    }

    /// The callout path, "usb:<registry id>" for a cable with no port, "usbhid:<registry id>" for a USB HID computer, or "usbdevice:<registry id>" for a raw USB computer; stable while it stays plugged in.
    public let id: String
    /// `.serial` for a USB port, `.classicBTSerial` for a paired Bluetooth port, `.usbHID` for a computer that is itself a USB HID device, `.usb` for one read over raw USB (the Atomic Aquatics Cobalt).
    public let transport: DCTransport
    /// The /dev/cu.* device to open; nil when `driverMissing`.
    public let calloutPath: String?
    public let vendorID: UInt16?
    public let productID: UInt16?
    /// The USB adapter's own serial number, when it has one; it stands in for a computer that reports none.
    public let usbSerialNumber: String?
    /// The USB product name the adapter (or USB computer) reports.
    public let productName: String?
    public let hint: CableHint?
    /// The models to offer, most likely first.
    public let candidates: [DCModel]
    public var status: Status
    /// A USB HID computer's IOHIDDevice registry entry, or a raw USB computer's USB device entry, which the open starts from.
    public let registryID: UInt64?

    public init(id: String, transport: DCTransport, calloutPath: String?, vendorID: UInt16? = nil, productID: UInt16? = nil,
                usbSerialNumber: String? = nil, productName: String? = nil, hint: CableHint? = nil,
                candidates: [DCModel], status: Status = .ready, registryID: UInt64? = nil) {
        self.id = id
        self.transport = transport
        self.calloutPath = calloutPath
        self.vendorID = vendorID
        self.productID = productID
        self.usbSerialNumber = usbSerialNumber
        self.productName = productName
        self.hint = hint
        self.candidates = candidates
        self.status = status
        self.registryID = registryID
    }

    /// A USB serial port at `path`, with the hint and candidates its VID:PID gives.
    public static func serialPort(path: String, vendorID: UInt16?, productID: UInt16?, usbSerialNumber: String? = nil,
                                  productName: String? = nil) -> CableEndpoint {
        let hint = vendorID.flatMap { vid in productID.flatMap { CableHints.hint(vendorID: vid, productID: $0) } }
        return CableEndpoint(id: path, transport: .serial, calloutPath: path, vendorID: vendorID, productID: productID,
                             usbSerialNumber: usbSerialNumber.flatMap { $0.isEmpty ? nil : $0 }, productName: productName,
                             hint: hint, candidates: hint?.candidates ?? DeviceCatalog.models(for: .serial))
    }

    /// A USB HID device that is one of libdivecomputer's HID models, offering only those (`DeviceCatalog.candidates`); nil for any other device on the same VIDs, such as a Suunto watch or a Keil debug probe.
    public static func usbHIDDevice(registryID: UInt64, vendorID: UInt16, productID: UInt16, serialNumber: String? = nil,
                                    productName: String? = nil) -> CableEndpoint? {
        let candidates = DeviceCatalog.candidates(vid: vendorID, pid: productID, transport: .usbHID)
        guard !candidates.isEmpty else { return nil }
        return CableEndpoint(id: "usbhid:" + String(registryID, radix: 16), transport: .usbHID, calloutPath: nil,
                             vendorID: vendorID, productID: productID,
                             usbSerialNumber: serialNumber.flatMap { $0.isEmpty ? nil : $0 }, productName: productName,
                             candidates: candidates, registryID: registryID)
    }

    /// A USB device that is one of libdivecomputer's raw USB models (`USBComputers`), offering only those; nil for any other device.
    public static func usbDevice(registryID: UInt64, vendorID: UInt16, productID: UInt16, serialNumber: String? = nil,
                                 productName: String? = nil) -> CableEndpoint? {
        guard USBComputers.layout(vendorID: vendorID, productID: productID) != nil else { return nil }
        let candidates = DeviceCatalog.candidates(vid: vendorID, pid: productID, transport: .usb)
        guard !candidates.isEmpty else { return nil }
        return CableEndpoint(id: "usbdevice:" + String(registryID, radix: 16), transport: .usb, calloutPath: nil,
                             vendorID: vendorID, productID: productID,
                             usbSerialNumber: serialNumber.flatMap { $0.isEmpty ? nil : $0 }, productName: productName,
                             candidates: candidates, registryID: registryID)
    }

    /// A paired classic-Bluetooth port, offering the models its name matches (`DeviceCatalog.pairedBluetoothCandidates`).
    public static func pairedBluetoothPort(path: String, baseName: String? = nil) -> CableEndpoint {
        let name = baseName ?? (path as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "")
        return CableEndpoint(id: path, transport: .classicBTSerial, calloutPath: path, productName: baseName,
                             candidates: DeviceCatalog.pairedBluetoothCandidates(portName: name))
    }

    /// Where a session on this endpoint reached the computer; nil when there is no port or device to open.
    public var locator: DiveComputerLocator? {
        if transport == .usbHID || transport == .usb {
            guard let registryID, let vendorID, let productID else { return nil }
            return transport == .usb ? .usb(vid: vendorID, pid: productID, registryID: registryID)
                : .usbHID(vid: vendorID, pid: productID, registryID: registryID)
        }
        guard let calloutPath else { return nil }
        switch transport {
        case .classicBTSerial:
            return .classicBTSerial(path: calloutPath)
        default:
            return .serial(path: calloutPath, usbSerial: usbSerialNumber, vid: vendorID, pid: productID)
        }
    }

    /// What `EndpointClaims` marks busy: the port, or the USB device.
    var claimKey: String? {
        isUSBComputer ? id : calloutPath
    }

    /// The computer is itself the USB device, with no port in between.
    private var isUSBComputer: Bool { transport == .usbHID || transport == .usb }

    /// The hint's name, else a USB computer's one candidate, else the product name, else the port's file name.
    public var displayName: String {
        if let hint { return hint.name }
        if isUSBComputer, candidates.count == 1, let only = candidates.first { return only.name }
        if let productName, !productName.isEmpty { return productName }
        if isUSBComputer, !candidates.isEmpty { return candidates.map(\.name).joined(separator: " or ") }
        return calloutPath.map { ($0 as NSString).lastPathComponent } ?? "USB cable"
    }

    /// Every model the endpoint offers is beta on its transport (`DCModel.isBeta(on:)`), as a Cobalt's are.
    public var isBeta: Bool {
        !candidates.isEmpty && candidates.allSatisfy { $0.isBeta(on: transport) }
    }

    /// What to do about a `driverMissing` endpoint, in English: which driver, and where from when the hint knows; nil otherwise.
    public var driverMissingMessage: String? {
        guard status == .driverMissing else { return nil }
        let source = hint?.driverURL.map { " from \($0.absoluteString)" } ?? ""
        if hint?.needsVendorDriver == true {
            let driver = hint?.driverURL == nil ? "the macOS driver its maker supplies" : "the chip maker's driver\(source)"
            return "macOS has no driver for the \(displayName), so it has no serial port. Install \(driver), "
                + "then unplug the cable and plug it in again."
        }
        return "macOS made no serial port for the \(displayName). Unplug it and plug it in again. "
            + "If it still has no port, install the chip maker's driver\(source)."
    }

    /// `driverMissingMessage` with no download link and no install step, for an App Store build (Guideline 2.4.5).
    public var driverMissingStoreMessage: String? {
        guard status == .driverMissing else { return nil }
        if hint?.needsVendorDriver == true {
            return "macOS has no driver for the \(displayName), so it has no serial port. Ask the cable's maker about macOS support."
        }
        return "macOS made no serial port for the \(displayName). Unplug it and plug it in again."
    }
}

/// What the IORegistry says about serial ports and known cables at one moment: the seam `IOKitCableDiscovery` maps, so the mapping runs on fixtures.
public struct RegistrySnapshot: Hashable, Sendable {
    public struct USBDevice: Hashable, Sendable {
        public var registryID: UInt64
        public var vendorID: UInt16
        public var productID: UInt16
        public var serialNumber: String?
        public var productName: String?

        public init(registryID: UInt64, vendorID: UInt16, productID: UInt16, serialNumber: String? = nil, productName: String? = nil) {
            self.registryID = registryID
            self.vendorID = vendorID
            self.productID = productID
            self.serialNumber = serialNumber
            self.productName = productName
        }
    }

    /// One IOSerialBSDClient.
    public struct Port: Hashable, Sendable {
        public enum Parent: Hashable, Sendable {
            case usb(USBDevice)
            case bluetooth
            /// Built in, such as debug-console.
            case none
        }

        public var calloutPath: String
        /// kIOTTYBaseNameKey, such as "Bluetooth-Incoming-Port".
        public var baseName: String?
        public var parent: Parent

        public init(calloutPath: String, baseName: String? = nil, parent: Parent) {
            self.calloutPath = calloutPath
            self.baseName = baseName
            self.parent = parent
        }
    }

    /// One IOHIDDevice on a `HIDVendors` VID, whether or not it is a model libdivecomputer knows.
    public struct HIDDevice: Hashable, Sendable {
        public var registryID: UInt64
        public var vendorID: UInt16
        public var productID: UInt16
        public var serialNumber: String?
        public var productName: String?
        /// kIOHIDPrimaryUsagePageKey.
        public var primaryUsagePage: UInt32?
        /// kIOHIDPrimaryUsageKey.
        public var primaryUsage: UInt32?

        public init(registryID: UInt64, vendorID: UInt16, productID: UInt16, serialNumber: String? = nil,
                    productName: String? = nil, primaryUsagePage: UInt32? = nil, primaryUsage: UInt32? = nil) {
            self.registryID = registryID
            self.vendorID = vendorID
            self.productID = productID
            self.serialNumber = serialNumber
            self.productName = productName
            self.primaryUsagePage = primaryUsagePage
            self.primaryUsage = primaryUsage
        }

        var isKeyboardOrMouse: Bool {
            primaryUsagePage == HIDVendors.genericDesktopUsagePage
                && primaryUsage.map(HIDVendors.keyboardOrMouseUsages.contains) == true
        }

        /// A keyboard or mouse interface of a composite device that has another HID interface with the same VID:PID. Nobody has
        /// read the dive computers' real usage pages, so a computer's only interface is never hidden, whatever page it declares.
        func isRedundantInputInterface(among devices: [HIDDevice]) -> Bool {
            isKeyboardOrMouse && devices.contains {
                $0.registryID != registryID && $0.vendorID == vendorID && $0.productID == productID && !$0.isKeyboardOrMouse
            }
        }
    }

    public var ports: [Port]
    /// USB devices with a `CableHints` VID:PID, with or without a port.
    public var cableDevices: [USBDevice]
    public var hidDevices: [HIDDevice]
    /// USB devices with a `USBComputers` VID:PID.
    public var usbComputers: [USBDevice]

    public init(ports: [Port] = [], cableDevices: [USBDevice] = [], hidDevices: [HIDDevice] = [],
                usbComputers: [USBDevice] = []) {
        self.ports = ports
        self.cableDevices = cableDevices
        self.hidDevices = hidDevices
        self.usbComputers = usbComputers
    }

    static let bluetoothIncomingBaseName = "Bluetooth-Incoming-Port"
    /// Paired Bluetooth ports are listed now that a session can open them.
    static let listsPairedBluetoothPorts = true

    /// USB HID computers; then raw USB computers; then USB ports, known cables first; then known cables with no port; then paired Bluetooth ports, once they can be opened. Built-in ports, macOS's own Bluetooth listening port, keyboards and mice beside a computer's own interface, and HID devices that are no known model are left out.
    public var endpoints: [CableEndpoint] {
        var usb: [CableEndpoint] = []
        var bluetooth: [CableEndpoint] = []
        var devicesWithPorts = Set<UInt64>()
        for port in ports {
            switch port.parent {
            case .usb(let device):
                devicesWithPorts.insert(device.registryID)
                usb.append(.serialPort(path: port.calloutPath, vendorID: device.vendorID, productID: device.productID,
                                       usbSerialNumber: device.serialNumber, productName: device.productName))
            case .bluetooth:
                guard Self.listsPairedBluetoothPorts else { continue }
                let incoming = port.baseName == Self.bluetoothIncomingBaseName
                    || port.calloutPath.hasSuffix("." + Self.bluetoothIncomingBaseName)
                guard !incoming else { continue }
                bluetooth.append(.pairedBluetoothPort(path: port.calloutPath, baseName: port.baseName))
            case .none:
                continue
            }
        }
        let missing = cableDevices
            .filter { !devicesWithPorts.contains($0.registryID) }
            .compactMap { device -> CableEndpoint? in
                guard let hint = CableHints.hint(vendorID: device.vendorID, productID: device.productID) else { return nil }
                return CableEndpoint(id: "usb:" + String(device.registryID, radix: 16), transport: .serial, calloutPath: nil,
                                     vendorID: device.vendorID, productID: device.productID,
                                     usbSerialNumber: device.serialNumber.flatMap { $0.isEmpty ? nil : $0 },
                                     productName: device.productName, hint: hint, candidates: hint.candidates,
                                     status: .driverMissing)
            }
        let hid = hidDevices
            .filter { !$0.isRedundantInputInterface(among: hidDevices) }
            .compactMap { device in
                CableEndpoint.usbHIDDevice(registryID: device.registryID, vendorID: device.vendorID, productID: device.productID,
                                           serialNumber: device.serialNumber, productName: device.productName)
            }
        let computers = usbComputers.compactMap { device in
            CableEndpoint.usbDevice(registryID: device.registryID, vendorID: device.vendorID, productID: device.productID,
                                    serialNumber: device.serialNumber, productName: device.productName)
        }
        let byID: (CableEndpoint, CableEndpoint) -> Bool = { $0.id < $1.id }
        return hid.sorted(by: byID) + computers.sorted(by: byID) + usb.filter { $0.hint != nil }.sorted(by: byID)
            + usb.filter { $0.hint == nil }.sorted(by: byID) + missing.sorted(by: byID) + bluetooth.sorted(by: byID)
    }
}
#endif
