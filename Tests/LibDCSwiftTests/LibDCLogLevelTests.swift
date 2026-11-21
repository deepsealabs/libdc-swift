import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `LibDCLogging.level` decides what each context passes to the host sink. At `.all` a tester's log gets a download's
/// every line, the iostream hexdumps and the driver's DEBUG dumps included: the full log libdivecomputer reviews need.
final class LibDCLogLevelTests: XCTestCase {

    private static let lock = NSLock()
    private static var received: [(level: String, message: String)] = []

    private static var lines: [(level: String, message: String)] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    private var keepAlive: [AnyObject] = []

    override func setUp() {
        super.setUp()
        set_libdc_log_sink { level, message in
            let line = (String(cString: level!), String(cString: message!))
            LibDCLogLevelTests.lock.lock()
            LibDCLogLevelTests.received.append(line)
            LibDCLogLevelTests.lock.unlock()
        }
    }

    override func tearDown() {
        set_libdc_log_sink(nil)
        LibDCLogging.level = .warning
        set_ble_debug_logging(0)
        Self.lock.lock()
        Self.received = []
        Self.lock.unlock()
        keepAlive.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.loglevel.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private static func fake(_ userdata: UnsafeMutableRawPointer?) -> SessionClockTests.FakeSensus {
        Unmanaged<SessionClockTests.FakeSensus>.fromOpaque(userdata!).takeUnretainedValue()
    }

    /// A Reefnet Sensus session on a serial fake: its handshake is a DEBUG hexdump, its memory comes in 128-byte reads.
    private func openSession() throws -> DiveComputerSession {
        let fake = SessionClockTests.FakeSensus(serial: 0x1234, devtime: 5_000_000,
                                                dives: [(100, SessionClockTests.dive(timestamp: 5_000_000 - 3_600))])
        keepAlive.append(fake)
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        var cbs = dc_custom_cbs_t()
        cbs.read = { userdata, data, size, actual in
            let n = LibDCLogLevelTests.fake(userdata).hostRead(into: data!, size: size)
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            LibDCLogLevelTests.fake(userdata).hostWrote(UnsafeRawBufferPointer(start: data, count: size))
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(fake).toOpaque()),
                       DC_STATUS_SUCCESS)
        let session = try DiveComputerSession.open(
            iostream: try XCTUnwrap(iostream), context: try XCTUnwrap(context),
            family: DC_FAMILY_REEFNET_SENSUS, model: 1,
            displayName: "Reefnet Sensus", storageKey: "serial:sensus",
            deviceStorage: DeviceStorage(userDefaults: isolatedSuite("dev")), lease: DiveComputerSessionLease())
        addTeardownBlock { session.close() }
        return session
    }

    private func download(_ session: DiveComputerSession) throws -> DiveDownloadResult {
        let viewModel = DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedSuite("fp")))
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        let downloaded = try XCTUnwrap(result)
        XCTAssertEqual(downloaded.outcome, .completed)
        return downloaded
    }

    private static func hexdumps(_ lines: ArraySlice<(level: String, message: String)>) -> Int {
        lines.filter { $0.message.contains("Read: size=") || $0.message.contains("Write: size=") }.count
    }

    // MARK: - Tests

    func testAtTheDefaultLevelTheSinkGetsNoHexdumpsAndNoDebugLines() throws {
        XCTAssertEqual(LibDCLogging.level, .warning)
        XCTAssertEqual(libdc_log_level(), DC_LOGLEVEL_WARNING)

        _ = try download(openSession())

        XCTAssertEqual(Self.hexdumps(Self.lines[...]), 0)
        XCTAssertFalse(Self.lines.contains { $0.level == "INFO" || $0.level == "DEBUG" }, "\(Self.lines)")
    }

    func testFullLoggingSendsTheWholeDownloadToTheSink() throws {
        LibDCLogging.level = .all
        XCTAssertEqual(libdc_log_level(), DC_LOGLEVEL_ALL)

        let session = try openSession()
        _ = try download(session)

        let lines = Self.lines
        let write = try XCTUnwrap(lines.first { $0.message.contains("Write: size=1, data=0A") }, "no handshake write: \(lines)")
        XCTAssertEqual(write.level, "INFO")
        XCTAssertTrue(write.message.hasPrefix("iostream.c:"), write.message)
        let handshake = try XCTUnwrap(lines.first { $0.message.contains("Handshake: size=") }, "no DEBUG dump: \(lines)")
        XCTAssertEqual(handshake.level, "DEBUG")
        XCTAssertTrue(handshake.message.hasPrefix("reefnet_sensus.c:"), handshake.message)
        // The 32 KB memory dump, 128 bytes a read.
        XCTAssertGreaterThanOrEqual(lines.filter { $0.message.contains("Read: size=128, data=") }.count, 256)

        // A line past the bridge's 1 KB stack buffer arrives whole.
        let payload = [UInt8](repeating: 0x55, count: 700)
        var written = 0
        XCTAssertEqual(dc_iostream_write(session.devicePtr.pointee.iostream, payload, payload.count, &written), DC_STATUS_SUCCESS)
        let long = try XCTUnwrap(Self.lines.last { $0.message.contains("Write: size=700, data=") })
        XCTAssertTrue(long.message.hasSuffix("data=" + String(repeating: "55", count: 700)), "cut short at \(long.message.utf8.count) bytes")
    }

    func testALevelChangeAppliesFromTheNextConnection() throws {
        let quiet = try openSession()
        LibDCLogging.level = .all
        _ = try download(quiet)
        XCTAssertEqual(Self.hexdumps(Self.lines[...]), 0, "a context set up at WARNING stays there")

        let loud = try openSession()
        LibDCLogging.level = .warning
        let before = Self.lines.count
        _ = try download(loud)
        let after = Self.lines[before...]
        XCTAssertGreaterThan(Self.hexdumps(after), 0, "a context set up at ALL stays there")
        XCTAssertTrue(after.contains { $0.level == "DEBUG" }, "and keeps sending its DEBUG lines")
    }

    func testTheDebugToggleKeepsDebugLinesOnTheConsole() throws {
        set_ble_debug_logging(1)

        _ = try download(openSession())

        XCTAssertGreaterThan(Self.hexdumps(Self.lines[...]), 0, "INFO hexdumps reach the sink, as before")
        XCTAssertFalse(Self.lines.contains { $0.level == "DEBUG" }, "DEBUG stays on the console")
    }

    func testAWrappedStreamsContextLogsWarningUnlessFullLoggingIsOn() {
        let expected: [(LibDCLogLevel, dc_loglevel_t)] = [
            (.error, DC_LOGLEVEL_WARNING), (.warning, DC_LOGLEVEL_WARNING), (.info, DC_LOGLEVEL_WARNING),
            (.debug, DC_LOGLEVEL_DEBUG), (.all, DC_LOGLEVEL_ALL),
        ]
        for (level, stream) in expected {
            LibDCLogging.level = level
            XCTAssertEqual(LibDCLogging.level, level)
            XCTAssertEqual(libdc_stream_log_level(), stream, "\(level)")
        }
    }

    func testConfigureGivesAHostContextTheLevel() throws {
        LibDCLogging.level = .all
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        let ctx = try XCTUnwrap(context)
        LibDCLogging.configure(ctx)
        var cbs = dc_custom_cbs_t()
        cbs.write = { _, _, size, actual in
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, ctx, DC_TRANSPORT_SERIAL, &cbs, nil), DC_STATUS_SUCCESS)
        defer {
            dc_iostream_close(iostream)
            dc_context_free(ctx)
        }

        var written = 0
        XCTAssertEqual(dc_iostream_write(iostream, [UInt8]([0xA5, 0x01]), 2, &written), DC_STATUS_SUCCESS)

        XCTAssertTrue(Self.lines.contains { $0.level == "INFO" && $0.message.hasSuffix("Write: size=2, data=A501") }, "\(Self.lines)")
    }

    func testTheLibdivecomputerVersionIsTheVendoredOne() {
        XCTAssertEqual(LibDCLogging.libdivecomputerVersion, DC_VERSION)
    }
}
