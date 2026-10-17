import XCTest
@testable import LibDCSwift

/// `DeviceStorage` and `DeviceFingerprintStorage` were `UserDefaults.standard`
/// singletons, so tests could only run against the real store and would pollute
/// each other. Both now take an injected `UserDefaults` suite (default
/// `.standard`, unchanged for every production call site, which all go through
/// `.shared`).
final class StorageInjectionTests: XCTestCase {

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    // MARK: - DeviceFingerprintStorage

    func testFingerprintRoundTripsThroughAnInjectedSuite() {
        let storage = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp1"))
        XCTAssertNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "deadbeef"))

        storage.saveFingerprint(Data([0x01, 0x02]), deviceType: "Suunto Ocean", serial: "deadbeef")
        let found = storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "deadbeef")
        XCTAssertEqual(found?.fingerprint, Data([0x01, 0x02]))
    }

    func testDeviceTypeLookupIsCaseAndWhitespaceInsensitive() {
        let storage = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp2"))
        storage.saveFingerprint(Data([0xAA]), deviceType: "Suunto Ocean", serial: "01020304")
        XCTAssertNotNil(storage.getFingerprint(forDeviceType: "  SUUNTO OCEAN  ", serial: "01020304"))
        XCTAssertNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "01020305"), "serial must still match exactly")
    }

    func testSavingReplacesTheExistingFingerprintForTheSameKey() {
        let storage = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp3"))
        storage.saveFingerprint(Data([0x01]), deviceType: "Shearwater Perdix", serial: "abc")
        storage.saveFingerprint(Data([0x02]), deviceType: "Shearwater Perdix", serial: "abc")
        XCTAssertEqual(storage.loadFingerprints().filter { $0.serial == "abc" }.count, 1, "re-saving must replace, not accumulate")
        XCTAssertEqual(storage.getFingerprint(forDeviceType: "Shearwater Perdix", serial: "abc")?.fingerprint, Data([0x02]))
    }

    func testClearFingerprintRemovesOnlyThatDeviceAndSerial() {
        let storage = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp4"))
        storage.saveFingerprint(Data([0x01]), deviceType: "Suunto Ocean", serial: "11")
        storage.saveFingerprint(Data([0x02]), deviceType: "Suunto Ocean", serial: "22")

        storage.clearFingerprint(forDeviceType: "Suunto Ocean", serial: "11")
        XCTAssertNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "11"))
        XCTAssertNotNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "22"))
    }

    func testClearFingerprintsForDeviceTypeRemovesEverySerial() {
        let storage = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp5"))
        storage.saveFingerprint(Data([0x01]), deviceType: "Suunto Ocean", serial: "11")
        storage.saveFingerprint(Data([0x02]), deviceType: "Suunto Ocean", serial: "22")
        storage.saveFingerprint(Data([0x03]), deviceType: "Suunto Nautic", serial: "33")

        storage.clearFingerprintsForDeviceType("Suunto Ocean")
        XCTAssertNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "11"))
        XCTAssertNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "22"))
        XCTAssertNotNil(storage.getFingerprint(forDeviceType: "Suunto Nautic", serial: "33"))
    }

    func testClearAllFingerprintsEmptiesTheSuite() {
        let storage = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp6"))
        storage.saveFingerprint(Data([0x01]), deviceType: "Suunto Ocean", serial: "11")
        storage.clearAllFingerprints()
        XCTAssertTrue(storage.loadFingerprints().isEmpty)
    }

    func testAnEmptyStoredFingerprintIsNeverReturned() {
        // getFingerprint filters out entries whose fingerprint bytes are empty
        // (DiveLogRetriever's lookup treats a nil fingerprint, not an empty one,
        // as "no stored fingerprint").
        let suite = isolatedSuite("fp7")
        let storage = DeviceFingerprintStorage(userDefaults: suite)
        storage.saveFingerprint(Data(), deviceType: "Suunto Ocean", serial: "11")
        XCTAssertNil(storage.getFingerprint(forDeviceType: "Suunto Ocean", serial: "11"))
    }

    func testTwoInjectedSuitesAreFullyIsolatedFromEachOther() {
        let storageA = DeviceFingerprintStorage(userDefaults: isolatedSuite("fpA"))
        let storageB = DeviceFingerprintStorage(userDefaults: isolatedSuite("fpB"))
        storageA.saveFingerprint(Data([0x01]), deviceType: "Suunto Ocean", serial: "11")
        XCTAssertNil(storageB.getFingerprint(forDeviceType: "Suunto Ocean", serial: "11"))
    }

    // MARK: - DeviceStorage

    func testStoreAndGetRoundTripsThroughAnInjectedSuite() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev1"))
        XCTAssertNil(storage.getStoredDevice(uuid: "UUID-1"))

        storage.storeDevice(uuid: "UUID-1", name: "Suunto Ocean 123", family: .suuntoNautic, model: 1, serial: "0badf00d")
        let stored = storage.getStoredDevice(uuid: "UUID-1")
        XCTAssertEqual(stored?.name, "Suunto Ocean 123")
        XCTAssertEqual(stored?.family, .suuntoNautic)
        XCTAssertEqual(stored?.model, 1)
        XCTAssertEqual(stored?.serial, "0badf00d")
    }

    func testStoringAgainPreservesSerialAndFirmwareWhenNotProvided() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev2"))
        storage.storeDevice(uuid: "UUID-1", name: "Watch", family: .suuntoNautic, model: 1, serial: "serial-1")
        storage.updateDeviceFirmware(uuid: "UUID-1", firmware: "2.1.0")

        // Re-storing (e.g. a reconnect) without a serial must not drop the one already recorded.
        storage.storeDevice(uuid: "UUID-1", name: "Watch", family: .suuntoNautic, model: 1)
        let stored = storage.getStoredDevice(uuid: "UUID-1")
        XCTAssertEqual(stored?.serial, "serial-1")
        XCTAssertEqual(stored?.firmware, "2.1.0")
    }

    func testReconcileUUIDMigratesARecordFoundUnderItsOldUUID() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev3"))
        storage.storeDevice(uuid: "OLD-UUID", name: "Suunto Ocean 123", family: .suuntoNautic, model: 1, serial: "s1")

        let migrated = storage.reconcileUUID(name: "Suunto Ocean 123", newUUID: "NEW-UUID")
        XCTAssertTrue(migrated)
        XCTAssertNil(storage.getStoredDevice(uuid: "OLD-UUID"))
        XCTAssertEqual(storage.getStoredDevice(uuid: "NEW-UUID")?.serial, "s1")
    }

    func testReconcileUUIDIsANoOpWhenAlreadyUnderTheNewUUID() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev4"))
        storage.storeDevice(uuid: "NEW-UUID", name: "Suunto Ocean 123", family: .suuntoNautic, model: 1)
        XCTAssertFalse(storage.reconcileUUID(name: "Suunto Ocean 123", newUUID: "NEW-UUID"))
    }

    func testReconcileUUIDIsANoOpWhenNoRecordMatchesTheName() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev5"))
        XCTAssertFalse(storage.reconcileUUID(name: "Never Stored", newUUID: "NEW-UUID"))
    }

    func testUpdateDeviceSerialAndFirmwareOnlyAffectTheMatchingUUID() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev6"))
        storage.storeDevice(uuid: "UUID-1", name: "A", family: .suuntoNautic, model: 0)
        storage.storeDevice(uuid: "UUID-2", name: "B", family: .suuntoNautic, model: 0)

        storage.updateDeviceSerial(uuid: "UUID-1", serial: "s1")
        storage.updateDeviceFirmware(uuid: "UUID-1", firmware: "1.0")

        XCTAssertEqual(storage.getStoredDevice(uuid: "UUID-1")?.serial, "s1")
        XCTAssertNil(storage.getStoredDevice(uuid: "UUID-2")?.serial)
    }

    func testGetLastConnectedDeviceReturnsTheMostRecentlyStoredOne() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev7"))
        storage.storeDevice(uuid: "UUID-1", name: "First", family: .suuntoNautic, model: 0)
        storage.storeDevice(uuid: "UUID-2", name: "Second", family: .suuntoNautic, model: 0)
        XCTAssertEqual(storage.getLastConnectedDevice()?.uuid, "UUID-2")
    }

    func testTwoInjectedDeviceStoragesAreFullyIsolatedFromEachOther() {
        let storageA = DeviceStorage(userDefaults: isolatedSuite("devA"))
        let storageB = DeviceStorage(userDefaults: isolatedSuite("devB"))
        storageA.storeDevice(uuid: "UUID-1", name: "A", family: .suuntoNautic, model: 0)
        XCTAssertNil(storageB.getStoredDevice(uuid: "UUID-1"))
    }

    func testUpdateStoredDevicesReplacesTheWholeList() {
        let storage = DeviceStorage(userDefaults: isolatedSuite("dev8"))
        storage.storeDevice(uuid: "UUID-1", name: "A", family: .suuntoNautic, model: 0)
        let replacement = [StoredDevice(uuid: "UUID-2", name: "B", family: .suuntoNautic, model: 0)]
        storage.updateStoredDevices(replacement)

        XCTAssertNil(storage.getStoredDevice(uuid: "UUID-1"))
        XCTAssertNotNil(storage.getStoredDevice(uuid: "UUID-2"))
        XCTAssertEqual(storage.getAllStoredDevices()?.count, 1)
    }
}
