import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `DiveComputerIdentity` keys and `DiveComputerLocator`.
final class DiveComputerIdentityTests: XCTestCase {

    /// The host-side dedupe key the identity mirrors: serial first, else model, trimmed and lowercased.
    private func hostDeviceKey(serial: String?, model: String?) -> String? {
        if let serial = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !serial.isEmpty { return "sn:" + serial.lowercased() }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty { return "md:" + model.lowercased() }
        return nil
    }

    func testDeviceKeyIsTheSerialElseTheCanonicalName() {
        let withSerial = DiveComputerIdentity(family: .suuntoEonSteel, model: 2, serialNumber: 0x0012_ABCD, transport: .usbHID)
        XCTAssertEqual(withSerial.serial, "0012abcd")
        XCTAssertEqual(withSerial.deviceKey, "sn:0012abcd")
        XCTAssertEqual(withSerial.deviceKey, hostDeviceKey(serial: withSerial.serial, model: withSerial.canonicalName))

        let noSerial = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serialNumber: 0, transport: .serial)
        XCTAssertNil(noSerial.serial)
        XCTAssertEqual(noSerial.deviceKey, "md:" + noSerial.canonicalName.lowercased())
        XCTAssertEqual(noSerial.deviceKey, hostDeviceKey(serial: noSerial.serial, model: noSerial.canonicalName))
    }

    func testOneComputerKeysTheSameOverEveryTransport() {
        let ble = DiveComputerIdentity(family: .suuntoEonSteel, model: 2, serialNumber: 0x00C0FFEE, firmware: 7, transport: .ble)
        let usb = DiveComputerIdentity(family: .suuntoEonSteel, model: 2, serialNumber: 0x00C0FFEE, firmware: 9, transport: .usbHID)
        XCTAssertEqual(ble.deviceKey, usb.deviceKey)
        XCTAssertEqual(ble.storageKey(), usb.storageKey())
        XCTAssertEqual(ble.canonicalName, "Suunto D5")
        XCTAssertNotEqual(ble, usb, "the transport and firmware are still recorded")
    }

    func testTheStorageKeyCarriesTheFamilyButTheDeviceKeyDoesNot() {
        let suunto = DiveComputerIdentity(family: .suuntoEonSteel, model: 0, serial: "00001234", transport: .usbHID)
        let uwatec = DiveComputerIdentity(family: .uwatecSmart, model: 0x32, serial: "00001234", transport: .usbHID)
        XCTAssertEqual(suunto.deviceKey, uwatec.deviceKey)
        XCTAssertNotEqual(suunto.storageKey(), uwatec.storageKey())
        XCTAssertEqual(suunto.storageKey(), String(format: "dc:%08x:00001234", DC_FAMILY_SUUNTO_EONSTEEL.rawValue))
    }

    func testSerialZeroIsUnknown() {
        for serial in [nil, "", "   ", "0", "00000000", " 00000000 "] as [String?] {
            let identity = DiveComputerIdentity(family: .oceansS1, model: 0, serial: serial, transport: .ble)
            XCTAssertNil(identity.serial, String(describing: serial))
            XCTAssertNil(identity.storageKey(), "a model-only key would be shared by every unit")
            XCTAssertEqual(identity.devinfoSerial, "00000000")
        }
        let padded = DiveComputerIdentity(family: .oceansS1, model: 0, serial: " 0000ABCD\n", transport: .ble)
        XCTAssertEqual(padded.serial, "0000abcd")
    }

    func testAComputerWithNoSerialIsKeyedByItsStandIn() {
        let edy = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serialNumber: 0, transport: .serial)
        let adapterA = DiveComputerLocator.serial(path: "/dev/cu.usbserial-1", usbSerial: "STANDIN-A", vid: 0x0403, pid: 0x6001)
        let adapterB = DiveComputerLocator.serial(path: "/dev/cu.usbserial-1", usbSerial: "STANDIN-B", vid: 0x0403, pid: 0x6001)
        let keyA = edy.storageKey(standIn: adapterA.unitStandIn)
        XCTAssertEqual(keyA, "md:" + edy.canonicalName.lowercased() + "@adapter:0403:6001:STANDIN-A")
        XCTAssertNotEqual(keyA, edy.storageKey(standIn: adapterB.unitStandIn))
        XCTAssertNil(edy.storageKey(standIn: ""))

        let withSerial = DiveComputerIdentity(family: .suuntoVyper, model: 0x0A, serial: "00000042", transport: .serial)
        XCTAssertEqual(withSerial.storageKey(standIn: adapterA.unitStandIn), withSerial.storageKey(), "a real serial wins over a stand-in")
    }

    func testFirmwareZeroIsUnreported() {
        XCTAssertNil(DiveComputerIdentity(family: .suuntoVyper, model: 0x0A, serialNumber: 1, firmware: 0, transport: .serial).firmware)
        XCTAssertEqual(DiveComputerIdentity(family: .suuntoVyper, model: 0x0A, serialNumber: 1, firmware: 42, transport: .serial).firmware, "42")
        XCTAssertNil(DiveComputerIdentity(family: .suuntoVyper, model: 0x0A, serial: "1", firmware: "", transport: .serial).firmware)
    }

    func testTheCanonicalNameDefaultsToTheCatalogs() {
        let console = DiveComputerIdentity(family: .uwatecSmart, model: 0x32, serial: "1", transport: .usbHID)
        XCTAssertEqual(console.canonicalName, "Scubapro G2")
        let named = DiveComputerIdentity(family: .uwatecSmart, model: 0x32, serial: "1", transport: .usbHID, canonicalName: "Custom")
        XCTAssertEqual(named.canonicalName, "Custom")
    }

    func testIdentityRoundTripsThroughJSON() throws {
        let identity = DiveComputerIdentity(family: .hwOstc3, model: 0x0A, serialNumber: 0x99, firmware: 3, transport: .serial)
        let decoded = try JSONDecoder().decode(DiveComputerIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(decoded.deviceKey, identity.deviceKey)
    }

    // MARK: - From DEVINFO

    private func deviceData(family: dc_family_t, descriptorModel: UInt32, devinfo: dc_event_devinfo_t?) throws -> UnsafeMutablePointer<device_data_t> {
        var descriptor: OpaquePointer?
        XCTAssertEqual(find_descriptor_by_model(&descriptor, family, descriptorModel), DC_STATUS_SUCCESS)
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.descriptor = try XCTUnwrap(descriptor)
        if let devinfo {
            data.pointee.devinfo = devinfo
            data.pointee.have_devinfo = 1
        }
        addTeardownBlock {
            dc_descriptor_free(data.pointee.descriptor)
            data.deinitialize(count: 1)
            data.deallocate()
        }
        return data
    }

    func testTheIdentityWaitsForDEVINFO() throws {
        let data = try deviceData(family: DC_FAMILY_SUUNTO_VYPER, descriptorModel: 0x0A, devinfo: nil)
        XCTAssertNil(DiveComputerIdentity(device: data, transport: .serial))
    }

    func testTheIdentityTakesTheReportedModelWhenADescriptorKnowsIt() throws {
        let data = try deviceData(family: DC_FAMILY_UWATEC_SMART, descriptorModel: 0x32,
                                  devinfo: dc_event_devinfo_t(model: 0x31, firmware: 5, serial: 0xABCDEF))
        let identity = try XCTUnwrap(DiveComputerIdentity(device: data, transport: .usbHID))
        XCTAssertEqual(identity.family, .uwatecSmart)
        XCTAssertEqual(identity.model, 0x31)
        XCTAssertEqual(identity.canonicalName, "Scubapro G2 TEK")
        XCTAssertEqual(identity.serial, "00abcdef")
        XCTAssertEqual(identity.firmware, "5")
        XCTAssertEqual(identity.transport, .usbHID)
    }

    func testAnUnknownOrUnreportedModelFallsBackToTheOpenedDescriptor() throws {
        XCTAssertFalse(DeviceConfiguration.hasDescriptor(family: DC_FAMILY_REEFNET_SENSUS, model: 7))
        let unknown = try deviceData(family: DC_FAMILY_REEFNET_SENSUS, descriptorModel: 1,
                                     devinfo: dc_event_devinfo_t(model: 7, firmware: 0, serial: 0x1234))
        XCTAssertEqual(DiveComputerIdentity(device: unknown, transport: .serial)?.model, 1)

        let unreported = try deviceData(family: DC_FAMILY_SUUNTO_EONSTEEL, descriptorModel: 2,
                                        devinfo: dc_event_devinfo_t(model: 0, firmware: 0, serial: 1))
        XCTAssertEqual(DiveComputerIdentity(device: unreported, transport: .usbHID)?.canonicalName, "Suunto D5")
    }

#if os(macOS)
    func testACobaltsReportedModelZeroIsTheCobalt1() throws {
        let data = try deviceData(family: DC_FAMILY_ATOMICS_COBALT, descriptorModel: 2,
                                  devinfo: dc_event_devinfo_t(model: 0, firmware: 0, serial: 12_345))
        let identity = try XCTUnwrap(DiveComputerIdentity(device: data, transport: .usb))
        XCTAssertEqual(identity.model, 0, "the driver reads the model off the computer")
        XCTAssertEqual(identity.canonicalName, "Atomic Aquatics Cobalt")
    }
#endif

    func testAReportedSerialZeroGivesNoSerial() throws {
        let data = try deviceData(family: DC_FAMILY_OCEANS_S1, descriptorModel: 0,
                                  devinfo: dc_event_devinfo_t(model: 0, firmware: 0, serial: 0))
        let identity = try XCTUnwrap(DiveComputerIdentity(device: data, transport: .ble))
        XCTAssertNil(identity.serial)
        XCTAssertEqual(identity.deviceKey, "md:oceans s1")
    }

    // MARK: - Locator

    func testLocatorKeysAndTransports() {
        let cases: [(DiveComputerLocator, DCTransport, String, String?)] = [
            (.ble(uuid: "6A1B"), .ble, "ble:6A1B", "ble:6A1B"),
            (.serial(path: "/dev/cu.usbserial-X", usbSerial: "FTX", vid: 0x0403, pid: 0xF680), .serial, "serial:FTX", "adapter:0403:f680:FTX"),
            (.serial(path: "/dev/cu.usbserial-X", usbSerial: nil, vid: nil, pid: nil), .serial, "serial:/dev/cu.usbserial-X", nil),
            (.serial(path: "/dev/cu.usbserial-X", usbSerial: "", vid: 0x0403, pid: 0x6001), .serial, "serial:/dev/cu.usbserial-X", nil),
            (.usbHID(vid: 0x1493, pid: 0x0030, registryID: 0x1000_0A2B), .usbHID, "usbhid:1493:0030:10000a2b", nil),
            (.usb(vid: 0x0471, pid: 0x0888, registryID: 0xFF), .usb, "usb:0471:0888:ff", nil),
            (.classicBTSerial(path: "/dev/cu.Petrel"), .classicBTSerial, "btserial:/dev/cu.Petrel", nil),
        ]
        for (locator, transport, key, standIn) in cases {
            XCTAssertEqual(locator.transport, transport, key)
            XCTAssertEqual(locator.locatorKey, key)
            XCTAssertEqual(locator.unitStandIn, standIn, key)
        }
    }

    func testLocatorRoundTripsThroughJSON() throws {
        let locators: [DiveComputerLocator] = [
            .ble(uuid: "U"), .serial(path: "/dev/cu.x", usbSerial: "S", vid: 1, pid: 2), .serial(path: "/dev/cu.y", usbSerial: nil, vid: nil, pid: nil),
            .usbHID(vid: 3, pid: 4, registryID: 5), .usb(vid: 6, pid: 7, registryID: 8), .classicBTSerial(path: "/dev/cu.z"),
        ]
        let decoded = try JSONDecoder().decode([DiveComputerLocator].self, from: JSONEncoder().encode(locators))
        XCTAssertEqual(decoded, locators)
    }
}
