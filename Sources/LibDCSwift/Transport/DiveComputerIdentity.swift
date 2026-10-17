import Foundation
import Clibdivecomputer
import LibDCBridge

/// Which physical dive computer a download came from, the same over every transport.
public struct DiveComputerIdentity: Codable, Hashable, Sendable {
    public let family: DeviceConfiguration.DeviceFamily
    public let model: UInt32
    public let canonicalName: String
    /// DEVINFO's serial as `%08x`; nil when the computer reports none or 0, as every Cressi Edy and Oceans S1 does.
    public let serial: String?
    public let firmware: String?
    /// The transport this download used. No key includes it, so a computer keys the same over BLE and cable.
    public let transport: DCTransport

    /// `serial` is trimmed and lowercased, and an empty or all-zero one is unknown; `canonicalName` defaults to `DeviceCatalog.canonicalName`.
    public init(family: DeviceConfiguration.DeviceFamily, model: UInt32, serial: String?, firmware: String? = nil,
                transport: DCTransport, canonicalName: String? = nil) {
        self.family = family
        self.model = model
        self.canonicalName = canonicalName ?? DeviceCatalog.canonicalName(family: family, model: model)
        self.serial = Self.normalizedSerial(serial)
        self.firmware = firmware.flatMap { $0.isEmpty ? nil : $0 }
        self.transport = transport
    }

    /// From DEVINFO's numbers, where 0 means not reported.
    public init(family: DeviceConfiguration.DeviceFamily, model: UInt32, serialNumber: UInt32, firmware: UInt32 = 0,
                transport: DCTransport) {
        self.init(family: family, model: model, serial: String(format: "%08x", serialNumber),
                  firmware: firmware == 0 ? nil : String(firmware), transport: transport)
    }

    /// "sn:<serial>", else "md:<canonical name>", lowercased: the keys hosts dedupe dives on.
    public var deviceKey: String {
        if let serial { return "sn:" + serial }
        return "md:" + canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The fingerprint store's key: "dc:<family>:<serial>" (unlike `deviceKey`, two families' equal serials never share it), else "md:<canonical name>@<standIn>", else nil and every download fetches every dive, since a model-only key would be shared by every unit of the model.
    public func storageKey(standIn: String? = nil) -> String? {
        if let serial { return "dc:" + String(format: "%08x", family.asDCFamily.rawValue) + ":" + serial }
        guard let standIn, !standIn.isEmpty else { return nil }
        return "md:" + canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "@" + standIn
    }

    /// The serial as the C lookup and 1.18 stored it, `%08x` of 0 included.
    var devinfoSerial: String { serial ?? "00000000" }

    static func normalizedSerial(_ serial: String?) -> String? {
        guard let trimmed = serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty,
              trimmed.contains(where: { $0 != "0" }) else { return nil }
        return trimmed
    }
}

extension DiveComputerIdentity {
    /// DEVINFO's identity for an open device, with the model a session parses with: the reported one when a descriptor knows it, else the opened descriptor's. nil before DEVINFO.
    public init?(device devicePtr: UnsafeMutablePointer<device_data_t>, transport: DCTransport) {
        let data = devicePtr.pointee
        guard data.have_devinfo != 0 else { return nil }
        let opened = data.descriptor.map { (family: dc_descriptor_get_type($0), model: dc_descriptor_get_model($0)) }
        let dcFamily = opened?.family ?? data.device.map { dc_device_get_type($0) } ?? DC_FAMILY_NULL
        guard let family = DeviceConfiguration.DeviceFamily(dcFamily: dcFamily) else { return nil }
        let reported = data.devinfo.model
        let model = reported != 0 && DeviceConfiguration.hasDescriptor(family: dcFamily, model: reported)
            ? reported : (opened?.model ?? reported)
        self.init(family: family, model: model, serialNumber: data.devinfo.serial, firmware: data.devinfo.firmware,
                  transport: transport)
    }

    /// Families whose drivers never send DEVINFO, so they have no serial and the C fingerprint lookup never runs.
    static let familiesWithoutDevinfo: Set<DeviceConfiguration.DeviceFamily> = [.zeagleN2ition3, .citizenAqualand]

    /// The opened descriptor's identity, with no serial, for a family in `familiesWithoutDevinfo`; nil for any other.
    init?(descriptorOf devicePtr: UnsafeMutablePointer<device_data_t>, transport: DCTransport) {
        guard let descriptor = devicePtr.pointee.descriptor,
              let family = DeviceConfiguration.DeviceFamily(dcFamily: dc_descriptor_get_type(descriptor)),
              Self.familiesWithoutDevinfo.contains(family) else { return nil }
        self.init(family: family, model: dc_descriptor_get_model(descriptor), serial: nil, transport: transport)
    }
}

/// Where a computer was reached this time: provenance for records and logs, never identity, since ports, registry IDs and BLE identifiers change.
public enum DiveComputerLocator: Codable, Hashable, Sendable {
    case ble(uuid: String)
    case serial(path: String, usbSerial: String?, vid: UInt16?, pid: UInt16?)
    case usbHID(vid: UInt16, pid: UInt16, registryID: UInt64)
    case usb(vid: UInt16, pid: UInt16, registryID: UInt64)
    case classicBTSerial(path: String)

    public var transport: DCTransport {
        switch self {
        case .ble: return .ble
        case .serial: return .serial
        case .usbHID: return .usbHID
        case .usb: return .usb
        case .classicBTSerial: return .classicBTSerial
        }
    }

    /// A string form for `StoredDevice.locatorKey` and logs.
    public var locatorKey: String {
        switch self {
        case .ble(let uuid):
            return "ble:" + uuid
        case .serial(let path, let usbSerial, _, _):
            return "serial:" + (usbSerial.flatMap { $0.isEmpty ? nil : $0 } ?? path)
        case .usbHID(let vid, let pid, let registryID):
            return "usbhid:" + Self.hex(vid, pid) + String(format: ":%llx", registryID)
        case .usb(let vid, let pid, let registryID):
            return "usb:" + Self.hex(vid, pid) + String(format: ":%llx", registryID)
        case .classicBTSerial(let path):
            return "btserial:" + path
        }
    }

    /// What `DiveComputerIdentity.storageKey(standIn:)` takes for a computer with no serial: the cable adapter's USB serial, or the peripheral's identifier on this host. nil where nothing outlives a replug.
    public var unitStandIn: String? {
        switch self {
        case .ble(let uuid):
            return uuid.isEmpty ? nil : "ble:" + uuid
        case .serial(_, let usbSerial, let vid, let pid):
            guard let usbSerial, !usbSerial.isEmpty else { return nil }
            return "adapter:" + Self.hex(vid ?? 0, pid ?? 0) + ":" + usbSerial
        case .usbHID, .usb, .classicBTSerial:
            return nil
        }
    }

    private static func hex(_ vid: UInt16, _ pid: UInt16) -> String {
        String(format: "%04x:%04x", vid, pid)
    }
}
