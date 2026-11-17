#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `libdc_btserial_open`, the paired classic-Bluetooth port's iostream, answering as libdivecomputer's RFCOMM transport does.
final class BluetoothSerialStreamTests: XCTestCase {
    private var context: OpaquePointer?

    override func setUp() {
        super.setUp()
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
    }

    override func tearDown() {
        if let context { dc_context_free(context) }
        context = nil
        super.tearDown()
    }

    private func open(_ path: String, writeLimit: UInt32 = UInt32(LIBDC_BTSERIAL_WRITE_LIMIT_MS)) throws -> OpaquePointer {
        var stream: OpaquePointer?
        XCTAssertEqual(libdc_btserial_open(&stream, context, path, writeLimit), DC_STATUS_SUCCESS)
        return try XCTUnwrap(stream)
    }

    /// A pseudo-terminal's slave opened as a paired port; the master is the computer's side.
    private func pty(writeLimit: UInt32 = UInt32(LIBDC_BTSERIAL_WRITE_LIMIT_MS)) throws -> (stream: OpaquePointer, master: Int32) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { Darwin.close(master) }
            throw XCTSkip("No pseudo-terminal available here (errno \(errno))")
        }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let stream = try open(String(cString: name), writeLimit: writeLimit)
        addTeardownBlock { Darwin.close(master) }
        return (stream, master)
    }

    func testLineCallsThePortRefusesAnswerSuccessAsRFCOMMDoes() throws {
        // /dev/null refuses TIOCEXCL, termios and modem lines, as a pseudo-serial might; serial_posix fails its open there.
        var serial: OpaquePointer?
        XCTAssertNotEqual(dc_serial_open(&serial, context, "/dev/null"), DC_STATUS_SUCCESS)
        let stream = try open("/dev/null")
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_get_transport(stream), DC_TRANSPORT_SERIAL, "Shearwater's non-BLE framing")
        XCTAssertEqual(dc_iostream_configure(stream, 115200, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_set_dtr(stream, 1), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_set_rts(stream, 0), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_set_break(stream, 1), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_flush(stream), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_purge(stream, DC_DIRECTION_ALL), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_set_timeout(stream, 3000), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_sleep(stream, 1), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_ioctl(stream, 0, nil, 0), DC_STATUS_UNSUPPORTED)
        var lines: UInt32 = 0
        XCTAssertNotEqual(dc_iostream_get_lines(stream, &lines), DC_STATUS_SUCCESS, "a line read is a real answer, not a stand-in")
    }

    func testAMissingPortFailsTheOpenWithItsErrno() {
        var stream: OpaquePointer?
        XCTAssertEqual(libdc_btserial_open(&stream, context, "/dev/cu.libdcswift-no-such-port", 100), DC_STATUS_NODEVICE)
        XCTAssertNil(stream)
        XCTAssertEqual(libdc_btserial_open(nil, context, "/dev/null", 100), DC_STATUS_INVALIDARGS)
    }

    func testAPtyTakesTheDriversLineSettings() throws {
        let (stream, _) = try pty()
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_configure(stream, 115200, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_purge(stream, DC_DIRECTION_ALL), DC_STATUS_SUCCESS)
    }

    func testReadsAreFullOrTimeoutWithThePartialCount() throws {
        let (stream, master) = try pty()
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_configure(stream, 115200, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_SUCCESS)
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0

        XCTAssertEqual(Darwin.write(master, [0x01, 0x02] as [UInt8], 2), 2)
        XCTAssertEqual(dc_iostream_set_timeout(stream, 150), DC_STATUS_SUCCESS)
        var start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x01, 0x02], "the partial count drivers append")
        XCTAssertGreaterThanOrEqual(milliseconds(since: start), 140, "one deadline for the whole read")

        // Bytes that arrive in pieces inside the deadline make a full read.
        let late = master
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { _ = Darwin.write(late, [0x03, 0x04] as [UInt8], 2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { _ = Darwin.write(late, [0x05, 0x06] as [UInt8], 2) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 2000), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(buffer, [0x03, 0x04, 0x05, 0x06])

        XCTAssertEqual(dc_iostream_set_timeout(stream, 0), DC_STATUS_SUCCESS)
        start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(actual, 0)
        XCTAssertLessThan(milliseconds(since: start), wallClockBound(50), "0 takes what is there and returns")

        XCTAssertEqual(Darwin.write(master, [0x07] as [UInt8], 1), 1)
        XCTAssertEqual(dc_iostream_poll(stream, 1000), DC_STATUS_SUCCESS)
        var available = 0
        XCTAssertEqual(dc_iostream_get_available(stream, &available), DC_STATUS_SUCCESS)
        XCTAssertEqual(available, 1)
    }

    func testAWriteTheLinkHasNoRoomForEndsAtItsLimitInsteadOfBlocking() throws {
        // A master that never reads stands in for a link that went: the slave's buffer fills and stays full.
        let (stream, _) = try pty(writeLimit: 200)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_configure(stream, 115200, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_SUCCESS)
        let payload = [UInt8](repeating: 0x5A, count: 1 << 20)
        var written = 0
        let start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_write(stream, payload, payload.count, &written), DC_STATUS_TIMEOUT)
        let elapsed = milliseconds(since: start)
        XCTAssertGreaterThan(written, 0, "what the link took is counted")
        XCTAssertLessThan(written, payload.count)
        XCTAssertGreaterThanOrEqual(elapsed, 190)
        XCTAssertLessThan(elapsed, wallClockBound(1500), "serial_posix's tcdrain would wait for ever")
    }

    func testASmallWriteGoesOutWhole() throws {
        let (stream, master) = try pty()
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_configure(stream, 115200, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_SUCCESS)
        var written = 0
        let request: [UInt8] = [0xFF, 0x01, 0x04, 0x00, 0x22, 0x80, 0x10, 0xC0]
        XCTAssertEqual(dc_iostream_write(stream, request, request.count, &written), DC_STATUS_SUCCESS)
        XCTAssertEqual(written, request.count)
        var echo = [UInt8](repeating: 0, count: 16)
        usleep(20_000)
        XCTAssertEqual(Darwin.read(master, &echo, echo.count), request.count)
        XCTAssertEqual(Array(echo.prefix(request.count)), request)
    }

    func testTheWriteGateTripsOnlyOnceCarrierRoseAndDropped() {
        let dcd = UInt32(DC_LINE_DCD.rawValue)
        XCTAssertFalse(libdc_btserial_carrier_lost(false, 0), "carrier never seen: which line tracks the link is unconfirmed")
        XCTAssertFalse(libdc_btserial_carrier_lost(true, dcd))
        XCTAssertTrue(libdc_btserial_carrier_lost(true, 0), "the link came up and went")
        XCTAssertTrue(libdc_btserial_carrier_lost(true, UInt32(DC_LINE_CTS.rawValue | DC_LINE_DSR.rawValue)))
    }

    func testACancelDuringTheLinkWaitClosesThePortBeforeTheDriverOpens() throws {
        let probe = ProbeBackend()
        let inner = try DCCustomStream.open(backend: probe, transport: DC_TRANSPORT_SERIAL, context: context)
        let cancellation = CableOpenCancellation()
        cancellation.cancel()
        let lease = DiveComputerSessionLease()
        let factory = SerialTapFactory(recorder: nil, cancellation: cancellation, lease: lease, classicBluetooth: true)
        let wrapped = SerialTapFactory.wrap(context, inner, Unmanaged.passUnretained(factory).toOpaque())
        XCTAssertNil(wrapped, "nothing goes into a link that may not be up, not even the driver's close")
        XCTAssertEqual(factory.linkWait, .cancelled)
        XCTAssertEqual(probe.closeCount, 1)
        XCTAssertEqual(probe.log.map(\.operation), [.close], "no read, write or line call reached the port")
        XCTAssertTrue(factory.leaseTaken, "openSerial releases it as it throws cancelled")
        lease.release()
    }

    func testAPairedPortsByteAtATimeReadsLogOneLinePerFrame() throws {
        final class Bytes: ProbeBackendShim {
            var queue: [UInt8] = []
            override func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
                guard !queue.isEmpty, buffer.count > 0 else { actual = 0; return DC_STATUS_TIMEOUT }
                buffer[0] = queue.removeFirst()
                actual = 1
                return DC_STATUS_SUCCESS
            }
            override func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
                actual = data.count
                return DC_STATUS_SUCCESS
            }
        }
        let logger = Logger.shared
        let wasShowing = logger.shouldShowRawData
        let previousSink = logger.onPacket
        defer {
            logger.shouldShowRawData = wasShowing
            logger.onPacket = previousSink
        }
        var events: [PacketEvent] = []
        logger.onPacket = { events.append($0) }
        logger.shouldShowRawData = true

        let backend = Bytes()
        // A SLIP frame (ending 0xC0), then the start of the next.
        backend.queue = [0x01, 0xFF, 0x02, 0xC0, 0x05, 0x06]
        let recorder = DCStreamRecorder()
        let tap = TapStream(inner: try DCCustomStream.open(backend: backend, transport: DC_TRANSPORT_SERIAL, context: context),
                            recorder: recorder, coalescesInboundLog: true)
        let stream = try DCCustomStream.open(backend: tap, transport: tap.transport, context: context)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 0), DC_STATUS_SUCCESS)
        var byte: UInt8 = 0
        var actual = 0
        for _ in 0..<6 { XCTAssertEqual(dc_iostream_read(stream, &byte, 1, &actual), DC_STATUS_SUCCESS) }
        XCTAssertEqual(events.map { [UInt8]($0.data) }, [[0x01, 0xFF, 0x02, 0xC0]], "one line for the frame")
        XCTAssertEqual(dc_iostream_write(stream, [0xAA] as [UInt8], 1, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(events.map { [UInt8]($0.data) }, [[0x01, 0xFF, 0x02, 0xC0], [0x05, 0x06], [0xAA]],
                       "what was pending goes out before the next request")
        let reads = recorder.recording().exchanges.filter { if case .read = $0 { return true } else { return false } }
        XCTAssertEqual(reads.count, 6, "a recording keeps every read, for replay")
    }
}
#endif
