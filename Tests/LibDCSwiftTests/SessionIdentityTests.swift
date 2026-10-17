import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Session downloads key fingerprints by `DiveComputerIdentity`, over the real Reefnet Sensus driver on a serial fake.
final class SessionIdentityTests: XCTestCase {

    private typealias FakeSensus = SessionClockTests.FakeSensus

    private static let devtime: UInt32 = 5_000_000
    private static let older: UInt32 = devtime - 86_400
    private static let newer: UInt32 = devtime - 3_600

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive.removeAll()
        super.tearDown()
    }

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.sessionidentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private static func fakeSensus(_ userdata: UnsafeMutableRawPointer?) -> FakeSensus {
        Unmanaged<FakeSensus>.fromOpaque(userdata!).takeUnretainedValue()
    }

    private func sensus(serial: UInt16) -> FakeSensus {
        FakeSensus(serial: serial, devtime: Self.devtime,
                   dives: [(100, SessionClockTests.dive(timestamp: Self.older)), (400, SessionClockTests.dive(timestamp: Self.newer))])
    }

    private func open(_ fake: FakeSensus, devices: DeviceStorage, locator: DiveComputerLocator? = nil) throws -> DiveComputerSession {
        keepAlive.append(fake)
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        var cbs = dc_custom_cbs_t()
        cbs.read = { userdata, data, size, actual in
            let n = SessionIdentityTests.fakeSensus(userdata).hostRead(into: data!, size: size)
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            SessionIdentityTests.fakeSensus(userdata).hostWrote(UnsafeRawBufferPointer(start: data, count: size))
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(fake).toOpaque()), DC_STATUS_SUCCESS)
        let session = try DiveComputerSession.open(
            iostream: try XCTUnwrap(iostream), context: try XCTUnwrap(context), family: DC_FAMILY_REEFNET_SENSUS, model: 1,
            displayName: "Reefnet Sensus", storageKey: "serial:sensus", locator: locator,
            deviceStorage: devices, lease: DiveComputerSessionLease())
        addTeardownBlock { session.close() }
        return session
    }

    private func download(_ session: DiveComputerSession, viewModel: DiveDataViewModel) -> DiveDownloadResult? {
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        return result
    }

    private static func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    private static let adapter = DiveComputerLocator.serial(path: "/dev/cu.usbserial-TEST", usbSerial: "TEST-ADAPTER-1",
                                                            vid: 0x0403, pid: 0x6001)

    // MARK: - Completion

    func testEveryDiveIsInTheViewModelWhenCompletionRuns() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("order"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("orderDev"), fingerprints: fingerprints)
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let session = try open(sensus(serial: 0x1234), devices: devices)
        let parsed = DispatchSemaphore(value: 0)
        let hook: DiveLogRetriever.ParseHook = { _, parse in
            defer { parsed.signal() }
            return try parse()
        }

        let done = expectation(description: "download")
        var seen: (count: Int, numbers: [Int], result: DiveDownloadResult)?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel, parseHook: hook) { result in
            seen = (viewModel.dives.count, viewModel.dives.map(\.number), result)
            done.fulfill()
        }
        // Main stays busy until both dives and the finish are queued, the order in which the last dive used to land late.
        for _ in 0..<2 { XCTAssertEqual(parsed.wait(timeout: .now() + 10), .success) }
        Thread.sleep(forTimeInterval: 0.2)
        wait(for: [done], timeout: 10)

        let (count, numbers, result) = try XCTUnwrap(seen)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.divesDownloaded, 2)
        XCTAssertEqual(count, result.divesDownloaded, "a host converting dives in completion, then acknowledging, gets all of them")
        XCTAssertEqual(numbers, [1, 2], "numbered oldest first")
    }

    // MARK: - A serial

    func testTheResultTheSessionAndTheCommitCarryTheIdentity() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("dev"), fingerprints: fingerprints)
        let session = try open(sensus(serial: 0x1234), devices: devices, locator: Self.adapter)
        XCTAssertNil(session.identity, "nothing before DEVINFO")
        XCTAssertEqual(session.locator, Self.adapter)

        let result = try XCTUnwrap(download(session, viewModel: DiveDataViewModel(fingerprintStore: fingerprints)))
        XCTAssertEqual(result.outcome, .completed)
        let identity = try XCTUnwrap(result.identity)
        XCTAssertEqual(identity.family, .reefnetSensus)
        XCTAssertEqual(identity.model, 1)
        XCTAssertEqual(identity.canonicalName, "Reefnet Sensus")
        XCTAssertEqual(identity.serial, "00001234")
        XCTAssertEqual(identity.transport, .serial)
        XCTAssertEqual(identity.deviceKey, "sn:00001234")
        XCTAssertEqual(session.identity, identity)

        let commit = try XCTUnwrap(result.fingerprintCommit)
        XCTAssertEqual(commit.identity, identity)
        XCTAssertEqual(commit.fingerprint, Self.le32(Self.newer))
        commit.acknowledge()
        let record = try XCTUnwrap(fingerprints.loadFingerprints().first)
        XCTAssertEqual(record.key, identity.storageKey(), "the serial keys it; the adapter doesn't")
        XCTAssertEqual(record.deviceType, "Reefnet Sensus")
        XCTAssertEqual(record.serial, "00001234")
    }

    func testA118FingerprintStopsTheFirstSessionDownload() throws {
        for migrate in [false, true] {
            let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("legacy\(migrate)"))
            fingerprints.saveFingerprint(Self.le32(Self.newer), deviceType: "Reefnet Sensus", serial: "00001234")
            if migrate { XCTAssertEqual(fingerprints.migrateLegacyKeys(), 1) }
            let devices = DeviceStorage(userDefaults: isolatedSuite("legacyDev\(migrate)"), fingerprints: fingerprints)
            let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
            let result = try XCTUnwrap(download(try open(sensus(serial: 0x1234), devices: devices), viewModel: viewModel))
            XCTAssertEqual(result.outcome, .noNewDives, "migrated: \(migrate)")
            XCTAssertEqual(viewModel.dives.count, 0)
        }
    }

    func testASeededFingerprintStopsTheFirstDownloadThere() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("seed"))
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let identity = DiveComputerIdentity(family: .reefnetSensus, model: 1, serialNumber: 0x1234, transport: .ble)
        XCTAssertTrue(viewModel.seedFingerprint(identity: identity, data: Self.le32(Self.older)), "synced earlier over another transport")

        let devices = DeviceStorage(userDefaults: isolatedSuite("seedDev"), fingerprints: fingerprints)
        let result = try XCTUnwrap(download(try open(sensus(serial: 0x1234), devices: devices), viewModel: viewModel))
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.divesDownloaded, 1, "only the dive after the seeded one")
        XCTAssertEqual(result.fingerprintCommit?.fingerprint, Self.le32(Self.newer))
    }

    func testTheStoredDeviceGetsTheReportedSerial() throws {
        let devices = DeviceStorage(userDefaults: isolatedSuite("serialDev"))
        devices.storeDevice(uuid: "serial:sensus", name: "Reefnet Sensus", family: .reefnetSensus, model: 1, transport: .serial)
        let viewModel = DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedSuite("serialFp")))
        _ = download(try open(sensus(serial: 0x1234), devices: devices), viewModel: viewModel)
        XCTAssertEqual(devices.getStoredDevice(uuid: "serial:sensus")?.serial, "00001234")
        XCTAssertEqual(devices.storedDevice(family: .reefnetSensus, serial: "00001234")?.uuid, "serial:sensus")
    }

    // MARK: - No serial

    func testWithoutASerialOrAStandInEveryDownloadFetchesEveryDive() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("zero"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("zeroDev"), fingerprints: fingerprints)
        devices.storeDevice(uuid: "serial:sensus", name: "Reefnet Sensus", family: .reefnetSensus, model: 1, transport: .serial)
        for _ in 0..<2 {
            let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
            let result = try XCTUnwrap(download(try open(sensus(serial: 0), devices: devices), viewModel: viewModel))
            XCTAssertEqual(result.outcome, .completed)
            XCTAssertEqual(result.divesDownloaded, 2)
            XCTAssertNil(result.fingerprintCommit, "a model-only key would be shared by every Sensus")
            XCTAssertNil(result.identity?.serial)
            XCTAssertEqual(result.identity?.deviceKey, "md:reefnet sensus")
        }
        XCTAssertTrue(fingerprints.loadFingerprints().isEmpty)
        XCTAssertNil(devices.getStoredDevice(uuid: "serial:sensus")?.serial, "0 isn't stored as a serial")
    }

    func testTheAdapterStandsInForAMissingSerial() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("standIn"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("standInDev"), fingerprints: fingerprints)

        let first = try XCTUnwrap(download(try open(sensus(serial: 0), devices: devices, locator: Self.adapter),
                                           viewModel: DiveDataViewModel(fingerprintStore: fingerprints)))
        let commit = try XCTUnwrap(first.fingerprintCommit)
        XCTAssertEqual(commit.serial, "00000000")
        commit.acknowledge()
        XCTAssertEqual(fingerprints.loadFingerprints().first?.key, "md:reefnet sensus@adapter:0403:6001:TEST-ADAPTER-1")

        let again = try XCTUnwrap(download(try open(sensus(serial: 0), devices: devices, locator: Self.adapter),
                                           viewModel: DiveDataViewModel(fingerprintStore: fingerprints)))
        XCTAssertEqual(again.outcome, .noNewDives)

        let otherAdapter = DiveComputerLocator.serial(path: "/dev/cu.usbserial-TEST", usbSerial: "TEST-ADAPTER-2", vid: 0x0403, pid: 0x6001)
        let elsewhere = try XCTUnwrap(download(try open(sensus(serial: 0), devices: devices, locator: otherAdapter),
                                               viewModel: DiveDataViewModel(fingerprintStore: fingerprints)))
        XCTAssertEqual(elsewhere.divesDownloaded, 2, "another adapter may be another unit")
    }

    // MARK: - No DEVINFO

    /// Citizen Hyper Aqualand: one dive, its whole memory in 32-byte packets ending in 0xFF; the driver never sends DEVINFO.
    final class FakeAqualand {
        private let memory: [UInt8]
        private var index = 0
        private let lock = NSLock()

        init() {
            var memory = [UInt8](repeating: 0x20, count: 64)
            memory.replaceSubrange(5..<13, with: [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
            memory[63] = 0xFF
            self.memory = memory
        }

        func hostWrote(_ bytes: UnsafeRawBufferPointer) {
            lock.lock(); defer { lock.unlock() }
            if bytes.first == 0x7F { index = 0 }
        }

        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = min(size, memory.count - index)
            guard n > 0 else { return 0 }
            memory.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + index, byteCount: n) }
            index += n
            return n
        }
    }

    private static let aqualandFingerprint = Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])

    private func openAqualand(_ fake: FakeAqualand, devices: DeviceStorage, locator: DiveComputerLocator? = nil) throws -> DiveComputerSession {
        keepAlive.append(fake)
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        var cbs = dc_custom_cbs_t()
        cbs.read = { userdata, data, size, actual in
            let n = Unmanaged<FakeAqualand>.fromOpaque(userdata!).takeUnretainedValue().hostRead(into: data!, size: size)
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            Unmanaged<FakeAqualand>.fromOpaque(userdata!).takeUnretainedValue().hostWrote(UnsafeRawBufferPointer(start: data, count: size))
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(fake).toOpaque()), DC_STATUS_SUCCESS)
        let session = try DiveComputerSession.open(
            iostream: try XCTUnwrap(iostream), context: try XCTUnwrap(context), family: DC_FAMILY_CITIZEN_AQUALAND, model: 0,
            displayName: "Citizen Hyper Aqualand", storageKey: "serial:aqualand", locator: locator,
            deviceStorage: devices, lease: DiveComputerSessionLease())
        addTeardownBlock { session.close() }
        return session
    }

    /// The Aqualand parser wants a real dump; the hook counts the dives that reach it.
    private func downloadAqualand(_ session: DiveComputerSession, viewModel: DiveDataViewModel, parsed: inout Int) -> DiveDownloadResult? {
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        var count = 0
        let hook: DiveLogRetriever.ParseHook = { _, _ in
            count += 1
            return DiveComputerSessionTests.stubDive()
        }
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel, parseHook: hook) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        parsed += count
        return result
    }

    func testAFamilyWithoutDevinfoGetsTheOpenedDescriptorsIdentity() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("noDevinfo"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("noDevinfoDev"), fingerprints: fingerprints)
        var parsed = 0
        for _ in 0..<2 {
            let session = try openAqualand(FakeAqualand(), devices: devices)
            let result = try XCTUnwrap(downloadAqualand(session, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), parsed: &parsed))
            XCTAssertEqual(result.outcome, .completed)
            XCTAssertEqual(result.divesDownloaded, 1)
            let identity = try XCTUnwrap(result.identity, "no DEVINFO, but the opened descriptor names the computer")
            XCTAssertEqual(identity.family, .citizenAqualand)
            XCTAssertEqual(identity.model, 0)
            XCTAssertEqual(identity.canonicalName, "Citizen Hyper Aqualand")
            XCTAssertNil(identity.serial)
            XCTAssertEqual(identity.transport, .serial)
            XCTAssertEqual(identity.deviceKey, "md:citizen hyper aqualand")
            XCTAssertEqual(session.identity, identity)
            XCTAssertNil(result.fingerprintCommit, "no serial and no stand-in: every download is full")
        }
        XCTAssertEqual(parsed, 2)
        XCTAssertTrue(fingerprints.loadFingerprints().isEmpty)
    }

    func testAFamilyWithoutDevinfoStopsAtItsAdapterKeyedFingerprint() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("noDevinfoAdapter"))
        let devices = DeviceStorage(userDefaults: isolatedSuite("noDevinfoAdapterDev"), fingerprints: fingerprints)
        let fake = FakeAqualand()
        var parsed = 0

        let first = try XCTUnwrap(downloadAqualand(try openAqualand(fake, devices: devices, locator: Self.adapter),
                                                   viewModel: DiveDataViewModel(fingerprintStore: fingerprints), parsed: &parsed))
        XCTAssertEqual(first.outcome, .completed)
        let commit = try XCTUnwrap(first.fingerprintCommit)
        XCTAssertEqual(commit.fingerprint, Self.aqualandFingerprint)
        commit.acknowledge()
        XCTAssertEqual(fingerprints.loadFingerprints().first?.key, "md:citizen hyper aqualand@adapter:0403:6001:TEST-ADAPTER-1")
        XCTAssertEqual(parsed, 1)

        let session = try openAqualand(fake, devices: devices, locator: Self.adapter)
        let again = try XCTUnwrap(downloadAqualand(session, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), parsed: &parsed))
        XCTAssertEqual(again.outcome, .noNewDives)
        XCTAssertEqual(again.divesDownloaded, 0)
        XCTAssertEqual(parsed, 1)
        // The fingerprint was set on the device, so the driver skips the dive itself.
        let counting: dc_dive_callback_t = { _, _, _, _, userdata in
            userdata!.assumingMemoryBound(to: Int.self).pointee += 1
            return 1
        }
        var offered = 0
        let status = withUnsafeMutablePointer(to: &offered) { dc_device_foreach(session.devicePtr.pointee.device, counting, $0) }
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(offered, 0)

        let otherAdapter = DiveComputerLocator.serial(path: "/dev/cu.usbserial-TEST", usbSerial: "TEST-ADAPTER-2", vid: 0x0403, pid: 0x6001)
        let elsewhere = try XCTUnwrap(downloadAqualand(try openAqualand(fake, devices: devices, locator: otherAdapter),
                                                       viewModel: DiveDataViewModel(fingerprintStore: fingerprints), parsed: &parsed))
        XCTAssertEqual(elsewhere.divesDownloaded, 1, "another adapter may be another unit")
    }

    func testAFamilyWithoutDevinfoDownloadsInFullWhenFingerprintsAreOff() throws {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("noDevinfoOff"))
        fingerprints.saveFingerprint(Self.aqualandFingerprint,
                                     for: DiveComputerIdentity(family: .citizenAqualand, model: 0, serial: nil, transport: .serial),
                                     standIn: Self.adapter.unitStandIn)
        let devices = DeviceStorage(userDefaults: isolatedSuite("noDevinfoOffDev"), fingerprints: fingerprints)
        let session = try openAqualand(FakeAqualand(), devices: devices, locator: Self.adapter)
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), useFingerprint: false,
                                          parseHook: { _, _ in DiveComputerSessionTests.stubDive() }) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result?.divesDownloaded, 1)
    }
}
