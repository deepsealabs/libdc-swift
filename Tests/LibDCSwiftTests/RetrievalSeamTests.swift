import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Exercises the seam `retrieveDiveLogs`'s `CBPeripheral` overload forwards to, end to end against a real `FakeWatch` (reusing `SuuntoNauticTransportTests.FakeWatch`).
final class RetrievalSeamTests: XCTestCase {

    private func emptyDevicePtr() -> UnsafeMutablePointer<device_data_t> {
        let ptr = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        ptr.initialize(to: device_data_t())
        return ptr
    }

    func testNoDeviceConnectionFailsThroughTheSeamWithoutABluetoothManager() {
        let ptr = emptyDevicePtr()
        defer { ptr.deallocate() }
        let viewModel = DiveDataViewModel()

        var isCancelledCallCount = 0
        var markFinishedCallCount = 0
        let done = expectation(description: "completion")
        var result: Bool?

        DiveLogRetriever.retrieveDiveLogs(
            from: ptr,
            deviceName: "Test Device",
            deviceUUID: "TEST-UUID",
            viewModel: viewModel,
            isCancelled: { isCancelledCallCount += 1; return false },
            markFinished: { markFinishedCallCount += 1 },
            completion: { success in
                result = success
                done.fulfill()
            }
        )

        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, false, "a nil device pointer must fail, not crash")
        XCTAssertEqual(markFinishedCallCount, 1, "markFinished must run exactly once, matching the CBPeripheral overload")
        // The nil-device guard returns before any per-dive callback, so isCancelled is never consulted.
        XCTAssertEqual(isCancelledCallCount, 0)

        let finishedExpectation = expectation(description: "progress observed")
        DispatchQueue.main.async { finishedExpectation.fulfill() }
        wait(for: [finishedExpectation], timeout: 2)
        guard case .failed = viewModel.progress else {
            return XCTFail("expected .failed, got \(viewModel.progress)")
        }
    }

    // MARK: - End to end against a FakeWatch

    private typealias FakeWatch = SuuntoNauticTransportTests.FakeWatch
    private typealias FakeDive = SuuntoNauticTransportTests.FakeDive

    /// Two reliably non-empty synthetic dives (verified: both produce a
    /// divetime over the `isEmptyRead` threshold), oldest first.
    private static let diveA = FakeDive(id: 1_789_750_000, profileBytes: 600, summaryBytes: 100)
    private static let diveB = FakeDive(id: 1_789_757_200, profileBytes: 600, summaryBytes: 100)
    /// A header-only payload: always parses to zero samples and zero divetime, i.e. an empty read.
    private static func emptyDive(id: UInt32) -> FakeDive { FakeDive(id: id, profileBytes: 8, summaryBytes: 8) }

    private struct Session {
        var context: OpaquePointer?
        var iostream: OpaquePointer?
        var device: OpaquePointer?
    }

    private var openSessions: [Session] = []

    override func tearDown() {
        for s in openSessions { Self.closeSession(s) }
        openSessions.removeAll()
        modelStrings.forEach { free($0) }
        modelStrings.removeAll()
        super.tearDown()
    }

    private static func closeSession(_ s: Session) {
        if let d = s.device { dc_device_close(d) }
        if let io = s.iostream { dc_iostream_close(io) }
        if let c = s.context { dc_context_free(c) }
    }

    /// Closes the most recently opened session now, so a second open on the
    /// same `FakeWatch` isn't layered on a link the fake still thinks is live.
    private func closeMostRecentlyOpenedSession() {
        guard let s = openSessions.popLast() else { return }
        Self.closeSession(s)
    }

    private static func watch(_ userdata: UnsafeMutableRawPointer?) -> FakeWatch {
        Unmanaged<FakeWatch>.fromOpaque(userdata!).takeUnretainedValue()
    }

    /// Opens a Suunto Nautic `dc_device_t` against `watch` over a custom
    /// iostream, mirroring `SuuntoNauticTransportTests.open(_:)`.
    private func openDevice(_ watch: FakeWatch) throws -> OpaquePointer {
        var session = Session()
        XCTAssertEqual(dc_context_new(&session.context), DC_STATUS_SUCCESS)

        var cbs = dc_custom_cbs_t()
        cbs.set_timeout = { _, _ in DC_STATUS_SUCCESS }
        cbs.read = { userdata, data, size, actual in
            guard let n = RetrievalSeamTests.watch(userdata).hostRead(into: data!, size: size) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            guard RetrievalSeamTests.watch(userdata).hostWrote(UnsafeRawBufferPointer(start: data, count: size)) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        cbs.purge = { _, _ in DC_STATUS_SUCCESS }
        cbs.sleep = { _, _ in DC_STATUS_SUCCESS }
        cbs.close = { _ in DC_STATUS_SUCCESS }

        let userdata = Unmanaged.passUnretained(watch).toOpaque()
        XCTAssertEqual(dc_custom_open(&session.iostream, session.context, DC_TRANSPORT_BLE, &cbs, userdata), DC_STATUS_SUCCESS)

        var descriptor: OpaquePointer?
        var iterator: OpaquePointer?
        XCTAssertEqual(dc_descriptor_iterator_new(&iterator, session.context), DC_STATUS_SUCCESS)
        var candidate: OpaquePointer?
        while dc_iterator_next(iterator, &candidate) == DC_STATUS_SUCCESS {
            if dc_descriptor_get_type(candidate) == DC_FAMILY_SUUNTO_NAUTIC {
                descriptor = candidate
                break
            }
            dc_descriptor_free(candidate)
        }
        dc_iterator_free(iterator)
        let desc = try XCTUnwrap(descriptor, "no Suunto Nautic descriptor")
        defer { dc_descriptor_free(desc) }

        XCTAssertEqual(dc_device_open(&session.device, session.context, desc, session.iostream), DC_STATUS_SUCCESS)
        openSessions.append(session)
        return try XCTUnwrap(session.device)
    }

    /// Captures `DC_EVENT_DEVINFO` into `devicePtr`, the same way the production
    /// BLE-open path's C event handler (`ble_device_event_cb`) does.
    private static let devInfoCallback: dc_event_callback_t = { _, event, data, userdata in
        guard event == DC_EVENT_DEVINFO, let data, let userdata else { return }
        let devData = userdata.assumingMemoryBound(to: device_data_t.self)
        devData.pointee.devinfo = data.load(as: dc_event_devinfo_t.self)
        devData.pointee.have_devinfo = 1
    }

    private var modelStrings: [UnsafeMutablePointer<CChar>] = []

    /// Opens `watch` and wires its `dc_device_t` into a fresh `device_data_t`,
    /// with devinfo capture registered exactly like a real BLE connection.
    /// `modelName` stands in for the descriptor-derived `model` C string the
    /// production connect flow sets (`"%s %s", vendor, product`): without it,
    /// the Nautic driver's own fingerprint-match-stops-the-download path in
    /// `diveCallbackClosure` never has a `deviceTypeFromLibDC` to look up.
    private func devicePtr(for watch: FakeWatch, modelName: String = "Suunto Ocean 123456") throws -> UnsafeMutablePointer<device_data_t> {
        let device = try openDevice(watch)
        let ptr = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        ptr.initialize(to: device_data_t())
        ptr.pointee.device = device
        let model = strdup(modelName)
        modelStrings.append(model!)
        ptr.pointee.model = UnsafePointer(model)
        let events = DC_EVENT_DEVINFO.rawValue | DC_EVENT_PROGRESS.rawValue | DC_EVENT_CLOCK.rawValue
        XCTAssertEqual(dc_device_set_events(device, events, Self.devInfoCallback, UnsafeMutableRawPointer(ptr)), DC_STATUS_SUCCESS)
        return ptr
    }

    /// `finalizeDiveNumbering`/`updateProgress` each hop through their own
    /// `DispatchQueue.main.async`, on top of the completion handler's own --
    /// a single extra drain isn't always enough under CI scheduling, so poll.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            let step = expectation(description: "drain")
            DispatchQueue.main.async { step.fulfill() }
            wait(for: [step], timeout: 1)
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }

    /// `updateProgress` only ever sets a terminal case after the download finishes.
    private func isTerminal(_ progress: DiveDataViewModel.DownloadProgress) -> Bool {
        switch progress {
        case .inProgress, .notStarted: return false
        default: return true
        }
    }

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.retrievalseam.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    @discardableResult
    private func download(
        _ devicePtr: UnsafeMutablePointer<device_data_t>,
        deviceUUID: String = "FAKE-UUID",
        viewModel: DiveDataViewModel,
        deviceStorage: DeviceStorage,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        let done = expectation(description: "download")
        var result = false
        DiveLogRetriever.retrieveDiveLogs(
            from: devicePtr,
            deviceName: "Suunto Ocean 123456",
            deviceUUID: deviceUUID,
            viewModel: viewModel,
            isCancelled: isCancelled,
            markFinished: {},
            deviceStorage: deviceStorage,
            completion: { success in result = success; done.fulfill() }
        )
        wait(for: [done], timeout: 5)
        return result
    }

    func testACountLandingAfterTheEndDoesNotReopenTheDownload() {
        let viewModel = DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedSuite("fp")))
        func drain(turns: Int = 3) {
            for _ in 0..<turns {
                let step = expectation(description: "turn")
                DispatchQueue.main.async { step.fulfill() }
                wait(for: [step], timeout: 1)
            }
        }
        viewModel.updateProgress(count: 1)
        drain()
        XCTAssertEqual(viewModel.progress, .inProgress(1))

        // appendDives queues its count a turn late, so it can follow the download's own end.
        viewModel.updateProgress(.completed)
        viewModel.updateProgress(count: 2)
        drain()
        XCTAssertEqual(viewModel.progress, .completed)

        viewModel.updateProgress(.noNewDives)
        viewModel.updateProgress(count: 3)
        drain()
        XCTAssertEqual(viewModel.progress, .noNewDives)

        viewModel.resetProgress()
        drain()
        viewModel.updateProgress(count: 4)
        drain()
        XCTAssertEqual(viewModel.progress, .inProgress(4), "the next download counts again")
    }

    func testDownloadReportsDivesOldestFirstWithSerialKeyedFingerprint() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let ptr = try devicePtr(for: watch)
        defer { ptr.deallocate() }
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let deviceStorage = DeviceStorage(userDefaults: isolatedSuite("dev"))
        // updateDeviceSerial only updates an existing record, so pre-store one
        // (as the BLE connect flow would) to see the serial land in it.
        deviceStorage.storeDevice(uuid: "FAKE-UUID", name: "Suunto Ocean 123456", family: .suuntoNautic, model: 1)

        XCTAssertTrue(download(ptr, viewModel: viewModel, deviceStorage: deviceStorage))
        waitUntil { isTerminal(viewModel.progress) }

        XCTAssertEqual(viewModel.dives.map(\.number), [1, 2], "finalizeDiveNumbering renumbers oldest=#1")
        XCTAssertEqual(viewModel.dives.map(\.datetime).sorted(), viewModel.dives.map(\.datetime))
        guard case .completed = viewModel.progress else { return XCTFail("expected .completed, got \(viewModel.progress)") }

        // "/Info" on FakeWatch reports serial 2604C3003306, truncated to the low 32 bits.
        XCTAssertEqual(deviceStorage.getStoredDevice(uuid: "FAKE-UUID")?.serial, "c3003306")
        XCTAssertNotNil(fingerprints.getFingerprint(forDeviceType: "Suunto Ocean", serial: "c3003306"))
    }

    func testDownloadPrefersTheStoredModelNameOverTheAdvertisedNameForTheFingerprintKey() throws {
        let watch = FakeWatch(dives: [Self.diveA])
        let ptr = try devicePtr(for: watch)
        defer { ptr.deallocate() }
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let deviceStorage = DeviceStorage(userDefaults: isolatedSuite("dev"))
        deviceStorage.storeDevice(uuid: "FAKE-UUID", name: "whatever was last advertised", family: .suuntoNautic, model: 1)

        XCTAssertTrue(download(ptr, viewModel: viewModel, deviceStorage: deviceStorage))
        XCTAssertNotNil(fingerprints.getFingerprint(forDeviceType: "Suunto Ocean", serial: "c3003306"),
            "the stored device's supportedModels name ('Suunto Ocean') must win over the raw BLE name")
    }

    func testASecondDownloadStopsAtTheMatchingFingerprintAndDoesNotAppendDives() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let deviceStorage = DeviceStorage(userDefaults: isolatedSuite("dev"))

        let first = try devicePtr(for: watch)
        defer { first.deallocate() }
        XCTAssertTrue(download(first, viewModel: viewModel, deviceStorage: deviceStorage))
        waitUntil { isTerminal(viewModel.progress) }
        let afterFirstRun = viewModel.dives.count
        XCTAssertEqual(afterFirstRun, 2)

        // A second connection to the same (unchanged) watch: close the first
        // link and let the fake reset its session before opening a new one.
        closeMostRecentlyOpenedSession()
        watch.reconnect()
        let second = try devicePtr(for: watch)
        defer { second.deallocate() }
        XCTAssertTrue(download(second, viewModel: viewModel, deviceStorage: deviceStorage))
        waitUntil { isTerminal(viewModel.progress) }

        XCTAssertEqual(viewModel.dives.count, afterFirstRun, "no new dives on the second run")
        guard case .noNewDives = viewModel.progress else { return XCTFail("expected .noNewDives, got \(viewModel.progress)") }
    }

    /// Characterizes real, slightly surprising behavior: the Nautic driver's
    /// `dc_device_foreach` loop breaks on a 0 return from the per-dive callback
    /// (where `isCancelled` is checked) without changing its own status, which
    /// stays DC_STATUS_SUCCESS from the last dive that DID download. So a
    /// between-dive cancel is indistinguishable from a short, successful
    /// download -- the dives already in hand are kept and fingerprinted.
    func testCancellingBetweenDivesKeepsWhicheverDivesAlreadyDownloaded() throws {
        let watch = FakeWatch(dives: [Self.diveA, Self.diveB])
        let ptr = try devicePtr(for: watch)
        defer { ptr.deallocate() }
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let deviceStorage = DeviceStorage(userDefaults: isolatedSuite("dev"))

        // isCancelled is consulted once per dive, synchronously on the retrieval
        // queue, before that dive is processed: let the first (newest, diveB)
        // through, then stop before the second (diveA).
        var divesOffered = 0
        let result = download(ptr, viewModel: viewModel, deviceStorage: deviceStorage, isCancelled: {
            divesOffered += 1
            return divesOffered > 1
        })
        XCTAssertTrue(result)
        waitUntil { isTerminal(viewModel.progress) }

        XCTAssertEqual(viewModel.dives.map(\.datetime), [Date(timeIntervalSince1970: TimeInterval(1_789_757_200))])
        guard case .completed = viewModel.progress else { return XCTFail("expected .completed, got \(viewModel.progress)") }
        XCTAssertNotNil(fingerprints.getFingerprint(forDeviceType: "Suunto Ocean 123456", serial: "c3003306"))
    }

    func testAllEmptyReadsProduceEmptyReadWithNoFingerprintSaved() throws {
        let watch = FakeWatch(dives: [Self.emptyDive(id: 1_789_900_000), Self.emptyDive(id: 1_789_900_100)])
        let ptr = try devicePtr(for: watch)
        defer { ptr.deallocate() }
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedSuite("fp"))
        let viewModel = DiveDataViewModel(fingerprintStore: fingerprints)
        let deviceStorage = DeviceStorage(userDefaults: isolatedSuite("dev"))

        let result = download(ptr, viewModel: viewModel, deviceStorage: deviceStorage)
        XCTAssertFalse(result, "an all-empty read is not reported as success")
        waitUntil { isTerminal(viewModel.progress) }

        XCTAssertTrue(viewModel.dives.isEmpty)
        guard case .emptyRead = viewModel.progress else { return XCTFail("expected .emptyRead, got \(viewModel.progress)") }
        XCTAssertNil(fingerprints.getFingerprint(forDeviceType: "Suunto Ocean 123456", serial: "c3003306"))
    }

    func testTwoConcurrentDownloadsDoNotShareDiveListsOrFingerprints() throws {
        let watchA = FakeWatch(dives: [Self.diveA])
        let watchB = FakeWatch(dives: [Self.diveB])
        let ptrA = try devicePtr(for: watchA, modelName: "Suunto Ocean AAA")
        let ptrB = try devicePtr(for: watchB, modelName: "Suunto Ocean BBB")
        defer { ptrA.deallocate(); ptrB.deallocate() }

        let fingerprintsA = DeviceFingerprintStorage(userDefaults: isolatedSuite("fpA"))
        let fingerprintsB = DeviceFingerprintStorage(userDefaults: isolatedSuite("fpB"))
        let viewModelA = DiveDataViewModel(fingerprintStore: fingerprintsA)
        let viewModelB = DiveDataViewModel(fingerprintStore: fingerprintsB)
        let storageA = DeviceStorage(userDefaults: isolatedSuite("devA"))
        let storageB = DeviceStorage(userDefaults: isolatedSuite("devB"))

        let doneA = expectation(description: "A")
        let doneB = expectation(description: "B")
        var resultA: Bool?, resultB: Bool?

        DiveLogRetriever.retrieveDiveLogs(
            from: ptrA, deviceName: "Suunto Ocean AAA", deviceUUID: "UUID-A", viewModel: viewModelA,
            isCancelled: { false }, markFinished: {}, deviceStorage: storageA,
            completion: { resultA = $0; doneA.fulfill() })
        DiveLogRetriever.retrieveDiveLogs(
            from: ptrB, deviceName: "Suunto Ocean BBB", deviceUUID: "UUID-B", viewModel: viewModelB,
            isCancelled: { false }, markFinished: {}, deviceStorage: storageB,
            completion: { resultB = $0; doneB.fulfill() })

        wait(for: [doneA, doneB], timeout: 5)
        XCTAssertEqual(resultA, true)
        XCTAssertEqual(resultB, true)
        waitUntil { isTerminal(viewModelA.progress) && isTerminal(viewModelB.progress) }

        XCTAssertEqual(viewModelA.dives.map(\.datetime), [Date(timeIntervalSince1970: TimeInterval(1_789_750_000))])
        XCTAssertEqual(viewModelB.dives.map(\.datetime), [Date(timeIntervalSince1970: TimeInterval(1_789_757_200))])
        XCTAssertNotNil(fingerprintsA.getFingerprint(forDeviceType: "Suunto Ocean AAA", serial: "c3003306"))
        XCTAssertNotNil(fingerprintsB.getFingerprint(forDeviceType: "Suunto Ocean BBB", serial: "c3003306"))
        XCTAssertNil(storageA.getStoredDevice(uuid: "UUID-B"))
        XCTAssertNil(storageB.getStoredDevice(uuid: "UUID-A"))
    }
}
