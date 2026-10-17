import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `StoredDevice.transport` and `locator`, per-record decoding, fingerprint keys, and lookups across transports.
final class StoredDeviceTransportTests: XCTestCase {

    private static let storageKey = "com.libdc.storedDevices"

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.storedtransport.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// A store as 1.17.8 and 1.18.0 wrote it: no transport or locator, dates as reference-date seconds.
    private static let legacyJSON = """
    [{"uuid":"AAAAAAAA-0000-0000-0000-000000000001","name":"Perdix 2 Test","family":"shearwaterPetrel","model":11,\
    "lastConnected":800000000,"serial":"0badf00d","firmware":"89"},\
    {"uuid":"AAAAAAAA-0000-0000-0000-000000000002","name":"Suunto Ocean Test","family":"suuntoNautic","model":1,\
    "lastConnected":800000100}]
    """

    private func storage(json: String, _ name: String) -> (DeviceStorage, UserDefaults) {
        let defaults = isolatedSuite(name)
        defaults.set(Data(json.utf8), forKey: Self.storageKey)
        return (DeviceStorage(userDefaults: defaults, fingerprints: DeviceFingerprintStorage(userDefaults: isolatedSuite(name + "fp"))), defaults)
    }

    // MARK: - Decoding

    func testLegacyRecordsDecodeAsBLE() throws {
        let (storage, _) = storage(json: Self.legacyJSON, "legacy")
        let perdix = try XCTUnwrap(storage.getStoredDevice(uuid: "AAAAAAAA-0000-0000-0000-000000000001"))
        XCTAssertNil(perdix.transport)
        XCTAssertEqual(perdix.effectiveTransport, .ble)
        XCTAssertNil(perdix.locator)
        XCTAssertEqual(perdix.family, .shearwaterPetrel)
        XCTAssertEqual(perdix.model, 11)
        XCTAssertEqual(perdix.serial, "0badf00d")
        XCTAssertEqual(perdix.firmware, "89")
        XCTAssertEqual(perdix.lastConnected, Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(storage.getStoredDevice(uuid: "AAAAAAAA-0000-0000-0000-000000000002")?.effectiveTransport, .ble)
        XCTAssertEqual(storage.getAllStoredDevices()?.count, 2)
    }

    func testARecordWithoutATransportEncodesAsBefore() throws {
        let device = StoredDevice(uuid: "U", name: "N", family: .suuntoNautic, model: 1, serial: "s", firmware: "f")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["uuid", "name", "family", "model", "lastConnected", "serial", "firmware"])
    }

    func testTransportAndLocatorRoundTrip() throws {
        let device = StoredDevice(uuid: "dc:00010005:00c0ffee", name: "Suunto D5", family: .suuntoEonSteel, model: 2, serial: "00c0ffee",
                                  transport: .usbHID, locator: .usbHID(vid: 0x1493, pid: 0x0035, registryID: 1))
        let decoded = try JSONDecoder().decode(StoredDevice.self, from: JSONEncoder().encode(device))
        XCTAssertEqual(decoded.transport, .usbHID)
        XCTAssertEqual(decoded.effectiveTransport, .usbHID)
        XCTAssertEqual(decoded.locator, .usbHID(vid: 0x1493, pid: 0x0035, registryID: 1))
        XCTAssertEqual(decoded.locatorKey, "usbhid:1493:0035:1")
        XCTAssertEqual(decoded.lastConnected, device.lastConnected)
    }

    func testALocatorThisVersionCantReadDropsOnlyTheLocator() {
        let json = """
        [{"uuid":"U1","name":"A","family":"suuntoVyper","model":10,"lastConnected":1,"transport":"serial",        "locator":{"thunderbolt":{"port":"3"}}}]
        """
        let (storage, _) = storage(json: json, "futureLocator")
        XCTAssertEqual(storage.getStoredDevice(uuid: "U1")?.transport, .serial)
        XCTAssertNil(storage.getStoredDevice(uuid: "U1")?.locator)
    }

    func testAnUnknownFamilyDropsOnlyThatRecord() {
        let json = """
        [{"uuid":"U1","name":"A","family":"shearwaterPetrel","model":5,"lastConnected":1},\
        {"uuid":"U2","name":"B","family":"someFutureFamily","model":1,"lastConnected":2},\
        {"uuid":"U3","name":"C","family":"suuntoVyper","model":10,"lastConnected":3,"transport":"serial"}]
        """
        let (storage, _) = storage(json: json, "unknownFamily")
        XCTAssertNotNil(storage.getStoredDevice(uuid: "U1"))
        XCTAssertNil(storage.getStoredDevice(uuid: "U2"))
        XCTAssertEqual(storage.getStoredDevice(uuid: "U3")?.transport, .serial)
        XCTAssertEqual(storage.getAllStoredDevices()?.map(\.uuid), ["U1", "U3"])
    }

    func testAnUnknownTransportOrAMissingFieldDropsOnlyThatRecord() {
        let json = """
        [{"uuid":"U1","name":"A","family":"shearwaterPetrel","model":5,"lastConnected":1,"transport":"wifi"},\
        {"uuid":"U2","name":"B","family":"suuntoNautic","lastConnected":2},\
        {"uuid":"U3","name":"C","family":"suuntoNautic","model":1,"lastConnected":3}]
        """
        let (storage, _) = storage(json: json, "unknownTransport")
        XCTAssertEqual(storage.getAllStoredDevices()?.map(\.uuid), ["U3"])
        XCTAssertNotNil(storage.getStoredDevice(uuid: "U3"))
    }

    func testAStoreThatIsntAnArrayLoadsEmpty() {
        let (storage, _) = storage(json: "{\"not\":\"an array\"}", "corrupt")
        XCTAssertNil(storage.getLastConnectedDevice())
        XCTAssertNil(storage.getAllStoredDevices())
    }

    func testSavingAfterADroppedRecordKeepsTheReadableOnes() {
        let json = """
        [{"uuid":"U1","name":"A","family":"shearwaterPetrel","model":5,"lastConnected":1},\
        {"uuid":"U2","name":"B","family":"someFutureFamily","model":1,"lastConnected":2}]
        """
        let (storage, defaults) = storage(json: json, "resave")
        storage.storeDevice(uuid: "U3", name: "C", family: .suuntoNautic, model: 1)
        let reloaded = DeviceStorage(userDefaults: defaults, fingerprints: DeviceFingerprintStorage(userDefaults: isolatedSuite("resavefp")))
        XCTAssertEqual(reloaded.getAllStoredDevices()?.map(\.uuid), ["U1", "U3"])
    }

    private static func adapter(_ usbSerial: String?) -> DiveComputerLocator {
        .serial(path: "/dev/cu.usbserial-TEST", usbSerial: usbSerial, vid: 0x0403, pid: 0x6001)
    }

    // MARK: - storeDevice

    func testStoringAgainKeepsTransportAndLocatorUnlessGiven() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("store"))
        storage.storeDevice(uuid: "K", name: "Suunto Vyper", family: .suuntoVyper, model: 0x0A, serial: "00000042",
                            transport: .serial, locator: Self.adapter("ADAPTER-1"))
        storage.storeDevice(uuid: "K", name: "Suunto Vyper", family: .suuntoVyper, model: 0x0A)
        XCTAssertEqual(storage.getStoredDevice(uuid: "K")?.transport, .serial)
        XCTAssertEqual(storage.getStoredDevice(uuid: "K")?.locatorKey, "serial:ADAPTER-1")
        XCTAssertEqual(storage.getStoredDevice(uuid: "K")?.serial, "00000042")

        storage.storeDevice(uuid: "K", name: "Suunto Vyper", family: .suuntoVyper, model: 0x0A, locator: Self.adapter("ADAPTER-2"))
        XCTAssertEqual(storage.getStoredDevice(uuid: "K")?.locatorKey, "serial:ADAPTER-2")
        XCTAssertEqual(storage.getStoredDevice(uuid: "K")?.transport, .serial)
    }

    // MARK: - storedDevice(family:serial:)

    func testTheSameComputerIsFoundAcrossTransports() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("across"))
        storage.storeDevice(uuid: "BLE-UUID", name: "Suunto D5", family: .suuntoEonSteel, model: 2, serial: "00c0ffee")
        XCTAssertEqual(storage.storedDevice(family: .suuntoEonSteel, serial: "00C0FFEE")?.uuid, "BLE-UUID", "serials compare lowercased")

        storage.storeDevice(uuid: "dc:hid", name: "Suunto D5", family: .suuntoEonSteel, model: 2, serial: "00c0ffee", transport: .usbHID)
        XCTAssertEqual(storage.storedDevice(family: .suuntoEonSteel, serial: "00c0ffee")?.uuid, "dc:hid", "the most recent connection")
        XCTAssertNil(storage.storedDevice(family: .uwatecSmart, serial: "00c0ffee"), "another family's serial is another computer")
        XCTAssertNil(storage.storedDevice(family: .suuntoEonSteel, serial: "00c0ffef"))
    }

    func testAnUnknownSerialMatchesNothing() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("zero"))
        storage.storeDevice(uuid: "S1-A", name: "Oceans S1", family: .oceansS1, model: 0, serial: "00000000")
        XCTAssertNil(storage.storedDevice(family: .oceansS1, serial: "00000000"))
        XCTAssertNil(storage.storedDevice(family: .oceansS1, serial: ""))
    }

    func testTheSessionPathStoresANewRecordWithItsTransportAndLocator() throws {
        let storage = DeviceStorage(userDefaults: isolatedSuite("hardware"))
        let ptr = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        ptr.initialize(to: device_data_t())
        defer { ptr.deallocate() }
        ptr.pointee.have_devinfo = 1
        ptr.pointee.devinfo.model = 8
        let locator = DiveComputerLocator.classicBTSerial(path: "/dev/cu.Perdix-Test")
        XCTAssertNotEqual(DeviceConfiguration.fromName("Perdix Test")?.model, 8)
        DeviceConfiguration.updateDeviceConfigurationFromHardware(
            deviceAddress: "btserial:test", deviceDataPtr: ptr, deviceName: "Perdix Test", storage: storage,
            requireKnownModel: true, transport: .classicBTSerial, locator: locator)
        let stored = try XCTUnwrap(storage.getStoredDevice(uuid: "btserial:test"), "the hardware's model differs from the name's")
        XCTAssertEqual(stored.family, .shearwaterPetrel)
        XCTAssertEqual(stored.model, 8)
        XCTAssertEqual(stored.transport, .classicBTSerial, "not read as BLE, so reconcileUUID leaves it alone")
        XCTAssertEqual(stored.locator, locator)
        XCTAssertFalse(storage.reconcileUUID(name: "Perdix Test", newUUID: "PERIPHERAL"))
    }

    // MARK: - Fingerprint key

    func testASerialZeroCableRecordKeysItsFingerprintByItsAdapter() {
        let device = StoredDevice(uuid: "serial:edy", name: "Cressi Edy", family: .cressiEdy, model: 0x08, serial: "00000000",
                                  transport: .serial, locator: Self.adapter("TEST-ADAPTER-1"))
        let identity = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serial: nil, transport: .serial)
        XCTAssertEqual(device.fingerprintStorageKey, identity.storageKey(standIn: Self.adapter("TEST-ADAPTER-1").unitStandIn))
        XCTAssertTrue(device.fingerprintStorageKey?.hasSuffix("@adapter:0403:6001:TEST-ADAPTER-1") == true)

        let noSerialAdapter = StoredDevice(uuid: "serial:edy", name: "Cressi Edy", family: .cressiEdy, model: 0x08,
                                           transport: .serial, locator: Self.adapter(nil))
        XCTAssertNil(noSerialAdapter.fingerprintStorageKey, "nothing outlives a replug, so nothing was stored")
        XCTAssertNil(StoredDevice(uuid: "serial:edy", name: "Cressi Edy", family: .cressiEdy, model: 0x08, transport: .serial)
            .fingerprintStorageKey)
    }

    func testABLERecordStandsInWithItsLocatorElseItsUUID() {
        let identity = DiveComputerIdentity(family: .oceansS1, model: 0, serial: nil, transport: .ble)
        let legacy = StoredDevice(uuid: "PERIPHERAL-1", name: "Oceans S1", family: .oceansS1, model: 0, serial: "00000000")
        XCTAssertEqual(legacy.fingerprintStorageKey, identity.storageKey(standIn: "ble:PERIPHERAL-1"))
        let located = StoredDevice(uuid: "PERIPHERAL-2", name: "Oceans S1", family: .oceansS1, model: 0, serial: "00000000",
                                   transport: .ble, locator: .ble(uuid: "PERIPHERAL-1"))
        XCTAssertEqual(located.fingerprintStorageKey, identity.storageKey(standIn: "ble:PERIPHERAL-1"), "the locator the fingerprint was keyed by")
    }

    func testRemovingASerialZeroCableDeviceClearsItsAdapterKeyedFingerprint() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("removeCableFp"))
        let storage = DeviceStorage(userDefaults: isolatedSuite("removeCable"), fingerprints: fingerprints)
        let locator = Self.adapter("TEST-ADAPTER-1")
        storage.storeDevice(uuid: "serial:edy", name: "Cressi Edy", family: .cressiEdy, model: 0x08, serial: "00000000",
                            transport: .serial, locator: locator)
        let identity = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serial: nil, transport: .serial)
        fingerprints.saveFingerprint(Data([1, 2, 3, 4]), for: identity, standIn: locator.unitStandIn)
        let other = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serial: nil, transport: .serial)
        fingerprints.saveFingerprint(Data([5, 6, 7, 8]), for: other, standIn: Self.adapter("TEST-ADAPTER-2").unitStandIn)
        XCTAssertEqual(fingerprints.loadFingerprints().count, 2)

        storage.removeDevice(uuid: "serial:edy")
        XCTAssertEqual(fingerprints.loadFingerprints().map(\.fingerprint), [Data([5, 6, 7, 8])], "another adapter's unit stays")
    }

    // MARK: - reconcileUUID

    func testReconcileLeavesCableRecordsAlone() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("reconcileCable"))
        storage.storeDevice(uuid: "dc:hid", name: "Suunto D5", family: .suuntoEonSteel, model: 2, serial: "1", transport: .usbHID)
        XCTAssertFalse(storage.reconcileUUID(name: "Suunto D5", newUUID: "PERIPHERAL"))
        XCTAssertNotNil(storage.getStoredDevice(uuid: "dc:hid"))
        XCTAssertNil(storage.getStoredDevice(uuid: "PERIPHERAL"))
    }

    func testReconcileMovesTheBLERecordOfTheSameName() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("reconcileBoth"))
        storage.storeDevice(uuid: "dc:hid", name: "Suunto D5", family: .suuntoEonSteel, model: 2, serial: "1", transport: .usbHID,
                            locator: .usbHID(vid: 0x1493, pid: 0x0035, registryID: 1))
        storage.storeDevice(uuid: "OLD-PERIPHERAL", name: "Suunto D5", family: .suuntoEonSteel, model: 2, serial: "1", transport: .ble,
                            locator: .ble(uuid: "OLD-PERIPHERAL"))
        XCTAssertTrue(storage.reconcileUUID(name: "Suunto D5", newUUID: "NEW-PERIPHERAL"))
        XCTAssertNotNil(storage.getStoredDevice(uuid: "dc:hid"), "the cable record isn't the one that moved")
        XCTAssertNil(storage.getStoredDevice(uuid: "OLD-PERIPHERAL"))
        let moved = storage.getStoredDevice(uuid: "NEW-PERIPHERAL")
        XCTAssertEqual(moved?.transport, .ble)
        XCTAssertEqual(moved?.locatorKey, "ble:OLD-PERIPHERAL")
    }

    func testReconcileStillMovesALegacyRecord() {
        let (storage, _) = storage(json: Self.legacyJSON, "reconcileLegacy")
        XCTAssertTrue(storage.reconcileUUID(name: "Suunto Ocean Test", newUUID: "NEW"))
        XCTAssertNil(storage.getStoredDevice(uuid: "NEW")?.transport, "still a legacy BLE record")
        XCTAssertEqual(storage.getStoredDevice(uuid: "NEW")?.effectiveTransport, .ble)
    }
}
