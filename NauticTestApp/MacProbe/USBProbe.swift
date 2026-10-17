#if os(macOS)
import Foundation
import IOKit
import IOKit.serial
import IOKit.usb
import IOKit.usb.IOUSBLib

struct USBInterfaceInfo: Hashable {
    let number: Int?
    let interfaceClass: Int?
    let subclass: Int?
    let drivers: [String]
    let userClients: [String]

    func summary(deviceHolder: String?) -> String {
        let cls = interfaceClass.map { String(format: "0x%02x", $0) } ?? "?"
        let bound: String
        if !drivers.isEmpty {
            bound = drivers.joined(separator: ", ")
        } else if let deviceHolder {
            bound = "no interface driver, device held by \(deviceHolder)"
        } else {
            bound = "no driver"
        }
        return "if\(number.map(String.init) ?? "?") class \(cls): \(bound)" + USBDeviceInfo.clients(userClients)
    }
}

struct USBDeviceInfo: Identifiable, Hashable {
    let id: UInt64
    let vendorID: Int
    let productID: Int
    let product: String?
    let vendor: String?
    let serial: String?
    let locationID: Int?
    let deviceClass: Int?
    let deviceDrivers: [String]
    let userClients: [String]
    let interfaces: [USBInterfaceInfo]
    let calloutPaths: [String]

    var vidPid: String { ProbeText.vidPid(vendorID, productID) }
    var hint: CableHint? { CableHint.lookup(vendorID: vendorID, productID: productID) }
    var isSerialBridge: Bool { CableHint.isBridge(vendorID: vendorID) }
    var driverMissing: Bool { isSerialBridge && calloutPaths.isEmpty }
    var isAtomicCobalt: Bool { vendorID == USBProbe.cobaltVendorID && productID == USBProbe.cobaltProductID }

    // Composite drivers only pick the configuration and leave the interfaces claimable.
    var deviceHolder: String? {
        let holders = deviceDrivers.filter { !$0.hasSuffix("CompositeDevice") }
        return holders.isEmpty ? nil : holders.joined(separator: ", ")
    }

    var driverLines: [String] {
        let device = "device driver: " + (deviceDrivers.isEmpty ? "none" : deviceDrivers.joined(separator: ", "))
        return [device + Self.clients(userClients)] + interfaces.map { $0.summary(deviceHolder: deviceHolder) }
    }

    var displayName: String {
        if isAtomicCobalt { return "Atomic Aquatics Cobalt \(vidPid)" }
        return "\(hint?.label ?? product ?? "USB device") \(vidPid)"
    }

    // User clients are named after the process holding them, e.g. a vendor app that has the device open.
    static func clients(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return ", \(names.count) user client\(names.count == 1 ? "" : "s") (\(Set(names).sorted().joined(separator: ", ")))"
    }
}

struct USBScan: Hashable {
    var devices: [USBDeviceInfo] = []
    var className = kIOUSBHostDeviceClassName
    var error: String?
}

private typealias DeviceInterface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface100>?>
private typealias InterfaceInterface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface100>?>

enum USBProbe {
    static let cobaltVendorID = 0x0471
    static let cobaltProductID = 0x0888

    static func enumerate() -> USBScan {
        var scan = USBScan()
        for className in [kIOUSBHostDeviceClassName, "IOUSBDevice"] {
            scan = USBScan(className: className)
            let kr = Registry.matching(IOServiceMatching(className)) { device in
                scan.devices.append(info(device))
            }
            if kr != KERN_SUCCESS { scan.error = "IOServiceGetMatchingServices(\(className)): \(ProbeText.ioReturn(kr))" }
            if !scan.devices.isEmpty { break }
        }
        scan.devices.sort { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
        return scan
    }

    static func info(_ device: io_service_t) -> USBDeviceInfo {
        var interfaces: [USBInterfaceInfo] = []
        var deviceDrivers: [String] = []
        var deviceClients: [String] = []
        Registry.children(device) { child in
            if Registry.isUSBInterface(child) {
                var drivers: [String] = []
                var clients: [String] = []
                Registry.children(child) { entry in
                    if Registry.isUserClient(entry) { clients.append(Registry.name(entry)) } else { drivers.append(Registry.driverLabel(entry)) }
                }
                interfaces.append(USBInterfaceInfo(
                    number: Registry.int(child, "bInterfaceNumber"),
                    interfaceClass: Registry.int(child, "bInterfaceClass"),
                    subclass: Registry.int(child, "bInterfaceSubClass"),
                    drivers: drivers,
                    userClients: clients
                ))
            } else if Registry.isUserClient(child) {
                deviceClients.append(Registry.name(child))
            } else {
                deviceDrivers.append(Registry.driverLabel(child))
            }
        }
        var callouts: [String] = []
        Registry.children(device, recursive: true) { entry in
            if Registry.conforms(entry, to: kIOSerialBSDServiceValue), let path = SerialProbe.calloutPath(of: entry) {
                callouts.append(path)
            }
        }
        return USBDeviceInfo(
            id: Registry.registryID(device),
            vendorID: Registry.int(device, kUSBVendorID) ?? 0,
            productID: Registry.int(device, kUSBProductID) ?? 0,
            product: Registry.string(device, kUSBProductString, "kUSBProductString"),
            vendor: Registry.string(device, kUSBVendorString, "kUSBVendorString"),
            serial: Registry.string(device, kUSBSerialNumberString, "kUSBSerialNumberString"),
            locationID: Registry.int(device, "locationID"),
            deviceClass: Registry.int(device, "bDeviceClass"),
            deviceDrivers: deviceDrivers,
            userClients: deviceClients,
            interfaces: interfaces.sorted { ($0.number ?? 0) < ($1.number ?? 0) },
            calloutPaths: callouts.sorted()
        )
    }

    // IOUSBLib's UUIDs are CFUUIDGetConstantUUIDWithBytes macros that Swift cannot import.
    private static let deviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xd4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let interfaceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xd4, 0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let cfPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0xc2, 0x44, 0xe8, 0x58, 0x10, 0x9c, 0x11, 0xd4, 0x91, 0xd4, 0x00, 0x50, 0xe4, 0xc6, 0x42, 0x6f)
    private static let deviceInterfaceID100 = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xd4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let interfaceInterfaceID100 = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x73, 0xc9, 0x7a, 0xe8, 0x9e, 0xf3, 0x11, 0xd4, 0xb1, 0xd0, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    /// Device open, configuration, then interface 0 claimed with its pipes listed: what a bulk transport needs.
    static func plugInTest(registryID: UInt64, expectCobaltPipes: Bool) -> [ProbeStep] {
        let service = Registry.service(registryID: registryID)
        guard service != 0 else { return [.failed("lookup", "device is gone")] }
        defer { IOObjectRelease(service) }

        var steps: [ProbeStep] = []
        guard let device: DeviceInterface = query(service, deviceUserClientTypeID, deviceInterfaceID100, "IOUSBDeviceInterface", &steps) else {
            return steps
        }
        defer { _ = device.pointee?.pointee.Release(device) }
        guard let deviceVTable = device.pointee?.pointee else {
            steps.append(.failed("QueryInterface(IOUSBDeviceInterface)", "NULL interface"))
            return steps
        }

        let open = deviceVTable.USBDeviceOpen(device)
        guard open == kIOReturnSuccess else {
            steps.append(.failed("USBDeviceOpen", ProbeText.ioReturn(open)))
            return steps
        }
        steps.append(.ok("USBDeviceOpen"))

        configure(device, deviceVTable, allowSet: expectCobaltPipes, into: &steps)
        claimInterfaceZero(device, deviceVTable, expectCobaltPipes: expectCobaltPipes, into: &steps)

        let close = deviceVTable.USBDeviceClose(device)
        steps.append(close == kIOReturnSuccess ? .ok("USBDeviceClose") : .failed("USBDeviceClose", ProbeText.ioReturn(close)))
        return steps
    }

    private static func query<T>(_ service: io_service_t, _ typeID: CFUUID?, _ interfaceID: CFUUID?, _ label: String,
                                 _ steps: inout [ProbeStep]) -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(service, typeID, cfPlugInInterfaceID, &plugIn, &score)
        guard kr == KERN_SUCCESS, let plugIn, let plugInVTable = plugIn.pointee?.pointee else {
            steps.append(.failed("IOCreatePlugInInterfaceForService(\(label))", ProbeText.ioReturn(kr)))
            return nil
        }
        defer { IODestroyPlugInInterface(plugIn) }
        steps.append(.ok("IOCreatePlugInInterfaceForService(\(label))", "score \(score)"))

        var raw: LPVOID?
        let hr = plugInVTable.QueryInterface(plugIn, CFUUIDGetUUIDBytes(interfaceID), &raw)
        guard hr == 0, let raw else {
            steps.append(.failed("QueryInterface(\(label))", String(format: "HRESULT 0x%08x", UInt32(bitPattern: hr))))
            return nil
        }
        steps.append(.ok("QueryInterface(\(label))"))
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<T>?.self)
    }

    // A vendor-class device may arrive unconfigured, with no interface nubs until a configuration is set.
    private static func configure(_ device: DeviceInterface, _ vtable: IOUSBDeviceInterface100, allowSet: Bool, into steps: inout [ProbeStep]) {
        var current: UInt8 = 0
        let get = vtable.GetConfiguration(device, &current)
        guard get == kIOReturnSuccess else {
            steps.append(.failed("GetConfiguration", ProbeText.ioReturn(get)))
            return
        }
        steps.append(.ok("GetConfiguration", "\(current)"))
        guard current == 0 else { return }
        guard allowSet else {
            steps.append(.skipped("SetConfiguration", "unconfigured; only a Cobalt gets configured"))
            return
        }
        var descriptor: IOUSBConfigurationDescriptorPtr?
        let read = vtable.GetConfigurationDescriptorPtr(device, 0, &descriptor)
        guard read == kIOReturnSuccess, let descriptor else {
            steps.append(.failed("GetConfigurationDescriptorPtr(0)", ProbeText.ioReturn(read)))
            return
        }
        let value = descriptor.pointee.bConfigurationValue
        steps.append(.ok("GetConfigurationDescriptorPtr(0)", "bConfigurationValue \(value), \(descriptor.pointee.bNumInterfaces) interfaces"))
        let set = vtable.SetConfiguration(device, value)
        steps.append(set == kIOReturnSuccess ? .ok("SetConfiguration", "\(value)") : .failed("SetConfiguration", ProbeText.ioReturn(set)))
    }

    private static func claimInterfaceZero(_ device: DeviceInterface, _ deviceVTable: IOUSBDeviceInterface100,
                                           expectCobaltPipes: Bool, into steps: inout [ProbeStep]) {
        let any = UInt16(kIOUSBFindInterfaceDontCare)
        var request = IOUSBFindInterfaceRequest(bInterfaceClass: any, bInterfaceSubClass: any, bInterfaceProtocol: any, bAlternateSetting: any)
        var iterator: io_iterator_t = 0
        let created = deviceVTable.CreateInterfaceIterator(device, &request, &iterator)
        guard created == kIOReturnSuccess else {
            steps.append(.failed("CreateInterfaceIterator", ProbeText.ioReturn(created)))
            return
        }
        var service: io_service_t = 0
        var seen = 0
        Registry.drain(iterator) { next in
            seen += 1
            if service == 0, Registry.int(next, "bInterfaceNumber") == 0 {
                IOObjectRetain(next)
                service = next
            }
        }
        IOObjectRelease(iterator)
        guard service != 0 else {
            steps.append(.failed("CreateInterfaceIterator", "\(seen) interfaces, none numbered 0"))
            return
        }
        defer { IOObjectRelease(service) }
        steps.append(.ok("CreateInterfaceIterator", "\(seen) interfaces, using interface 0"))

        guard let interface: InterfaceInterface = query(service, interfaceUserClientTypeID, interfaceInterfaceID100, "IOUSBInterfaceInterface", &steps) else {
            return
        }
        defer { _ = interface.pointee?.pointee.Release(interface) }
        guard let vtable = interface.pointee?.pointee else {
            steps.append(.failed("QueryInterface(IOUSBInterfaceInterface)", "NULL interface"))
            return
        }

        let open = vtable.USBInterfaceOpen(interface)
        guard open == kIOReturnSuccess else {
            steps.append(.failed("USBInterfaceOpen", ProbeText.ioReturn(open)))
            return
        }
        steps.append(.ok("USBInterfaceOpen"))

        var count: UInt8 = 0
        let counted = vtable.GetNumEndpoints(interface, &count)
        if counted == kIOReturnSuccess {
            steps.append(.ok("GetNumEndpoints", "\(count)"))
            var pipes: [(address: Int, type: UInt8)] = []
            var described: [String] = []
            for pipe in stride(from: UInt8(1), through: count, by: 1) {
                var direction: UInt8 = 0, number: UInt8 = 0, type: UInt8 = 0, interval: UInt8 = 0
                var maxPacket: UInt16 = 0
                let kr = vtable.GetPipeProperties(interface, pipe, &direction, &number, &type, &maxPacket, &interval)
                guard kr == kIOReturnSuccess else {
                    described.append("pipe \(pipe) \(ProbeText.ioReturn(kr))")
                    continue
                }
                let address = Int(number) | (direction == 1 ? 0x80 : 0)
                pipes.append((address, type))
                described.append("pipe \(pipe): " + String(format: "0x%02x", address)
                    + " \(direction == 1 ? "in" : "out") \(transferName(type)) max \(maxPacket)")
            }
            steps.append(.ok("GetPipeProperties", described.isEmpty ? "no pipes" : described.joined(separator: "; ")))
            if expectCobaltPipes {
                let bulk = UInt8(2)
                let hasIn = pipes.contains { $0.address == 0x82 && $0.type == bulk }
                let hasOut = pipes.contains { $0.address == 0x02 && $0.type == bulk }
                let detail = "0x82 bulk in \(hasIn ? "present" : "MISSING"), 0x02 bulk out \(hasOut ? "present" : "MISSING")"
                steps.append(hasIn && hasOut ? .ok("Cobalt pipes", detail) : .failed("Cobalt pipes", detail))
            }
        } else {
            steps.append(.failed("GetNumEndpoints", ProbeText.ioReturn(counted)))
        }

        let close = vtable.USBInterfaceClose(interface)
        steps.append(close == kIOReturnSuccess ? .ok("USBInterfaceClose") : .failed("USBInterfaceClose", ProbeText.ioReturn(close)))
    }

    private static func transferName(_ type: UInt8) -> String {
        switch type {
        case 0: return "control"
        case 1: return "isoc"
        case 2: return "bulk"
        case 3: return "interrupt"
        default: return "type \(type)"
        }
    }
}
#endif
