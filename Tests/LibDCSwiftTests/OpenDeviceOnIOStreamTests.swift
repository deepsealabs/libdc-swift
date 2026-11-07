import XCTest
import Darwin
import Clibdivecomputer
import LibDCBridge

/// `open_device_on_iostream`, `libdc_set_cancel` and `libdc_cable_transports` against a fake `dc_custom_open` stream.
final class OpenDeviceOnIOStreamTests: XCTestCase {

    // Suunto Vyper's open is configure, set_timeout, set_dtr, sleep, purge, with no reply needed.
    private static let family = DC_FAMILY_SUUNTO_VYPER
    private static let model: UInt32 = 0x0A

    final class FakeStream {
        let configureFailures: Int
        var configureCalls = 0
        var writeCalls = 0
        var closeCalls = 0
        init(configureFailures: Int = 0) { self.configureFailures = configureFailures }
    }

    final class CancelProbe {
        var calls = 0
    }

    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.reversed().forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    private static func fake(_ userdata: UnsafeMutableRawPointer?) -> FakeStream {
        Unmanaged<FakeStream>.fromOpaque(userdata!).takeUnretainedValue()
    }

    private static func makeStream(_ fake: FakeStream, context: OpaquePointer?) -> OpaquePointer? {
        var cbs = dc_custom_cbs_t()
        cbs.configure = { userdata, _, _, _, _, _ in
            let s = OpenDeviceOnIOStreamTests.fake(userdata)
            s.configureCalls += 1
            return s.configureCalls <= s.configureFailures ? DC_STATUS_IO : DC_STATUS_SUCCESS
        }
        cbs.read = { _, _, _, actual in
            actual?.pointee = 0
            return DC_STATUS_TIMEOUT
        }
        cbs.write = { userdata, _, size, actual in
            OpenDeviceOnIOStreamTests.fake(userdata).writeCalls += 1
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        cbs.close = { userdata in
            OpenDeviceOnIOStreamTests.fake(userdata).closeCalls += 1
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        let rc = dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(fake).toOpaque())
        return rc == DC_STATUS_SUCCESS ? iostream : nil
    }

    private static func newData() -> UnsafeMutablePointer<device_data_t> {
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        return data
    }

    private static func newContext() -> OpaquePointer? {
        var context: OpaquePointer?
        return dc_context_new(&context) == DC_STATUS_SUCCESS ? context : nil
    }

    /// Releases what a successful open leaves in `data`, the way an app closes a session.
    private static func closeOpened(_ data: UnsafeMutablePointer<device_data_t>) {
        if let device = data.pointee.device { dc_device_close(device) }
        if let iostream = data.pointee.iostream { dc_iostream_close(iostream) }
        if let context = data.pointee.context { dc_context_free(context) }
        if let model = data.pointee.model { free(UnsafeMutableRawPointer(mutating: model)) }
        data.pointee = device_data_t()
    }

    private struct Opened {
        let status: dc_status_t
        let data: UnsafeMutablePointer<device_data_t>
        let context: OpaquePointer
        let iostream: OpaquePointer
    }

    private func open(_ fake: FakeStream, model: UInt32 = model, attempts: UInt32, retryMs: UInt32 = 0) throws -> Opened {
        let data = Self.newData()
        let context = try XCTUnwrap(Self.newContext())
        let iostream = try XCTUnwrap(Self.makeStream(fake, context: context))
        data.pointee.context = context
        let status = open_device_on_iostream(data, iostream, Self.family, model, attempts, retryMs)
        // The stream's close callback reads the fake, so it must outlive tearDown's close.
        cleanups.append {
            withExtendedLifetime(fake) { Self.closeOpened(data) }
            data.deallocate()
        }
        return Opened(status: status, data: data, context: context, iostream: iostream)
    }

    private func assertReleased(_ data: UnsafeMutablePointer<device_data_t>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(data.pointee.context, "context must be freed", file: file, line: line)
        XCTAssertNil(data.pointee.iostream, "iostream must be closed", file: file, line: line)
        XCTAssertNil(data.pointee.device, file: file, line: line)
        XCTAssertNil(data.pointee.descriptor, file: file, line: line)
        XCTAssertNil(data.pointee.model, file: file, line: line)
    }

    // MARK: - Attempts

    func testBLERetryBudgetIsFiveAttemptsThreeSecondsApart() {
        XCTAssertEqual(LIBDC_BLE_OPEN_ATTEMPTS, 5)
        XCTAssertEqual(LIBDC_BLE_OPEN_RETRY_MS, 3000)
    }

    func testBLEBudgetMakesFiveOpenAttemptsOnOneStream() throws {
        let fake = FakeStream(configureFailures: .max)
        let opened = try open(fake, attempts: UInt32(LIBDC_BLE_OPEN_ATTEMPTS))

        XCTAssertEqual(opened.status, DC_STATUS_IO)
        XCTAssertEqual(fake.configureCalls, 5)
        XCTAssertEqual(fake.closeCalls, 1, "the stream is closed once, after the last attempt")
        assertReleased(opened.data)
    }

    func testCableCallerMakesOneOpenAttempt() throws {
        let fake = FakeStream(configureFailures: .max)
        let opened = try open(fake, attempts: 1)

        XCTAssertEqual(opened.status, DC_STATUS_IO)
        XCTAssertEqual(fake.configureCalls, 1)
        XCTAssertEqual(fake.closeCalls, 1)
        assertReleased(opened.data)
    }

    func testRetryStopsAtTheFirstSuccessfulAttempt() throws {
        let fake = FakeStream(configureFailures: 2)
        let opened = try open(fake, attempts: 5)

        XCTAssertEqual(opened.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(fake.configureCalls, 3)
        XCTAssertEqual(fake.closeCalls, 0)
    }

    func testRetryWaitsBetweenAttemptsButNotBeforeTheFirst() throws {
        let fake = FakeStream(configureFailures: .max)
        let start = Date()
        let opened = try open(fake, attempts: 3, retryMs: 50)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(opened.status, DC_STATUS_IO)
        XCTAssertEqual(fake.configureCalls, 3)
        XCTAssertGreaterThanOrEqual(elapsed, 0.1, "two 50 ms waits")
        XCTAssertLessThan(elapsed, 2.0)
    }

    // MARK: - Success

    func testSuccessfulOpenKeepsTheCallersContextAndStream() throws {
        let fake = FakeStream()
        let opened = try open(fake, attempts: 1)
        let data = opened.data.pointee

        XCTAssertEqual(opened.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data.context, opened.context)
        XCTAssertEqual(data.iostream, opened.iostream)
        XCTAssertNotNil(data.device)
        let descriptor = try XCTUnwrap(data.descriptor)
        XCTAssertEqual(dc_descriptor_get_type(descriptor), Self.family)
        XCTAssertEqual(dc_descriptor_get_model(descriptor), Self.model)
        XCTAssertEqual(data.model.map { String(cString: $0) }, "Suunto Vyper")
        XCTAssertEqual(data.have_devinfo, 0)
        XCTAssertEqual(fake.closeCalls, 0)
    }

    func testOpenResetsLeftoverStateExceptTheContext() throws {
        let fake = FakeStream()
        let data = Self.newData()
        defer { Self.closeOpened(data); data.deallocate() }
        let context = try XCTUnwrap(Self.newContext())
        let iostream = try XCTUnwrap(Self.makeStream(fake, context: context))
        data.pointee.context = context
        data.pointee.have_devinfo = 1
        data.pointee.fdeviceid = 42

        XCTAssertEqual(open_device_on_iostream(data, iostream, Self.family, Self.model, 1, 0), DC_STATUS_SUCCESS)
        XCTAssertEqual(data.pointee.context, context)
        XCTAssertEqual(data.pointee.have_devinfo, 0)
        XCTAssertEqual(data.pointee.fdeviceid, 0)
    }

    // MARK: - Error paths release everything

    func testUnknownModelClosesTheStreamWithoutTouchingIt() throws {
        let fake = FakeStream()
        let opened = try open(fake, model: 0xEE, attempts: 5)

        XCTAssertEqual(opened.status, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(fake.configureCalls, 0, "no I/O before the descriptor resolves")
        XCTAssertEqual(fake.closeCalls, 1)
        assertReleased(opened.data)
    }

    func testZeroAttemptsIsInvalidAndReleasesEverything() throws {
        let fake = FakeStream()
        let opened = try open(fake, attempts: 0)

        XCTAssertEqual(opened.status, DC_STATUS_INVALIDARGS)
        XCTAssertEqual(fake.configureCalls, 0)
        XCTAssertEqual(fake.closeCalls, 1)
        assertReleased(opened.data)
    }

    func testNullIOStreamFreesTheContext() throws {
        let data = Self.newData()
        defer { data.deallocate() }
        data.pointee.context = try XCTUnwrap(Self.newContext())

        XCTAssertEqual(open_device_on_iostream(data, nil, Self.family, Self.model, 1, 0), DC_STATUS_INVALIDARGS)
        assertReleased(data)
    }

    func testNullContextClosesTheStream() throws {
        let fake = FakeStream()
        let streamContext = try XCTUnwrap(Self.newContext())
        defer { dc_context_free(streamContext) }
        let iostream = try XCTUnwrap(Self.makeStream(fake, context: streamContext))
        let data = Self.newData()
        defer { data.deallocate() }

        XCTAssertEqual(open_device_on_iostream(data, iostream, Self.family, Self.model, 1, 0), DC_STATUS_INVALIDARGS)
        XCTAssertEqual(fake.closeCalls, 1)
        assertReleased(data)
    }

    func testNullDataClosesTheStream() throws {
        let fake = FakeStream()
        let streamContext = try XCTUnwrap(Self.newContext())
        defer { dc_context_free(streamContext) }
        let iostream = try XCTUnwrap(Self.makeStream(fake, context: streamContext))

        XCTAssertEqual(open_device_on_iostream(nil, iostream, Self.family, Self.model, 1, 0), DC_STATUS_INVALIDARGS)
        XCTAssertEqual(fake.closeCalls, 1)
    }

    /// Runs every reachable failure path once plus a successful open and close; returns how many misbehaved.
    private static func exerciseAllPaths() -> Int {
        var failures = 0
        func check(_ ok: Bool) { if !ok { failures += 1 } }

        func attempt(_ fake: FakeStream, model: UInt32, attempts: UInt32, withContext: Bool, withStream: Bool, expect: dc_status_t) {
            let data = newData()
            defer { data.deallocate() }
            let context = newContext()
            let iostream = withStream ? makeStream(fake, context: context) : nil
            data.pointee.context = withContext ? context : nil
            check(open_device_on_iostream(data, iostream, family, model, attempts, 0) == expect)
            if expect == DC_STATUS_SUCCESS {
                closeOpened(data)
            } else if !withContext, let context {
                dc_context_free(context)
            }
            check(data.pointee.context == nil && data.pointee.iostream == nil && data.pointee.model == nil)
            check(!withStream || fake.closeCalls == 1)
        }

        attempt(FakeStream(configureFailures: .max), model: model, attempts: 2, withContext: true, withStream: true, expect: DC_STATUS_IO)
        attempt(FakeStream(), model: 0xEE, attempts: 1, withContext: true, withStream: true, expect: DC_STATUS_UNSUPPORTED)
        attempt(FakeStream(), model: model, attempts: 0, withContext: true, withStream: true, expect: DC_STATUS_INVALIDARGS)
        attempt(FakeStream(), model: model, attempts: 1, withContext: true, withStream: false, expect: DC_STATUS_INVALIDARGS)
        attempt(FakeStream(), model: model, attempts: 1, withContext: false, withStream: true, expect: DC_STATUS_INVALIDARGS)
        attempt(FakeStream(), model: model, attempts: 1, withContext: true, withStream: true, expect: DC_STATUS_SUCCESS)
        return failures
    }

    private static func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func testNoPathLeaksTheContextStreamOrModelString() {
        XCTAssertEqual(Self.exerciseAllPaths(), 0)

        let iterations = 200
        let before = Self.bytesInUse()
        var failures = 0
        for _ in 0..<iterations { failures += Self.exerciseAllPaths() }
        let grown = Self.bytesInUse() - before

        XCTAssertEqual(failures, 0)
        // One leaked context per iteration is ~16 KB x 200 = 3.2 MB; a clean run stays near zero.
        XCTAssertLessThan(grown, 1 << 20, "heap grew \(grown) bytes over \(iterations) iterations")
    }

    // MARK: - Cancel

    func testSetCancelNeedsAnOpenDevice() {
        XCTAssertEqual(libdc_set_cancel(nil, nil, nil), DC_STATUS_INVALIDARGS)
        let data = Self.newData()
        defer { data.deallocate() }
        XCTAssertEqual(libdc_set_cancel(data, { _ in 1 }, nil), DC_STATUS_INVALIDARGS)
    }

    func testSetCancelStopsTheNextTransferAndClearingItResumes() throws {
        let fake = FakeStream()
        let opened = try open(fake, attempts: 1)
        XCTAssertEqual(opened.status, DC_STATUS_SUCCESS)
        let device = try XCTUnwrap(opened.data.pointee.device)
        let probe = CancelProbe()
        var buffer = [UInt8](repeating: 0, count: 1)

        let installed = libdc_set_cancel(opened.data, { userdata in
            Unmanaged<CancelProbe>.fromOpaque(userdata!).takeUnretainedValue().calls += 1
            return 1
        }, Unmanaged.passUnretained(probe).toOpaque())
        XCTAssertEqual(installed, DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_device_read(device, 0, &buffer, 1), DC_STATUS_CANCELLED)
        XCTAssertGreaterThan(probe.calls, 0, "the callback gets its userdata")
        XCTAssertEqual(fake.writeCalls, 0, "a cancelled transfer sends nothing")

        XCTAssertEqual(libdc_set_cancel(opened.data, nil, nil), DC_STATUS_SUCCESS)
        let callsBeforeClear = probe.calls
        XCTAssertNotEqual(dc_device_read(device, 0, &buffer, 1), DC_STATUS_CANCELLED)
        XCTAssertGreaterThan(fake.writeCalls, 0)
        XCTAssertEqual(probe.calls, callsBeforeClear)
    }

    // MARK: - Cable transports

    func testCableTransportsMatchThePlatform() {
        #if os(macOS)
        XCTAssertEqual(libdc_cable_transports(), DC_TRANSPORT_SERIAL.rawValue | DC_TRANSPORT_USBHID.rawValue)
        #else
        XCTAssertEqual(libdc_cable_transports(), 0)
        #endif
        XCTAssertEqual(libdc_cable_transports() & DC_TRANSPORT_BLE.rawValue, 0)
    }
}
