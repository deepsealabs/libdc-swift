import Foundation
import Clibdivecomputer
import LibDCBridge

/// One libdivecomputer descriptor: a model a host can offer, with the transports this library reaches it on.
public struct DCModel: Hashable, Identifiable, Sendable {
    public let vendor: String
    public let product: String
    public let family: DeviceConfiguration.DeviceFamily
    public let model: UInt32
    /// The descriptor's transports that have a `DCTransport` case; IrDA and RFCOMM sockets have none.
    public let transports: Set<DCTransport>
    /// The name an identity of this family and model carries (`DeviceCatalog.canonicalName`), so a G2 Console's is "Scubapro G2".
    public let canonicalName: String

    /// "Vendor Product", as `find_descriptor_by_name_transport` matches it on cable transports.
    public var name: String { "\(vendor) \(product)" }
    /// Family, model and name, since several products share a family and model; stable across library versions.
    public var id: String { Self.id(family: family, model: model, name: name) }
    public var dcFamily: dc_family_t { family.asDCFamily }
}

/// The models libdivecomputer knows, read from its descriptor table at runtime.
public enum DeviceCatalog {
    /// Every descriptor of a known family, in libdivecomputer's table order.
    public static let all: [DCModel] = {
        let entries = descriptorEntries()
        return entries.compactMap { entry in
            guard let family = entry.family else { return nil }
            return DCModel(vendor: entry.vendor, product: entry.product, family: family, model: entry.model,
                           transports: transports(mask: entry.mask, family: family),
                           canonicalName: canonicalName(family: family, model: entry.model,
                                                        descriptors: entries.lazy.map { ($0.family, $0.model, $0.name) }))
        }
    }()

    /// The models offered on `transport`, in table order; `.serial` leaves out Shearwater's paired-Bluetooth ports (`.classicBTSerial`).
    public static func models(for transport: DCTransport) -> [DCModel] {
        all.filter { $0.transports.contains(transport) }
    }

    /// First `supportedModels` match, else first descriptor, else "<family> model <n>", since family and model don't name one product (see Docs/DEVICE_IDENTITY.md).
    public static func canonicalName(family: DeviceConfiguration.DeviceFamily, model: UInt32) -> String {
        canonicalName(family: family, model: model, descriptors: all.lazy.map { (Optional($0.family), $0.model, $0.name) })
    }

    /// The models a USB or USB HID device can be: libdivecomputer's family filter, narrowed by `usbModels`; empty on other transports.
    public static func candidates(vid: UInt16, pid: UInt16, transport: DCTransport) -> [DCModel] {
        guard transport == .usbHID || transport == .usb else { return [] }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var matches: [DCModel] = []
        forEachDescriptor { descriptor in
            let passes: Int32
            if transport == .usbHID {
                var desc = dc_usbhid_desc_t(vid: vid, pid: pid)
                passes = dc_descriptor_filter(descriptor, transport.dcValue, &desc)
            } else {
                var desc = dc_usb_desc_t(vid: vid, pid: pid)
                passes = dc_descriptor_filter(descriptor, transport.dcValue, &desc)
            }
            guard passes != 0, let entry = Entry(descriptor), let family = entry.family,
                  let model = byID[DCModel.id(family: family, model: entry.model, name: entry.name)] else { return }
            matches.append(model)
        }
        guard let names = usbModels[usbKey(vid: vid, pid: pid)] else { return matches }
        return matches.filter { names.contains($0.name) }
    }

    /// The products each VID:PID is: the family filters accept any PID of the family, and EON Steel reports the descriptor's model as its own.
    static let usbModels: [UInt32: Set<String>] = [
        usbKey(vid: 0x1493, pid: 0x0030): ["Suunto EON Steel"],
        usbKey(vid: 0x1493, pid: 0x0033): ["Suunto EON Core"],
        usbKey(vid: 0x1493, pid: 0x0035): ["Suunto D5"],
        usbKey(vid: 0x1493, pid: 0x0036): ["Suunto EON Steel Black"],
        usbKey(vid: 0x2e6c, pid: 0x3201): ["Scubapro G2", "Scubapro G2 TEK"],
        usbKey(vid: 0x2e6c, pid: 0x3211): ["Scubapro G2 Console"],
        usbKey(vid: 0x2e6c, pid: 0x4201): ["Scubapro G2 HUD"],
        usbKey(vid: 0xc251, pid: 0x2006): ["Scubapro Aladin Square"],
    ]

    static func usbKey(vid: UInt16, pid: UInt16) -> UInt32 { UInt32(vid) << 16 | UInt32(pid) }

    /// The family a stored device-type name belongs to: a `supportedModels` name, a descriptor's "Vendor Product", or an advertised BLE name.
    static func family(forName name: String) -> DeviceConfiguration.DeviceFamily? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        if let supported = DeviceConfiguration.supportedModels.first(where: { normalized($0.name) == wanted }) {
            return supported.family
        }
        if let model = all.first(where: { normalized($0.name) == wanted }) {
            return model.family
        }
        return DeviceConfiguration.fromName(name)?.family
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    // Shearwater has no cable: its SERIAL descriptors are the paired classic-Bluetooth SPP port.
    private static func transports(mask: UInt32, family: DeviceConfiguration.DeviceFamily) -> Set<DCTransport> {
        var transports = Set<DCTransport>()
        func has(_ transport: dc_transport_t) -> Bool { mask & transport.rawValue != 0 }
        if has(DC_TRANSPORT_BLE) { transports.insert(.ble) }
        if has(DC_TRANSPORT_USBHID) { transports.insert(.usbHID) }
        if has(DC_TRANSPORT_USB) { transports.insert(.usb) }
        if has(DC_TRANSPORT_SERIAL) {
            let pairedPort = has(DC_TRANSPORT_BLUETOOTH) && (family == .shearwaterPetrel || family == .shearwaterPredator)
            transports.insert(pairedPort ? .classicBTSerial : .serial)
        }
        return transports
    }

    private static func canonicalName(family: DeviceConfiguration.DeviceFamily, model: UInt32,
                                      descriptors: some Sequence<(DeviceConfiguration.DeviceFamily?, UInt32, String)>) -> String {
        if let supported = DeviceConfiguration.supportedModels.first(where: { $0.family == family && $0.modelID == model }) {
            return supported.name
        }
        return descriptors.first { $0.0 == family && $0.1 == model }?.2 ?? "\(family.rawValue) model \(model)"
    }

    private struct Entry {
        let vendor: String
        let product: String
        let family: DeviceConfiguration.DeviceFamily?
        let model: UInt32
        let mask: UInt32
        var name: String { "\(vendor) \(product)" }

        init?(_ descriptor: OpaquePointer) {
            guard let vendor = dc_descriptor_get_vendor(descriptor), let product = dc_descriptor_get_product(descriptor) else { return nil }
            self.vendor = String(cString: vendor)
            self.product = String(cString: product)
            family = DeviceConfiguration.DeviceFamily(dcFamily: dc_descriptor_get_type(descriptor))
            model = dc_descriptor_get_model(descriptor)
            mask = dc_descriptor_get_transports(descriptor)
        }
    }

    private static func descriptorEntries() -> [Entry] {
        var entries: [Entry] = []
        forEachDescriptor { descriptor in
            if let entry = Entry(descriptor) { entries.append(entry) }
        }
        return entries
    }

    private static func forEachDescriptor(_ body: (OpaquePointer) -> Void) {
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS, let iterator else {
            logError("Couldn't read libdivecomputer's descriptor table")
            return
        }
        defer { dc_iterator_free(iterator) }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS {
            guard let current = descriptor else { continue }
            body(current)
            dc_descriptor_free(current)
            descriptor = nil
        }
    }
}

extension DCModel {
    static func id(family: DeviceConfiguration.DeviceFamily, model: UInt32, name: String) -> String {
        "\(family.rawValue):\(model):\(name)"
    }
}
