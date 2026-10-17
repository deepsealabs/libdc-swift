import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `DeviceCatalog` against libdivecomputer's descriptor table, `DCTransport` and `DeviceFamily`.
final class DeviceCatalogTests: XCTestCase {

    private struct RawDescriptor {
        let name: String
        let family: dc_family_t
        let model: UInt32
        let transports: UInt32
    }

    private static let rawDescriptors: [RawDescriptor] = {
        var rows: [RawDescriptor] = []
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS else { return rows }
        defer { dc_iterator_free(iterator) }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS, let current = descriptor {
            rows.append(RawDescriptor(
                name: String(cString: dc_descriptor_get_vendor(current)) + " " + String(cString: dc_descriptor_get_product(current)),
                family: dc_descriptor_get_type(current), model: dc_descriptor_get_model(current),
                transports: dc_descriptor_get_transports(current)))
            dc_descriptor_free(current)
            descriptor = nil
        }
        return rows
    }()

    private func names(_ models: [DCModel]) -> [String] { models.map(\.name) }

    // MARK: - Catalog

    func testTheCatalogHoldsEveryDescriptorInTableOrder() {
        XCTAssertEqual(Self.rawDescriptors.count, 359)
        XCTAssertEqual(names(DeviceCatalog.all), Self.rawDescriptors.map(\.name), "every family is known, so none is skipped")
        for (model, raw) in zip(DeviceCatalog.all, Self.rawDescriptors) {
            XCTAssertEqual(model.dcFamily, raw.family, model.name)
            XCTAssertEqual(model.model, raw.model, model.name)
        }
    }

    func testCableCatalogCounts() {
        let serialDescriptors = Self.rawDescriptors.filter { $0.transports & DC_TRANSPORT_SERIAL.rawValue != 0 }
        XCTAssertEqual(serialDescriptors.count, 288)
        XCTAssertEqual(DeviceCatalog.models(for: .serial).count, 283, "288 SERIAL descriptors less Shearwater's 5 paired-Bluetooth ports")
        XCTAssertEqual(DeviceCatalog.models(for: .usbHID).count, 10)
        XCTAssertEqual(DeviceCatalog.models(for: .usb).count, 2)
        XCTAssertEqual(DeviceCatalog.models(for: .classicBTSerial).count, 5)
        let bleDescriptors = Self.rawDescriptors.filter { $0.transports & DC_TRANSPORT_BLE.rawValue != 0 }
        XCTAssertEqual(names(DeviceCatalog.models(for: .ble)), bleDescriptors.map(\.name))
    }

    func testShearwatersSerialPortsAreClassicBluetoothNotCable() {
        XCTAssertEqual(names(DeviceCatalog.models(for: .classicBTSerial)),
                       ["Shearwater Predator", "Shearwater Petrel", "Shearwater Petrel 2", "Shearwater Nerd", "Shearwater Perdix"])
        let serial = Set(names(DeviceCatalog.models(for: .serial)))
        XCTAssertFalse(serial.contains { $0.hasPrefix("Shearwater") })
        let perdix = DeviceCatalog.all.first { $0.name == "Shearwater Perdix" }
        XCTAssertEqual(perdix?.transports, [.classicBTSerial, .ble])
        // Other SERIAL | BLUETOOTH descriptors have a cable.
        XCTAssertTrue(serial.contains("Heinrichs Weikamp OSTC 3"))
        XCTAssertTrue(serial.contains("Ratio iX3M GPS Easy"))
    }

    func testIrDAOnlyModelsHaveNoTransport() {
        let smartPro = DeviceCatalog.all.first { $0.name == "Uwatec Smart Pro" }
        XCTAssertEqual(smartPro?.transports, [])
    }

    func testIDsAreUniqueAndStable() {
        let ids = DeviceCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(DeviceCatalog.all.first { $0.name == "Scubapro G2 Console" }?.id, "uwatecSmart:50:Scubapro G2 Console")
    }

    func testEveryModelResolvesItsDescriptor() {
        // The session's open and its parse look the model up again.
        for model in DeviceCatalog.all {
            XCTAssertTrue(DeviceConfiguration.hasDescriptor(family: model.dcFamily, model: model.model), model.name)
        }
    }

    // MARK: - Canonical name

    func testCanonicalNameIsTheFirstTableMatch() {
        XCTAssertEqual(DeviceCatalog.canonicalName(family: .uwatecSmart, model: 0x32), "Scubapro G2", "G2 and G2 Console share 0x32")
        XCTAssertEqual(DeviceCatalog.canonicalName(family: .shearwaterPetrel, model: 3), "Shearwater Petrel", "Petrel and Petrel 2 share 3")
        XCTAssertEqual(DeviceCatalog.all.first { $0.name == "Scubapro G2 Console" }?.canonicalName, "Scubapro G2")
        XCTAssertEqual(DeviceCatalog.canonicalName(family: .suuntoNautic, model: 1), "Suunto Ocean")
        XCTAssertEqual(DeviceCatalog.canonicalName(family: .suuntoVyper, model: 0x0A), "Suunto Vyper")
        XCTAssertEqual(DeviceCatalog.canonicalName(family: .suuntoNautic, model: 99), "suuntoNautic model 99")
    }

    func testSupportedModelsNamesComeBeforeTheDescriptorTable() {
        for supported in DeviceConfiguration.supportedModels {
            let first = DeviceConfiguration.supportedModels.first { $0.family == supported.family && $0.modelID == supported.modelID }
            XCTAssertEqual(DeviceCatalog.canonicalName(family: supported.family, model: supported.modelID), first?.name, supported.name)
        }
        for model in DeviceCatalog.all
        where !DeviceConfiguration.supportedModels.contains(where: { $0.family == model.family && $0.modelID == model.model }) {
            let first = Self.rawDescriptors.first { $0.family == model.dcFamily && $0.model == model.model }
            XCTAssertEqual(model.canonicalName, first?.name, model.name)
        }
    }

    // MARK: - USB candidates

    func testEachUSBHIDProductIDNamesItsModels() {
        let expected: [(UInt16, UInt16, [String])] = [
            (0x1493, 0x0030, ["Suunto EON Steel"]),
            (0x1493, 0x0033, ["Suunto EON Core"]),
            (0x1493, 0x0035, ["Suunto D5"]),
            (0x1493, 0x0036, ["Suunto EON Steel Black"]),
            (0x2e6c, 0x3201, ["Scubapro G2 TEK", "Scubapro G2"]),
            (0x2e6c, 0x3211, ["Scubapro G2 Console"]),
            (0x2e6c, 0x4201, ["Scubapro G2 HUD"]),
            (0xc251, 0x2006, ["Scubapro Aladin Square"]),
        ]
        for (vid, pid, models) in expected {
            XCTAssertEqual(names(DeviceCatalog.candidates(vid: vid, pid: pid, transport: .usbHID)), models,
                           String(format: "%04x:%04x", vid, pid))
        }
    }

    func testTheFamilyFilterAloneMatchesTheWholeFamily() {
        // Why the PID table exists: libdivecomputer accepts any of the family's PIDs for every model in it.
        var desc = dc_usbhid_desc_t(vid: 0x1493, pid: 0x0030)
        var matches: [String] = []
        var iterator: OpaquePointer?
        XCTAssertEqual(dc_descriptor_iterator_new(&iterator, nil), DC_STATUS_SUCCESS)
        defer { dc_iterator_free(iterator) }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS, let current = descriptor {
            if dc_descriptor_filter(current, DC_TRANSPORT_USBHID, &desc) != 0 {
                matches.append(String(cString: dc_descriptor_get_vendor(current)) + " " + String(cString: dc_descriptor_get_product(current)))
            }
            descriptor = nil
        }
        XCTAssertEqual(matches, ["Suunto EON Steel", "Suunto EON Core", "Suunto D5", "Suunto EON Steel Black"])
    }

    func testAnUnlistedProductIDOrTheWrongTransportMatchesNothing() {
        XCTAssertEqual(DeviceCatalog.candidates(vid: 0x2e6c, pid: 0x9999, transport: .usbHID), [], "G3's PID isn't in libdivecomputer's table")
        XCTAssertEqual(DeviceCatalog.candidates(vid: 0x1493, pid: 0x0030, transport: .usb), [])
        XCTAssertEqual(DeviceCatalog.candidates(vid: 0x1493, pid: 0x0030, transport: .serial), [])
        XCTAssertEqual(DeviceCatalog.candidates(vid: 0x0403, pid: 0xf680, transport: .serial), [], "serial descriptors have no filter")
        XCTAssertEqual(DeviceCatalog.candidates(vid: 0x1234, pid: 0x5678, transport: .usbHID), [])
    }

    func testCobaltsShareOneUSBID() {
        XCTAssertEqual(names(DeviceCatalog.candidates(vid: 0x0471, pid: 0x0888, transport: .usb)),
                       ["Atomic Aquatics Cobalt", "Atomic Aquatics Cobalt 2"])
    }

    func testEveryPIDTableNameIsAUSBHIDModel() {
        let hid = Set(names(DeviceCatalog.models(for: .usbHID)))
        for name in DeviceCatalog.usbModels.values.flatMap({ $0 }) {
            XCTAssertTrue(hid.contains(name), name)
        }
    }

    // MARK: - Family names

    func testStoredDeviceTypeNamesResolveToTheirFamily() {
        XCTAssertEqual(DeviceCatalog.family(forName: "Shearwater Perdix"), .shearwaterPetrel)
        XCTAssertEqual(DeviceCatalog.family(forName: "  scubapro g2 console "), .uwatecSmart)
        XCTAssertEqual(DeviceCatalog.family(forName: "Suunto Ocean"), .suuntoNautic)
        XCTAssertEqual(DeviceCatalog.family(forName: "Suunto Vyper"), .suuntoVyper)
        XCTAssertEqual(DeviceCatalog.family(forName: "Petrel 3"), .shearwaterPetrel, "an advertised BLE name")
        XCTAssertNil(DeviceCatalog.family(forName: "Not A Dive Computer"))
        XCTAssertNil(DeviceCatalog.family(forName: ""))
    }

    // MARK: - DCTransport and CableSupport

    func testTransportsMapToLibdivecomputer() {
        XCTAssertEqual(DCTransport.ble.dcValue, DC_TRANSPORT_BLE)
        XCTAssertEqual(DCTransport.serial.dcValue, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(DCTransport.usbHID.dcValue, DC_TRANSPORT_USBHID)
        XCTAssertEqual(DCTransport.usb.dcValue, DC_TRANSPORT_USB)
        XCTAssertEqual(DCTransport.classicBTSerial.dcValue, DC_TRANSPORT_SERIAL, "a paired port opens as a serial port")
        for transport in DCTransport.allCases where transport != .classicBTSerial {
            XCTAssertEqual(DCTransport(dcValue: transport.dcValue), transport)
        }
        XCTAssertNil(DCTransport(dcValue: DC_TRANSPORT_IRDA))
        XCTAssertNil(DCTransport(dcValue: DC_TRANSPORT_BLUETOOTH))
        XCTAssertNil(DCTransport(dcValue: DC_TRANSPORT_NONE))
    }

    func testTransportRawValuesAreStable() {
        XCTAssertEqual(DCTransport.allCases.map(\.rawValue), ["ble", "serial", "usbhid", "usb", "btserial"])
    }

    func testCableSupportFollowsThePlatform() {
        #if os(macOS)
        XCTAssertEqual(CableSupport.transports, [.serial, .usbHID, .usb])
        #else
        XCTAssertEqual(CableSupport.transports, [])
        #endif
    }

    // MARK: - DeviceFamily

    func testEveryFamilyRoundTrips() throws {
        XCTAssertEqual(DeviceConfiguration.DeviceFamily.allCases.count, 47)
        let dcValues = DeviceConfiguration.DeviceFamily.allCases.map(\.asDCFamily)
        XCTAssertEqual(Set(dcValues.map(\.rawValue)).count, dcValues.count, "no two cases share a DC_FAMILY_*")
        for family in DeviceConfiguration.DeviceFamily.allCases {
            XCTAssertEqual(DeviceConfiguration.DeviceFamily(dcFamily: family.asDCFamily), family, family.rawValue)
            let data = try JSONEncoder().encode(family)
            XCTAssertEqual(try JSONDecoder().decode(DeviceConfiguration.DeviceFamily.self, from: data), family)
        }
        XCTAssertNil(DeviceConfiguration.DeviceFamily(dcFamily: DC_FAMILY_NULL))
    }

    func testEveryDescriptorFamilyHasACase() {
        for raw in Self.rawDescriptors {
            XCTAssertNotNil(DeviceConfiguration.DeviceFamily(dcFamily: raw.family), raw.name)
        }
    }

    func testTheExistingFamiliesKeepTheirStorageStrings() {
        let before: [DeviceConfiguration.DeviceFamily] = [
            .suuntoEonSteel, .shearwaterPetrel, .hwOstc3, .uwatecSmart, .oceanicAtom2, .pelagicI330R, .maresIconHD,
            .deepsixExcursion, .deepbluCosmiq, .oceansS1, .mcleanExtreme, .divesoftFreedom, .cressiGoa, .diveSystem,
            .seacScreen, .halcyonSymbios, .suuntoNautic,
        ]
        XCTAssertEqual(Array(DeviceConfiguration.DeviceFamily.allCases.prefix(before.count)), before)
        XCTAssertEqual(before.map(\.rawValue), [
            "suuntoEonSteel", "shearwaterPetrel", "hwOstc3", "uwatecSmart", "oceanicAtom2", "pelagicI330R", "maresIconHD",
            "deepsixExcursion", "deepbluCosmiq", "oceansS1", "mcleanExtreme", "divesoftFreedom", "cressiGoa", "diveSystem",
            "seacScreen", "halcyonSymbios", "suuntoNautic",
        ])
    }
}
