import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// Fingerprints keyed by `DiveComputerIdentity`, the migration from 1.18's (deviceType, serial) records, and seeding.
final class FingerprintIdentityTests: XCTestCase {

    private static let fingerprintKey = "DeviceFingerprints"

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.fpidentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func perdix(_ serial: String = "0badf00d", transport: DCTransport = .ble) -> DiveComputerIdentity {
        DiveComputerIdentity(family: .shearwaterPetrel, model: 5, serial: serial, transport: transport)
    }

    /// 1.18 records: identity-less, Data as base64, dates as reference-date seconds, names as the BLE download saved them.
    private static let legacyJSON = """
    [{"id":"10000000-0000-0000-0000-000000000001","deviceType":"Shearwater Perdix","serial":"0badf00d","fingerprint":"AQIDBA==","timestamp":800000000},\
    {"id":"10000000-0000-0000-0000-000000000002","deviceType":"Scubapro G2 Console","serial":"00c0ffee","fingerprint":"BQYHCA==","timestamp":800000001},\
    {"id":"10000000-0000-0000-0000-000000000003","deviceType":"Mystery Computer","serial":"00001111","fingerprint":"CQ==","timestamp":800000002},\
    {"id":"10000000-0000-0000-0000-000000000004","deviceType":"Oceans S1","serial":"00000000","fingerprint":"Cg==","timestamp":800000003}]
    """

    private func legacyStore(_ name: String) -> (DeviceFingerprintStorage, UserDefaults) {
        let defaults = isolatedSuite(name)
        defaults.set(Data(Self.legacyJSON.utf8), forKey: Self.fingerprintKey)
        return (DeviceFingerprintStorage(userDefaults: defaults), defaults)
    }

    private func oceansS1(uuid: String, serial: String? = "00000000") -> StoredDevice {
        StoredDevice(uuid: uuid, name: "Oceans S1 Test", family: .oceansS1, model: 0, serial: serial)
    }

    // MARK: - Unmigrated stores

    func testA118RecordIsFoundByIdentityBeforeAnyMigration() throws {
        let (store, _) = legacyStore("lazy")
        XCTAssertEqual(store.getFingerprint(for: perdix())?.fingerprint, Data([1, 2, 3, 4]), "no forced full download")
        XCTAssertEqual(store.getFingerprint(for: perdix(transport: .classicBTSerial))?.fingerprint, Data([1, 2, 3, 4]))
        let g2 = DiveComputerIdentity(family: .uwatecSmart, model: 0x32, serial: "00c0ffee", transport: .usbHID)
        XCTAssertEqual(store.getFingerprint(for: g2)?.fingerprint, Data([5, 6, 7, 8]), "saved as G2 Console, the same unit")
    }

    func testAnotherFamilyOrSerialIsAnotherComputer() {
        let (store, _) = legacyStore("strangers")
        XCTAssertNil(store.getFingerprint(for: perdix("0badf00e")))
        XCTAssertNil(store.getFingerprint(for: DiveComputerIdentity(family: .suuntoEonSteel, model: 0, serial: "0badf00d", transport: .usbHID)))
    }

    func testANoSerialIdentityNeverPicksUpASharedZeroRecord() {
        let (store, _) = legacyStore("zeroLazy")
        let s1 = DiveComputerIdentity(family: .oceansS1, model: 0, serial: nil, transport: .ble)
        XCTAssertNil(store.getFingerprint(for: s1))
        XCTAssertNil(store.getFingerprint(for: s1, standIn: "ble:S1-A"), "only the migration can tell whose it was")
    }

    // MARK: - Migration

    func testMigrationKeysRecordsInPlace() throws {
        let (store, _) = legacyStore("migrate")
        let before = store.loadFingerprints()
        XCTAssertEqual(store.migrateLegacyKeys(storedDevices: [oceansS1(uuid: "S1-A")]), 3)

        let after = store.loadFingerprints()
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.deviceType), before.map(\.deviceType), "1.18 readers still match on deviceType")
        XCTAssertEqual(after.map(\.serial), before.map(\.serial))
        XCTAssertEqual(after.map(\.fingerprint), before.map(\.fingerprint))
        XCTAssertEqual(after.map(\.timestamp), before.map(\.timestamp))
        XCTAssertEqual(after.map(\.key), [
            perdix().storageKey(),
            String(format: "dc:%08x:00c0ffee", DC_FAMILY_UWATEC_SMART.rawValue),
            nil,
            "md:oceans s1@ble:S1-A",
        ])

        XCTAssertEqual(store.getFingerprint(forDeviceType: "Shearwater Perdix", serial: "0badf00d")?.fingerprint, Data([1, 2, 3, 4]))
        XCTAssertEqual(store.getFingerprint(for: perdix())?.fingerprint, Data([1, 2, 3, 4]))
        let s1 = DiveComputerIdentity(family: .oceansS1, model: 0, serial: nil, transport: .ble)
        XCTAssertEqual(store.getFingerprint(for: s1, standIn: DiveComputerLocator.ble(uuid: "S1-A").unitStandIn)?.fingerprint, Data([10]))
        XCTAssertEqual(store.getFingerprint(forDeviceType: "Mystery Computer", serial: "00001111")?.fingerprint, Data([9]),
                       "a name no family has stays as it was")
    }

    func testMigrationIsIdempotent() {
        let (store, defaults) = legacyStore("idempotent")
        XCTAssertEqual(store.migrateLegacyKeys(), 2)
        let once = defaults.data(forKey: Self.fingerprintKey)
        XCTAssertEqual(store.migrateLegacyKeys(), 0)
        XCTAssertEqual(defaults.data(forKey: Self.fingerprintKey), once, "a second run writes nothing")
    }

    func testAZeroSerialRecordNeedsExactlyOneSerialZeroBLEDevice() {
        for devices in [[], [oceansS1(uuid: "S1-A"), oceansS1(uuid: "S1-B")], [oceansS1(uuid: "S1-A", serial: nil)]] as [[StoredDevice]] {
            let (store, _) = legacyStore("zero\(devices.count)")
            store.migrateLegacyKeys(storedDevices: devices)
            XCTAssertNil(store.loadFingerprints().first { $0.deviceType == "Oceans S1" }?.key, "\(devices.map(\.uuid))")
        }
        let cable = StoredDevice(uuid: "dc:x", name: "Oceans S1", family: .oceansS1, model: 0, serial: "00000000", transport: .serial)
        let (store, _) = legacyStore("zeroCable")
        store.migrateLegacyKeys(storedDevices: [cable])
        XCTAssertNil(store.loadFingerprints().first { $0.deviceType == "Oceans S1" }?.key, "1.18 only stored BLE devices")
    }

    func testDeviceStorageMigratesWithItsOwnRecords() {
        let (fingerprints, _) = legacyStore("viaDevices")
        let devices = DeviceStorage(userDefaults: isolatedSuite("viaDevicesDev"), fingerprints: fingerprints)
        devices.storeDevice(uuid: "S1-A", name: "Oceans S1 Test", family: .oceansS1, model: 0, serial: "00000000")
        XCTAssertEqual(devices.migrateFingerprintKeys(), 3)
        XCTAssertEqual(devices.migrateFingerprintKeys(), 0)
    }

    func testRecordsFromTheCurrentFormatDecodeWithAnOldReader() throws {
        struct OldRecord: Decodable { let id: UUID; let deviceType: String; let serial: String; let fingerprint: Data; let timestamp: Date }
        let (store, defaults) = legacyStore("downgrade")
        store.migrateLegacyKeys()
        store.saveFingerprint(Data([7]), for: perdix("00000077"))
        let old = try JSONDecoder().decode([OldRecord].self, from: XCTUnwrap(defaults.data(forKey: Self.fingerprintKey)))
        XCTAssertEqual(old.count, 5)
        XCTAssertEqual(old.last?.deviceType, "Shearwater Perdix")
        XCTAssertEqual(old.last?.serial, "00000077")
    }

    // MARK: - Saving

    func testSavingReplacesThisComputersRecordsAndKeepsTheOldName() throws {
        let (store, _) = legacyStore("save")
        let g2 = DiveComputerIdentity(family: .uwatecSmart, model: 0x32, serial: "00c0ffee", transport: .usbHID)
        store.saveFingerprint(Data([0xAA]), for: g2)

        let records = store.loadFingerprints().filter { $0.serial == "00c0ffee" }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.key, g2.storageKey())
        XCTAssertEqual(records.first?.deviceType, "Scubapro G2 Console", "a 1.18 reader of the old name still finds it")
        XCTAssertEqual(store.getFingerprint(forDeviceType: "Scubapro G2 Console", serial: "00c0ffee")?.fingerprint, Data([0xAA]))
        XCTAssertEqual(store.getFingerprint(for: g2)?.fingerprint, Data([0xAA]))
        XCTAssertEqual(store.getFingerprint(for: perdix())?.fingerprint, Data([1, 2, 3, 4]), "other computers untouched")
    }

    func testANewComputerIsSavedUnderItsCanonicalName() {
        let store = DeviceFingerprintStorage(userDefaults: isolatedSuite("fresh"))
        let d5 = DiveComputerIdentity(family: .suuntoEonSteel, model: 2, serial: "00000005", transport: .usbHID)
        store.saveFingerprint(Data([1]), for: d5)
        XCTAssertEqual(store.loadFingerprints().map(\.deviceType), ["Suunto D5"])
        XCTAssertEqual(store.getFingerprint(forDeviceType: "Suunto D5", serial: "00000005")?.fingerprint, Data([1]))
        store.saveFingerprint(Data([2]), for: DiveComputerIdentity(family: .suuntoEonSteel, model: 2, serial: "00000005", transport: .ble))
        XCTAssertEqual(store.loadFingerprints().count, 1, "the same computer over BLE replaces it")
        XCTAssertEqual(store.getFingerprint(for: d5)?.fingerprint, Data([2]))
    }

    func testALegacySaveKeepsAMigratedKey() {
        let (store, _) = legacyStore("legacySave")
        store.migrateLegacyKeys()
        store.saveFingerprint(Data([0xBB]), deviceType: "Shearwater Perdix", serial: "0badf00d")
        let record = store.loadFingerprints().first { $0.serial == "0badf00d" }
        XCTAssertEqual(record?.fingerprint, Data([0xBB]))
        XCTAssertEqual(record?.key, perdix().storageKey())
    }

    func testANoSerialComputerWithoutAStandInSavesNothing() {
        let store = DeviceFingerprintStorage(userDefaults: isolatedSuite("noKey"))
        let edy = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serialNumber: 0, transport: .serial)
        store.saveFingerprint(Data([1]), for: edy)
        XCTAssertTrue(store.loadFingerprints().isEmpty)
        XCTAssertNil(store.getFingerprint(for: edy))
    }

    func testStandInsKeepTwoSerialLessUnitsApart() {
        let store = DeviceFingerprintStorage(userDefaults: isolatedSuite("standIns"))
        let edy = DiveComputerIdentity(family: .cressiEdy, model: 0x08, serialNumber: 0, transport: .serial)
        store.saveFingerprint(Data([1]), for: edy, standIn: "adapter:0403:6001:A")
        store.saveFingerprint(Data([2]), for: edy, standIn: "adapter:0403:6001:B")
        XCTAssertEqual(store.getFingerprint(for: edy, standIn: "adapter:0403:6001:A")?.fingerprint, Data([1]))
        XCTAssertEqual(store.getFingerprint(for: edy, standIn: "adapter:0403:6001:B")?.fingerprint, Data([2]))
        XCTAssertEqual(store.loadFingerprints().map(\.serial), ["00000000", "00000000"], "the serial field is what DEVINFO said")
    }

    func testClearingByIdentityRemovesKeyedAnd118Records() {
        let (store, _) = legacyStore("clear")
        store.saveFingerprint(Data([3]), for: perdix("00000003"))
        store.clearFingerprint(for: perdix())
        store.clearFingerprint(for: perdix("00000003"))
        XCTAssertNil(store.getFingerprint(forDeviceType: "Shearwater Perdix", serial: "0badf00d"))
        XCTAssertNil(store.getFingerprint(for: perdix("00000003")))
        XCTAssertEqual(store.loadFingerprints().count, 3)
    }

    func testForgettingADeviceClearsItsKeyedRecord() {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("forget"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("forgetDev"), fingerprints: fingerprints)
        devices.storeDevice(uuid: "dc:vyper", name: "Suunto Vyper", family: .suuntoVyper, model: 0x0A, serial: "00000042", transport: .serial)
        let vyper = DiveComputerIdentity(family: .suuntoVyper, model: 0x0A, serial: "00000042", transport: .serial)
        fingerprints.saveFingerprint(Data([4]), for: vyper)
        fingerprints.saveFingerprint(Data([5]), for: perdix())

        devices.removeDevice(uuid: "dc:vyper")
        XCTAssertNil(fingerprints.getFingerprint(for: vyper))
        XCTAssertNotNil(fingerprints.getFingerprint(for: perdix()))
    }

    // MARK: - Seeding

    func testSeedingStoresWhenThereIsNothing() {
        let store = DeviceFingerprintStorage(userDefaults: isolatedSuite("seed"))
        XCTAssertTrue(store.seedFingerprint(identity: perdix(), data: Data([9, 9])))
        XCTAssertEqual(store.getFingerprint(for: perdix())?.fingerprint, Data([9, 9]))
        XCTAssertEqual(store.loadFingerprints().first?.key, perdix().storageKey())
    }

    func testSeedingNeverReplacesAStoredFingerprint() {
        let (store, _) = legacyStore("seedExisting")
        XCTAssertFalse(store.seedFingerprint(identity: perdix(), data: Data([9])), "a 1.18 record counts")
        XCTAssertEqual(store.getFingerprint(for: perdix())?.fingerprint, Data([1, 2, 3, 4]))
        store.saveFingerprint(Data([6]), for: perdix("00000006"))
        XCTAssertFalse(store.seedFingerprint(identity: perdix("00000006"), data: Data([9])))
        XCTAssertEqual(store.getFingerprint(for: perdix("00000006"))?.fingerprint, Data([6]))
    }

    func testSeedingNeedsDataAndAKey() {
        let store = DeviceFingerprintStorage(userDefaults: isolatedSuite("seedInvalid"))
        XCTAssertFalse(store.seedFingerprint(identity: perdix(), data: Data()))
        let s1 = DiveComputerIdentity(family: .oceansS1, model: 0, serial: nil, transport: .ble)
        XCTAssertFalse(store.seedFingerprint(identity: s1, data: Data([1])))
        XCTAssertTrue(store.seedFingerprint(identity: s1, data: Data([1]), standIn: "ble:S1-A"))
        XCTAssertTrue(store.loadFingerprints().count == 1)
    }

    func testTheViewModelSeedsAndReadsItsOwnStore() {
        let store = DeviceFingerprintStorage(userDefaults: isolatedSuite("viewModel"))
        let viewModel = DiveDataViewModel(fingerprintStore: store)
        XCTAssertTrue(viewModel.seedFingerprint(identity: perdix(), data: Data([8])))
        XCTAssertEqual(viewModel.getFingerprint(for: perdix()), Data([8]))
        viewModel.saveFingerprint(Data(), for: perdix())
        XCTAssertEqual(viewModel.getFingerprint(for: perdix()), Data([8]), "an empty fingerprint is ignored")
        viewModel.saveFingerprint(Data([7]), for: perdix())
        XCTAssertEqual(store.getFingerprint(for: perdix())?.fingerprint, Data([7]))
    }
}
