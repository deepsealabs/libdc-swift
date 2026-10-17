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
    /// macOS has no built-in driver for it, so it shows no port until the chip maker's driver is installed.
    public let needsVendorDriver: Bool
    /// Where the driver comes from, when `needsVendorDriver`.
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

/// The USB-serial cables and chips dive computers are known to use, by VID:PID.
public enum CableHints {
    private static let ftdiDriver = URL(string: "https://ftdichip.com/drivers/vcp-drivers/")

    private static let ostcFamilies: [DeviceConfiguration.DeviceFamily] = [.hwOstc, .hwOstc3, .hwFrog]

    public static let all: [CableHint] = [
        CableHint(vendorID: 0x0403, productID: 0xF680, name: "Suunto USB cable", brand: "Suunto",
                  families: [.suuntoD9, .suuntoVyper2, .suuntoVyper, .suuntoEon, .suuntoSolution], exclusive: true),
        CableHint(vendorID: 0x0403, productID: 0x87D0, name: "Cressi USB cable", brand: "Cressi",
                  families: [.cressiLeonardo, .cressiGoa, .cressiEdy], exclusive: true),
        CableHint(vendorID: 0x0403, productID: 0xF460, name: "Oceanic/Pelagic USB cable", brand: "Pelagic",
                  families: [.oceanicAtom2, .oceanicVeo250, .oceanicVtpro], exclusive: true,
                  needsVendorDriver: true, driverURL: ftdiDriver),
        CableHint(vendorID: 0x0403, productID: 0x6015, name: "FTDI FT-X USB-serial", brand: "Heinrichs Weikamp",
                  families: ostcFamilies),
        CableHint(vendorID: 0x0403, productID: 0x6001, name: "FTDI FT232R USB-serial", brand: "Heinrichs Weikamp",
                  families: ostcFamilies),
        CableHint(vendorID: 0x10C4, productID: 0xEA60, name: "Silicon Labs CP210x"),
        CableHint(vendorID: 0x10C4, productID: 0xEA70, name: "Silicon Labs CP2105"),
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

/// A serial port (or a known cable with none) a host can offer for a download.
public struct CableEndpoint: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case ready
        /// A known cable is plugged in but macOS made no port for it.
        case driverMissing
        /// A `DiveComputerSession` in this process has the port open.
        case busy
    }

    /// The callout path, or "usb:<registry id>" for a cable with no port; stable while it stays plugged in.
    public let id: String
    /// `.serial` for a USB port, `.classicBTSerial` for a paired Bluetooth port.
    public let transport: DCTransport
    /// The /dev/cu.* device to open; nil when `driverMissing`.
    public let calloutPath: String?
    public let vendorID: UInt16?
    public let productID: UInt16?
    /// The USB adapter's own serial number, when it has one; it stands in for a computer that reports none.
    public let usbSerialNumber: String?
    /// The USB product name the adapter reports.
    public let productName: String?
    public let hint: CableHint?
    /// The models to offer, most likely first.
    public let candidates: [DCModel]
    public var status: Status

    public init(id: String, transport: DCTransport, calloutPath: String?, vendorID: UInt16? = nil, productID: UInt16? = nil,
                usbSerialNumber: String? = nil, productName: String? = nil, hint: CableHint? = nil,
                candidates: [DCModel], status: Status = .ready) {
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
    }

    /// A USB serial port at `path`, with the hint and candidates its VID:PID gives.
    public static func serialPort(path: String, vendorID: UInt16?, productID: UInt16?, usbSerialNumber: String? = nil,
                                  productName: String? = nil) -> CableEndpoint {
        let hint = vendorID.flatMap { vid in productID.flatMap { CableHints.hint(vendorID: vid, productID: $0) } }
        return CableEndpoint(id: path, transport: .serial, calloutPath: path, vendorID: vendorID, productID: productID,
                             usbSerialNumber: usbSerialNumber.flatMap { $0.isEmpty ? nil : $0 }, productName: productName,
                             hint: hint, candidates: hint?.candidates ?? DeviceCatalog.models(for: .serial))
    }

    /// Where a session on this endpoint reached the computer; nil when there is no port.
    public var locator: DiveComputerLocator? {
        guard let calloutPath else { return nil }
        switch transport {
        case .classicBTSerial:
            return .classicBTSerial(path: calloutPath)
        default:
            return .serial(path: calloutPath, usbSerial: usbSerialNumber, vid: vendorID, pid: productID)
        }
    }

    /// The hint's name, else the adapter's product name, else the port's file name.
    public var displayName: String {
        if let hint { return hint.name }
        if let productName, !productName.isEmpty { return productName }
        return calloutPath.map { ($0 as NSString).lastPathComponent } ?? "USB cable"
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

    public var ports: [Port]
    /// USB devices with a `CableHints` VID:PID, with or without a port.
    public var cableDevices: [USBDevice]

    public init(ports: [Port] = [], cableDevices: [USBDevice] = []) {
        self.ports = ports
        self.cableDevices = cableDevices
    }

    static let bluetoothIncomingBaseName = "Bluetooth-Incoming-Port"

    /// USB ports, known cables first; then known cables with no port; then paired Bluetooth ports. Built-in ports and macOS's own Bluetooth listening port are left out.
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
                let incoming = port.baseName == Self.bluetoothIncomingBaseName
                    || port.calloutPath.hasSuffix("." + Self.bluetoothIncomingBaseName)
                guard !incoming else { continue }
                bluetooth.append(CableEndpoint(id: port.calloutPath, transport: .classicBTSerial, calloutPath: port.calloutPath,
                                               productName: port.baseName,
                                               candidates: DeviceCatalog.models(for: .classicBTSerial)))
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
        let byID: (CableEndpoint, CableEndpoint) -> Bool = { $0.id < $1.id }
        return usb.filter { $0.hint != nil }.sorted(by: byID) + usb.filter { $0.hint == nil }.sorted(by: byID)
            + missing.sorted(by: byID) + bluetooth.sorted(by: byID)
    }
}
#endif
