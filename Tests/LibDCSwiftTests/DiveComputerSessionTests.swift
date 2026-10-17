import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Sessions over a `FakeWatch` opened through `open_device_on_iostream`, so the C event and lookup path is the real one.
final class DiveComputerSessionTests: XCTestCase {

    private typealias FakeWatch = SuuntoNauticTransportTests.FakeWatch
    private typealias FakeDive = SuuntoNauticTransportTests.FakeDive

    private static let diveA = FakeDive(id: 1_789_750_000, profileBytes: 600, summaryBytes: 100)
    private static let diveB = FakeDive(id: 1_789_757_200, profileBytes: 600, summaryBytes: 100)
    private static let diveC = FakeDive(id: 1_789_764_400, profileBytes: 600, summaryBytes: 100)
    /// "/Info" on FakeWatch reports serial 2604C3003306, truncated to the low 32 bits.
    private static let serial = "c3003306"
    /// The Ocean descriptor's "Vendor Product", which the C lookup and the commit both key on.
    private static let deviceType = "Suunto Ocean"

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive.removeAll()
        super.tearDown()
    }

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.session.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private struct Stores {
        let fingerprints: DeviceFingerprintStorage
        let devices: DeviceStorage
    }

    private func stores() -> Stores {
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        return Stores(fingerprints: fingerprints, devices: DeviceStorage(userDefaults: isolatedSuite("dev"), fingerprints: fingerprints))
    }

    private static func watch(_ userdata: UnsafeMutableRawPointer?) -> FakeWatch {
        Unmanaged<FakeWatch>.fromOpaque(userdata!).takeUnretainedValue()
    }

    private func nauticStream(_ watch: FakeWatch, context: OpaquePointer) throws -> OpaquePointer {
        keepAlive.append(watch)
        var cbs = dc_custom_cbs_t()
        cbs.set_timeout = { _, _ in DC_STATUS_SUCCESS }
        cbs.read = { userdata, data, size, actual in
            guard let n = DiveComputerSessionTests.watch(userdata).hostRead(into: data!, size: size) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            guard DiveComputerSessionTests.watch(userdata).hostWrote(UnsafeRawBufferPointer(start: data, count: size)) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        cbs.purge = { _, _ in DC_STATUS_SUCCESS }
        cbs.sleep = { _, _ in DC_STATUS_SUCCESS }
        cbs.close = { _ in DC_STATUS_SUCCESS }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_BLE, &cbs, Unmanaged.passUnretained(watch).toOpaque()), DC_STATUS_SUCCESS)
        return try XCTUnwrap(iostream)
    }

    private func newContext() throws -> OpaquePointer {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        return try XCTUnwrap(context)
    }

    private func openNautic(_ watch: FakeWatch, stores: Stores, lease: DiveComputerSessionLease) throws -> DiveComputerSession {
        let context = try newContext()
        let iostream = try nauticStream(watch, context: context)
        let session = try DiveComputerSession.open(
            iostream: iostream, context: context, family: DC_FAMILY_SUUNTO_NAUTIC, model: 1,
            displayName: "Suunto Ocean 123456", storageKey: "FAKE-UUID",
            deviceStorage: stores.devices, lease: lease)
        addTeardownBlock { session.close() }
        return session
    }

    private func download(_ session: DiveComputerSession, viewModel: DiveDataViewModel,
                          useFingerprint: Bool = true, parseHook: DiveLogRetriever.ParseHook? = nil) -> DiveDownloadResult? {
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel, useFingerprint: useFingerprint,
                                          parseHook: parseHook) {
            XCTAssertTrue(Thread.isMainThread)
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    /// The view model's own progress and renumbering hop through `DispatchQueue.main.async`.
    private func drainMain(_ condition: () -> Bool = { true }, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let step = expectation(description: "drain")
            DispatchQueue.main.async { step.fulfill() }
            wait(for: [step], timeout: 1)
        } while !condition() && Date() < deadline
    }

    private static func le32(_ id: UInt32) -> Data {
        Data((0..<4).map { UInt8((id >> (8 * UInt32($0))) & 0xFF) })
    }

    // MARK: - Commit acknowledgement

    func testAcknowledgedCommitSavesTheFingerprintAndTheNextSessionStopsThere() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let stores = stores()
        let lease = DiveComputerSessionLease()
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)

        let session = try openNautic(watch, stores: stores, lease: lease)
        let result = try XCTUnwrap(download(session, viewModel: viewModel))
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.divesDownloaded, 2)
        XCTAssertEqual(result.parseFailureCount, 0)
        let commit = try XCTUnwrap(result.fingerprintCommit)
        XCTAssertEqual(commit.deviceType, Self.deviceType)
        XCTAssertEqual(commit.serial, Self.serial)
        XCTAssertEqual(commit.fingerprint, Self.le32(Self.diveB.id), "the newest dive's id")
        XCTAssertNil(stores.fingerprints.getFingerprint(forDeviceType: Self.deviceType, serial: Self.serial),
                     "nothing is saved before the host acknowledges")

        commit.acknowledge()
        commit.acknowledge()
        XCTAssertTrue(commit.isAcknowledged)
        XCTAssertEqual(stores.fingerprints.getFingerprint(forDeviceType: Self.deviceType, serial: Self.serial)?.fingerprint,
                       Self.le32(Self.diveB.id))
        XCTAssertEqual(stores.fingerprints.loadFingerprints().count, 1)
        drainMain { viewModel.progress == .completed }
        XCTAssertEqual(viewModel.dives.map(\.number), [1, 2])

        session.close()
        watch.reconnect()
        let next = try openNautic(watch, stores: stores, lease: lease)
        let again = try XCTUnwrap(download(next, viewModel: viewModel))
        XCTAssertEqual(again.outcome, .noNewDives)
        XCTAssertNil(again.fingerprintCommit)
        drainMain { viewModel.progress == .noNewDives }
        XCTAssertEqual(viewModel.dives.count, 2)
    }

    func testWithoutAnAcknowledgementTheStoreIsUntouchedAndTheDivesAreOfferedAgain() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let stores = stores()
        let lease = DiveComputerSessionLease()

        let session = try openNautic(watch, stores: stores, lease: lease)
        let first = try XCTUnwrap(download(session, viewModel: DiveDataViewModel(fingerprintStore: stores.fingerprints)))
        XCTAssertNotNil(first.fingerprintCommit)
        session.close()
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)

        watch.reconnect()
        let next = try openNautic(watch, stores: stores, lease: lease)
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let second = try XCTUnwrap(download(next, viewModel: viewModel))
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertEqual(second.divesDownloaded, 2, "the unacknowledged dives come again")
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)
    }

    /// A `device_data_t` built the way a legacy BLE connect leaves it: a device, no descriptor.
    private func descriptorlessNautic(_ watch: FakeWatch) throws -> UnsafeMutablePointer<device_data_t> {
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.context = try newContext()
        data.pointee.iostream = try nauticStream(watch, context: try XCTUnwrap(data.pointee.context))
        var descriptor: OpaquePointer?
        XCTAssertEqual(find_descriptor_by_model(&descriptor, DC_FAMILY_SUUNTO_NAUTIC, 1), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_device_open(&data.pointee.device, data.pointee.context, descriptor, data.pointee.iostream), DC_STATUS_SUCCESS)
        dc_descriptor_free(descriptor)
        let events = DC_EVENT_DEVINFO.rawValue | DC_EVENT_CLOCK.rawValue
        XCTAssertEqual(dc_device_set_events(data.pointee.device, events, { _, event, payload, userdata in
            guard event == DC_EVENT_DEVINFO, let payload, let userdata else { return }
            let devData = userdata.assumingMemoryBound(to: device_data_t.self)
            devData.pointee.devinfo = payload.load(as: dc_event_devinfo_t.self)
            devData.pointee.have_devinfo = 1
        }, UnsafeMutableRawPointer(data)), DC_STATUS_SUCCESS)
        addTeardownBlock {
            withExtendedLifetime(watch) { libdc_close_device_data(data) }
            data.deallocate()
        }
        return data
    }

    func testAParseFailureWithholdsTheCommitAndReportsTheCount() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let stores = stores()
        // A stored model no descriptor knows: every dive downloads, and none can be parsed.
        stores.devices.storeDevice(uuid: "FAKE-UUID", name: "Suunto Ocean 123456", family: .suuntoNautic, model: 99)
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let session = try DiveComputerSession.adopt(
            devicePtr: try descriptorlessNautic(watch), displayName: "Suunto Ocean 123456", storageKey: "FAKE-UUID",
            deviceStorage: stores.devices, lease: DiveComputerSessionLease())
        addTeardownBlock { session.close() }

        let result = try XCTUnwrap(download(session, viewModel: viewModel))
        XCTAssertEqual(result.outcome, .unreadableDives(2))
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(result.parseFailureCount, 2)
        XCTAssertEqual(result.divesDownloaded, 0)
        XCTAssertNil(result.fingerprintCommit)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(watch.streamsServed, 2, "both dives were downloaded")
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)
        drainMain { if case .failed = viewModel.progress { return true } else { return false } }
        XCTAssertEqual(viewModel.lastDownloadStatus, "unreadableDives")
        XCTAssertEqual(stores.devices.getStoredDevice(uuid: "FAKE-UUID")?.model, 99, "an unreported hardware model isn't stored")
    }

    func testOneUnparsedDiveInABatchWithholdsTheCommitAndKeepsTheOthers() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB, Self.diveC])
        let stores = stores()
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let session = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        var parsedIDs: [Data] = []
        let failB: DiveLogRetriever.ParseHook = { fingerprint, parse in
            guard fingerprint != Self.le32(Self.diveB.id) else { throw GenericParser.ParserError.invalidParameters }
            parsedIDs.append(fingerprint)
            return try parse()
        }

        let result = try XCTUnwrap(download(session, viewModel: viewModel, parseHook: failB))
        XCTAssertEqual(result.outcome, .unreadableDives(1))
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(result.parseFailureCount, 1)
        XCTAssertEqual(result.divesDownloaded, 2)
        XCTAssertNil(result.fingerprintCommit, "the newest dive parsed, but the commit would skip the failed one")
        XCTAssertEqual(watch.streamsServed, 3, "the walk went on past the failed dive")
        XCTAssertEqual(parsedIDs, [Self.le32(Self.diveC.id), Self.le32(Self.diveA.id)])
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)
        XCTAssertEqual(viewModel.lastDownloadStatus, "unreadableDives")
        drainMain { viewModel.dives.count == 2 }
        XCTAssertEqual(viewModel.dives.count, 2, "the parsed dives still reach the host")
    }

    func testTheUnreadableDivesMessageCountsWhatWasDownloaded() {
        XCTAssertEqual(DiveLogRetriever.unreadableDivesMessage(unreadable: 2, downloaded: 0), "2 dives couldn't be read.")
        XCTAssertEqual(DiveLogRetriever.unreadableDivesMessage(unreadable: 1, downloaded: 0), "1 dive couldn't be read.")
        XCTAssertEqual(DiveLogRetriever.unreadableDivesMessage(unreadable: 1, downloaded: 1),
                       "1 dive couldn't be read. 1 other dive was downloaded.")
        XCTAssertEqual(DiveLogRetriever.unreadableDivesMessage(unreadable: 3, downloaded: 4),
                       "3 dives couldn't be read. 4 other dives were downloaded.")
    }

    // MARK: - Families without fingerprints

    /// Suunto Solution's dump replies to scripted reads and ignores the host's writes, so its whole reply is fixed.
    final class FakeSolution {
        private let reply: [UInt8]
        private var index = 0
        private let lock = NSLock()
        private(set) var dumps = 0

        init(memory: [UInt8]) {
            var reply: [UInt8] = [0x3F]
            for i in 1..<256 { reply += [0x01, UInt8(i), memory[i], memory[i]] }
            reply += [0x02, 0x00, 0x80, 0x80, 0x3F]
            self.reply = reply
        }

        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            if index == reply.count { index = 0 }
            if index == 0 { dumps += 1 }
            let n = min(size, reply.count - index)
            reply.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + index, byteCount: n) }
            index += n
            return n
        }

        /// The profile ring stores dives newest first and each one backwards, ending in 0x80 and its surface byte.
        static func memory(dives: Int) -> [UInt8] {
            var memory = [UInt8](repeating: 0, count: 256)
            memory[0x18] = 0x20
            memory.replaceSubrange(0x1D...0x1F, with: [0x12, 0x34, 0x56])
            memory[0x20] = 0x82
            var p = 0x21
            for k in 0..<dives {
                let dive: [UInt8] = [0x10, 0x20, 0x30, 10, 10, 0, 0xF6, 0xF6, 0x80, UInt8(k + 1)]
                for b in dive.reversed() { memory[p] = b; p += 1 }
            }
            // The tail of an older, overwritten dive: its marker ends the last listed one.
            memory[p] = 0x05
            memory[p + 1] = 0x80
            return memory
        }
    }

    private func openSolution(_ fake: FakeSolution, stores: Stores, lease: DiveComputerSessionLease) throws -> DiveComputerSession {
        keepAlive.append(fake)
        let context = try newContext()
        var cbs = dc_custom_cbs_t()
        cbs.read = { userdata, data, size, actual in
            actual?.pointee = Unmanaged<FakeSolution>.fromOpaque(userdata!).takeUnretainedValue().hostRead(into: data!, size: size)
            return DC_STATUS_SUCCESS
        }
        cbs.write = { _, _, size, actual in actual?.pointee = size; return DC_STATUS_SUCCESS }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(fake).toOpaque()), DC_STATUS_SUCCESS)
        let session = try DiveComputerSession.open(
            iostream: try XCTUnwrap(iostream), context: context, family: DC_FAMILY_SUUNTO_SOLUTION, model: 0,
            displayName: "Suunto Solution", storageKey: "serial:solution", deviceStorage: stores.devices, lease: lease)
        addTeardownBlock { session.close() }
        return session
    }

    static func stubDive() -> DiveData {
        DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_700_000_000), maxDepth: 6, avgDepth: 3, divetime: 900,
                 temperature: 20, profile: [], tankPressure: [], gasMix: nil, gasMixCount: nil, gasMixes: nil,
                 salinity: nil, atmospheric: nil, surfaceTemperature: nil, minTemperature: nil, maxTemperature: nil,
                 tankCount: nil, tanks: nil, diveMode: nil, decoModel: nil, location: nil, rbt: nil, heartbeat: nil,
                 bearing: nil, setpoint: nil, ppo2Readings: [], cns: nil, decoStop: nil)
    }

    func testDivesWithoutAFingerprintStillDownloadAndNeverCommit() throws {
        let fake = FakeSolution(memory: FakeSolution.memory(dives: 3))
        let stores = stores()
        let lease = DiveComputerSessionLease()
        var fingerprints: [Data] = []
        var parseErrors: [Error] = []
        // The Solution parser has no datetime, so the hook stands in for a dated parse.
        let stub: DiveLogRetriever.ParseHook = { fingerprint, parse in
            fingerprints.append(fingerprint)
            do { _ = try parse() } catch { parseErrors.append(error) }
            return Self.stubDive()
        }

        let session = try openSolution(fake, stores: stores, lease: lease)
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let result = try XCTUnwrap(download(session, viewModel: viewModel, parseHook: stub))
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.divesDownloaded, 3)
        XCTAssertNil(result.fingerprintCommit, "there is no fingerprint to commit")
        XCTAssertEqual(fingerprints, [Data(), Data(), Data()])
        XCTAssertEqual(parseErrors.count, 3)
        for error in parseErrors {
            guard case GenericParser.ParserError.datetimeRetrievalFailed(DC_STATUS_UNSUPPORTED) = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)
        drainMain { viewModel.dives.count == 3 }
        XCTAssertEqual(viewModel.dives.count, 3)
        session.close()

        let next = try openSolution(fake, stores: stores, lease: lease)
        let again = try XCTUnwrap(download(next, viewModel: DiveDataViewModel(fingerprintStore: stores.fingerprints), parseHook: stub))
        XCTAssertEqual(again.outcome, .completed)
        XCTAssertEqual(again.divesDownloaded, 3, "every download fetches all of them again")
        XCTAssertEqual(fake.dumps, 2)
    }

    func testDivesWithoutAFingerprintReachTheParser() throws {
        let fake = FakeSolution(memory: FakeSolution.memory(dives: 3))
        let stores = stores()
        let session = try openSolution(fake, stores: stores, lease: DiveComputerSessionLease())

        let result = try XCTUnwrap(download(session, viewModel: DiveDataViewModel(fingerprintStore: stores.fingerprints)))
        XCTAssertEqual(result.outcome, .unreadableDives(3), "the walk no longer stops at the first dive")
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertNil(result.fingerprintCommit)
        XCTAssertNil(stores.devices.getStoredDevice(uuid: "serial:solution"), "the unreported model 0 isn't stored")
    }

    // MARK: - Cancel

    func testACancelBetweenDivesIsReportedAndSavesNothing() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let stores = stores()
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let session = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        // The newest dive is in hand by the time the second stream starts.
        watch.onStreamStart = { [weak session] count in if count == 2 { session?.cancel() } }

        let result = try XCTUnwrap(download(session, viewModel: viewModel))
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.divesDownloaded, 1)
        XCTAssertNil(result.fingerprintCommit)
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)
        drainMain { viewModel.progress == .cancelled }
        XCTAssertEqual(viewModel.lastDownloadStatus, "cancelled")
        XCTAssertNil(viewModel.lastDownloadInterruption)
    }

    func testACancelBeforeTheDownloadEndsItWithoutTouchingTheDevice() throws {
        let watch = FakeWatch(dives: [Self.diveA])
        let stores = stores()
        let session = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        session.cancel()
        let streamsBefore = watch.streamsServed

        let result = try XCTUnwrap(download(session, viewModel: DiveDataViewModel(fingerprintStore: stores.fingerprints)))
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.divesDownloaded, 0)
        XCTAssertEqual(watch.streamsServed, streamsBefore)
        XCTAssertFalse(session.isDownloading)
    }

    func testCloseDuringADownloadCancelsItAndClosesWhenItEnds() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let stores = stores()
        let lease = DiveComputerSessionLease()
        let session = try openNautic(watch, stores: stores, lease: lease)

        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: DiveDataViewModel(fingerprintStore: stores.fingerprints)) {
            result = $0
            done.fulfill()
        }
        session.close()
        XCTAssertFalse(session.isClosed, "the close waits for the download")
        XCTAssertTrue(session.isCancelled)
        wait(for: [done], timeout: 10)

        XCTAssertEqual(result?.outcome, .cancelled)
        XCTAssertTrue(session.isClosed)
        XCTAssertFalse(lease.isHeld)
        XCTAssertTrue(stores.fingerprints.loadFingerprints().isEmpty)
    }

    func testASecondDownloadOnTheSameSessionIsRefusedWhileOneRuns() throws {
        let watch = FakeWatch(dives: [Self.diveA])
        let stores = stores()
        let session = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)

        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var refused: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { _ in first.fulfill() }
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { refused = $0; second.fulfill() }
        wait(for: [first, second], timeout: 10)
        XCTAssertEqual(refused?.outcome, .failed(DC_STATUS_INVALIDARGS))
    }

    // MARK: - Lease and ownership

    func testTheLeaseAllowsOneOpenSessionAtATime() throws {
        let stores = stores()
        let lease = DiveComputerSessionLease()
        let first = try openNautic(FakeWatch(dives: [Self.diveA]), stores: stores, lease: lease)
        XCTAssertTrue(lease.isHeld)

        XCTAssertThrowsError(try openNautic(FakeWatch(dives: [Self.diveA]), stores: stores, lease: lease)) {
            XCTAssertEqual($0 as? DiveComputerSessionError, .busy)
        }
        XCTAssertThrowsError(try DiveComputerSession.adopt(devicePtr: first.devicePtr, displayName: "x", storageKey: "y", lease: lease)) {
            XCTAssertEqual($0 as? DiveComputerSessionError, .busy)
        }

        first.close()
        first.close()
        XCTAssertTrue(first.isClosed)
        XCTAssertFalse(lease.isHeld)
        XCTAssertNoThrow(try openNautic(FakeWatch(dives: [Self.diveA]), stores: stores, lease: lease))
    }

    func testAFailedOpenReleasesTheLease() throws {
        let lease = DiveComputerSessionLease()
        let context = try newContext()
        let iostream = try nauticStream(FakeWatch(dives: []), context: context)
        XCTAssertThrowsError(try DiveComputerSession.open(
            iostream: iostream, context: context, family: DC_FAMILY_SUUNTO_NAUTIC, model: 99,
            displayName: "x", storageKey: "y", lease: lease)) {
            XCTAssertEqual($0 as? DiveComputerSessionError, .openFailed(DC_STATUS_UNSUPPORTED))
        }
        XCTAssertFalse(lease.isHeld)
    }

    func testAdoptingADeviceDataWithNoDeviceIsRefused() {
        let lease = DiveComputerSessionLease()
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        defer { data.deallocate() }
        XCTAssertThrowsError(try DiveComputerSession.adopt(devicePtr: data, displayName: "x", storageKey: "y", lease: lease)) {
            XCTAssertEqual($0 as? DiveComputerSessionError, .noDevice)
        }
        XCTAssertFalse(lease.isHeld)
    }

    func testTheLookupViewModelIsHeldUntilClose() throws {
        let watch = FakeWatch(dives: [Self.diveA])
        let stores = stores()
        let session = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        weak var weakViewModel: DiveDataViewModel?
        do {
            let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
            weakViewModel = viewModel
            XCTAssertEqual(download(session, viewModel: viewModel)?.outcome, .completed)
        }
        drainMain()
        XCTAssertNotNil(weakViewModel, "the device's DEVINFO lookup can still run")
        XCTAssertNotNil(session.devicePtr.pointee.fingerprint_context)

        session.close()
        drainMain { weakViewModel == nil }
        XCTAssertNil(weakViewModel)
    }

    func testAnAdoptedSessionLeavesTheDeviceOpenOnClose() throws {
        let watch = FakeWatch(dives: [Self.diveA])
        let stores = stores()
        let owner = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        let lease = DiveComputerSessionLease()
        let adopted = try DiveComputerSession.adopt(devicePtr: owner.devicePtr, displayName: owner.displayName,
                                                    storageKey: owner.storageKey, deviceStorage: stores.devices, lease: lease)
        XCTAssertEqual(adopted.transport, DC_TRANSPORT_BLE)
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let result = try XCTUnwrap(download(adopted, viewModel: viewModel))
        XCTAssertEqual(result.outcome, .completed)
        result.fingerprintCommit?.acknowledge()

        adopted.close()
        XCTAssertFalse(lease.isHeld)
        XCTAssertNotNil(owner.devicePtr.pointee.device, "the owner still holds an open device")
        XCTAssertNil(owner.devicePtr.pointee.fingerprint_context, "the adopted session's lookup is withdrawn")
    }

    func testAnAdoptedBLESessionKeysItsCommitByIdentity() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let stores = stores()
        let owner = try openNautic(watch, stores: stores, lease: DiveComputerSessionLease())
        let adopted = try DiveComputerSession.adopt(devicePtr: owner.devicePtr, displayName: owner.displayName,
                                                    storageKey: owner.storageKey, locator: .ble(uuid: owner.storageKey),
                                                    deviceStorage: stores.devices, lease: DiveComputerSessionLease())
        addTeardownBlock { adopted.close() }
        XCTAssertEqual(adopted.locator, .ble(uuid: "FAKE-UUID"))

        let result = try XCTUnwrap(download(adopted, viewModel: DiveDataViewModel(fingerprintStore: stores.fingerprints)))
        let identity = try XCTUnwrap(result.identity)
        XCTAssertEqual(identity.family, .suuntoNautic)
        XCTAssertEqual(identity.serial, Self.serial)
        XCTAssertEqual(identity.transport, .ble)
        XCTAssertEqual(identity.deviceKey, "sn:" + Self.serial)
        let commit = try XCTUnwrap(result.fingerprintCommit)
        XCTAssertEqual(commit.identity, identity)
        commit.acknowledge()
        XCTAssertEqual(stores.fingerprints.loadFingerprints().map(\.key), [identity.storageKey()])
        XCTAssertEqual(stores.fingerprints.getFingerprint(forDeviceType: Self.deviceType, serial: Self.serial)?.fingerprint,
                       Self.le32(Self.diveB.id), "a 1.18 lookup still finds it")
    }

    func testClosingADeviceDataClearsItsFingerprintLookup() throws {
        let watch = FakeWatch(dives: [Self.diveA])
        let data = try descriptorlessNautic(watch)
        let viewModel = DiveDataViewModel(fingerprintStore: stores().fingerprints)
        data.pointee.fingerprint_context = Unmanaged.passUnretained(viewModel).toOpaque()
        data.pointee.lookup_fingerprint = { _, _, _, _ in nil }

        libdc_close_device_data(data)
        XCTAssertNil(data.pointee.device)
        XCTAssertNil(data.pointee.fingerprint_context)
        XCTAssertNil(data.pointee.lookup_fingerprint)
    }

    // MARK: - Commit and result values

    func testAnAcknowledgementOffTheMainThreadSavesOnTheMainThread() {
        let saved = expectation(description: "saved")
        var saves = 0
        let commit = FingerprintCommit(fingerprint: Data([1, 2, 3, 4]), deviceType: "Suunto Ocean", serial: "s") {
            XCTAssertTrue(Thread.isMainThread)
            saves += 1
            saved.fulfill()
        }
        DispatchQueue.global().async {
            commit.acknowledge()
            commit.acknowledge()
        }
        wait(for: [saved], timeout: 5)
        drainMain()
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(commit.isAcknowledged)
    }

    func testAViewModelCommitAcknowledgedInTheBackgroundReachesTheStore() {
        let stores = stores()
        let viewModel = DiveDataViewModel(fingerprintStore: stores.fingerprints)
        let commit = FingerprintCommit(fingerprint: Self.le32(Self.diveA.id), deviceType: Self.deviceType,
                                       serial: Self.serial, viewModel: viewModel)
        let acknowledged = expectation(description: "acknowledged")
        DispatchQueue.global().async {
            commit.acknowledge()
            acknowledged.fulfill()
        }
        wait(for: [acknowledged], timeout: 5)
        drainMain { stores.fingerprints.loadFingerprints().count == 1 }
        XCTAssertEqual(stores.fingerprints.getFingerprint(forDeviceType: Self.deviceType, serial: Self.serial)?.fingerprint,
                       Self.le32(Self.diveA.id))
    }

    func testHostsCanBuildResults() {
        let commit = FingerprintCommit(fingerprint: Data([9]), deviceType: "t", serial: "s") {}
        let result = DiveDownloadResult(outcome: .completed, divesDownloaded: 2, fingerprintCommit: commit)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(result.parseFailureCount, 0)
        XCTAssertTrue(result.fingerprintCommit === commit)
        XCTAssertFalse(DiveDownloadResult(outcome: .interrupted(DC_STATUS_IO), status: DC_STATUS_IO).succeeded)
    }

    // MARK: - Cancel through libdivecomputer (cable transports)

    final class SilentStream {
        var writes = 0
    }

    private func openVyper(transport: dc_transport_t, lease: DiveComputerSessionLease) throws -> (DiveComputerSession, SilentStream) {
        let fake = SilentStream()
        keepAlive.append(fake)
        let context = try newContext()
        var cbs = dc_custom_cbs_t()
        cbs.read = { _, _, _, actual in actual?.pointee = 0; return DC_STATUS_TIMEOUT }
        cbs.write = { userdata, _, size, actual in
            Unmanaged<SilentStream>.fromOpaque(userdata!).takeUnretainedValue().writes += 1
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, transport, &cbs, Unmanaged.passUnretained(fake).toOpaque()), DC_STATUS_SUCCESS)
        // Suunto Vyper opens with no reply needed.
        let session = try DiveComputerSession.open(
            iostream: try XCTUnwrap(iostream), context: context, family: DC_FAMILY_SUUNTO_VYPER, model: 0x0A,
            displayName: "Suunto Vyper", storageKey: "serial:test", lease: lease)
        addTeardownBlock { session.close() }
        return (session, fake)
    }

    func testACableSessionCancelStopsTheNextTransfer() throws {
        let (session, fake) = try openVyper(transport: DC_TRANSPORT_SERIAL, lease: DiveComputerSessionLease())
        XCTAssertEqual(session.transport, DC_TRANSPORT_SERIAL)
        let device = try XCTUnwrap(session.devicePtr.pointee.device)
        var byte: UInt8 = 0

        session.cancel()
        XCTAssertEqual(dc_device_read(device, 0, &byte, 1), DC_STATUS_CANCELLED)
        XCTAssertEqual(fake.writes, 0, "a cancelled transfer sends nothing")
    }

    func testABLESessionKeepsThePerDiveCancelOnly() throws {
        let (session, fake) = try openVyper(transport: DC_TRANSPORT_BLE, lease: DiveComputerSessionLease())
        let device = try XCTUnwrap(session.devicePtr.pointee.device)
        var byte: UInt8 = 0

        session.cancel()
        XCTAssertNotEqual(dc_device_read(device, 0, &byte, 1), DC_STATUS_CANCELLED)
        XCTAssertGreaterThan(fake.writes, 0)
    }

    // MARK: - Outcome rules

    private func sessionOutcome(_ status: dc_status_t, cancelled: Bool = false, failures: Int = 0, matched: Bool = false,
                                stored: Bool = true, newDives: Bool, empty: Int = 0,
                                family: dc_family_t = DC_FAMILY_SHEARWATER_PETREL) -> (DiveDownloadResult.Outcome, Bool) {
        let legacy = DiveLogRetriever.outcome(status: status, family: family, fingerprintMatched: matched,
                                              hasNewDives: newDives, hadStoredFingerprint: stored, emptyReadCount: empty)
        let r = DiveLogRetriever.sessionOutcome(legacy, status: status, cancelled: cancelled, parseFailureCount: failures,
                                                fingerprintMatched: matched, hadStoredFingerprint: stored, hasNewDives: newDives)
        return (r.outcome, r.commits)
    }

    func testOnlyACompleteFullyParsedWalkCommits() {
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, newDives: true) == (.completed, true))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, failures: 2, newDives: true) == (.unreadableDives(2), false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, failures: 1, newDives: false) == (.unreadableDives(1), false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, cancelled: true, newDives: true) == (.cancelled, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_CANCELLED, newDives: true) == (.cancelled, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_CANCELLED, newDives: false) == (.cancelled, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, newDives: true, empty: 1) == (.completed, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, newDives: false, empty: 2) == (.emptyRead, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_IO, newDives: true) == (.interrupted(DC_STATUS_IO), false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_IO, newDives: false) == (.failed(DC_STATUS_IO), false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_IO, failures: 1, newDives: true) == (.interrupted(DC_STATUS_IO), false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, newDives: false) == (.noNewDives, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_SUCCESS, stored: false, newDives: false) == (.completed, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_PROTOCOL, matched: true, newDives: false) == (.noNewDives, false))
        XCTAssertTrue(sessionOutcome(DC_STATUS_PROTOCOL, newDives: false, family: DC_FAMILY_SUUNTO_NAUTIC) == (.failed(DC_STATUS_PROTOCOL), false))
    }

    // MARK: - Hardware model

    private func devinfoData(model: UInt32) -> UnsafeMutablePointer<device_data_t> {
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.have_devinfo = 1
        data.pointee.devinfo.model = model
        addTeardownBlock { data.deallocate() }
        return data
    }

    func testASessionKeepsTheStoredModelWhenNoDescriptorKnowsTheHardwareOne() {
        let storage = stores().devices
        storage.storeDevice(uuid: "U", name: "Perdix", family: .shearwaterPetrel, model: 5)
        XCTAssertFalse(DeviceConfiguration.hasDescriptor(family: DC_FAMILY_SHEARWATER_PETREL, model: 0xEE))

        DeviceConfiguration.updateDeviceConfigurationFromHardware(
            deviceAddress: "U", deviceDataPtr: devinfoData(model: 0xEE), deviceName: "Perdix",
            storage: storage, requireKnownModel: true)
        XCTAssertEqual(storage.getStoredDevice(uuid: "U")?.model, 5)

        DeviceConfiguration.updateDeviceConfigurationFromHardware(
            deviceAddress: "U", deviceDataPtr: devinfoData(model: 0xEE), deviceName: "Perdix",
            storage: storage, requireKnownModel: false)
        XCTAssertEqual(storage.getStoredDevice(uuid: "U")?.model, 0xEE, "the legacy rule stores any hardware model")
    }

    func testASessionNeverStoresAnUnreportedHardwareModel() {
        let storage = stores().devices
        storage.storeDevice(uuid: "U", name: "Suunto Ocean 1", family: .suuntoNautic, model: 1)
        XCTAssertTrue(DeviceConfiguration.hasDescriptor(family: DC_FAMILY_SUUNTO_NAUTIC, model: 0), "0 is a real Nautic model too")

        DeviceConfiguration.updateDeviceConfigurationFromHardware(
            deviceAddress: "U", deviceDataPtr: devinfoData(model: 0), deviceName: "Suunto Ocean 1",
            storage: storage, requireKnownModel: true)
        XCTAssertEqual(storage.getStoredDevice(uuid: "U")?.model, 1)
    }

    func testASessionStoresAHardwareModelADescriptorKnows() {
        let storage = stores().devices
        storage.storeDevice(uuid: "U", name: "Perdix", family: .shearwaterPetrel, model: 5)
        XCTAssertTrue(DeviceConfiguration.hasDescriptor(family: DC_FAMILY_SHEARWATER_PETREL, model: 6))

        DeviceConfiguration.updateDeviceConfigurationFromHardware(
            deviceAddress: "U", deviceDataPtr: devinfoData(model: 6), deviceName: "Perdix",
            storage: storage, requireKnownModel: true)
        XCTAssertEqual(storage.getStoredDevice(uuid: "U")?.model, 6)
    }
}
