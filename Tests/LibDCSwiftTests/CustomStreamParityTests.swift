#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `DCCustomStream` against `custom.c`, which answers SUCCESS for any NULL callback, and the USB HID / USB backends against upstream's vtables.
final class CustomStreamParityTests: XCTestCase {

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

    private func open(_ backend: DCIOStreamBackend, _ transport: dc_transport_t = DC_TRANSPORT_SERIAL) throws -> OpaquePointer {
        try DCCustomStream.open(backend: backend, transport: transport, context: context)
    }

    func testAllFifteenCallbacksAreInstalled() {
        let slots = Mirror(reflecting: DCCustomStream.callbacks).children
        XCTAssertEqual(slots.count, DCIOStreamOperation.allCases.count)
        XCTAssertEqual(slots.count, 15)
        for slot in slots {
            let value = Mirror(reflecting: slot.value)
            XCTAssertFalse(value.displayStyle == .optional && value.children.isEmpty, "\(slot.label ?? "?") is NULL")
        }
        XCTAssertEqual(Set(slots.compactMap(\.label)), Set(DCIOStreamOperation.allCases.map(\.rawValue)))
    }

    func testEveryOperationReachesTheBackendWithItsArguments() throws {
        // All non-SUCCESS: a NULL callback would come back SUCCESS instead.
        let statuses: [DCIOStreamOperation: dc_status_t] = [
            .setTimeout: DC_STATUS_TIMEOUT, .setBreak: DC_STATUS_IO, .setDTR: DC_STATUS_NOACCESS, .setRTS: DC_STATUS_NODEVICE,
            .getLines: DC_STATUS_PROTOCOL, .getAvailable: DC_STATUS_DATAFORMAT, .configure: DC_STATUS_UNSUPPORTED,
            .poll: DC_STATUS_TIMEOUT, .read: DC_STATUS_TIMEOUT, .write: DC_STATUS_IO, .ioctl: DC_STATUS_PROTOCOL,
            .flush: DC_STATUS_NOMEMORY, .purge: DC_STATUS_INVALIDARGS, .sleep: DC_STATUS_CANCELLED, .close: DC_STATUS_DONE,
        ]
        let probe = ProbeBackend(statuses: statuses)
        probe.readReply = [0xDE, 0xAD]
        probe.writeActual = 2
        probe.lines = 0x5
        probe.available = 7
        probe.ioctlReply = [9, 8, 7, 6]
        let stream = try open(probe)
        XCTAssertEqual(dc_iostream_get_transport(stream), DC_TRANSPORT_SERIAL)

        let results = StreamOps.runAll(stream, timeout: 1234, sleep: 25)

        XCTAssertEqual(results.statuses, statuses)
        XCTAssertEqual(results.lines, 5)
        XCTAssertEqual(results.available, 7)
        XCTAssertEqual(results.read, [0xDE, 0xAD])
        XCTAssertEqual(results.written, 2)
        XCTAssertEqual(results.ioctlBuffer, [9, 8, 7, 6])
        XCTAssertEqual(probe.log, [
            .setTimeout(1234, status: DC_STATUS_TIMEOUT),
            .setBreak(0, status: DC_STATUS_IO),
            .setDTR(1, status: DC_STATUS_NOACCESS),
            .setRTS(0, status: DC_STATUS_NODEVICE),
            .getLines(value: 5, status: DC_STATUS_PROTOCOL),
            .getAvailable(value: 7, status: DC_STATUS_DATAFORMAT),
            .configure(StreamOps.configuration, status: DC_STATUS_UNSUPPORTED),
            .poll(timeout: 0, status: DC_STATUS_TIMEOUT),
            .read(size: 4, data: [0xDE, 0xAD], status: DC_STATUS_TIMEOUT),
            .write(data: StreamOps.written, actual: 2, status: DC_STATUS_IO),
            .ioctl(request: StreamOps.ioctlRequest, input: StreamOps.ioctlInput, output: [9, 8, 7, 6], status: DC_STATUS_PROTOCOL),
            .flush(status: DC_STATUS_NOMEMORY),
            .purge(DC_DIRECTION_ALL, status: DC_STATUS_INVALIDARGS),
            .sleep(milliseconds: 25, status: DC_STATUS_CANCELLED),
            .close(status: DC_STATUS_DONE),
        ])
        XCTAssertEqual(probe.log.map(\.operation), DCIOStreamOperation.allCases)
    }

    func testTheBackendLivesUntilCloseAndIsClosedOnce() throws {
        weak var weakProbe: ProbeBackend?
        let stream: OpaquePointer
        do {
            let probe = ProbeBackend()
            weakProbe = probe
            stream = try open(probe)
        }
        XCTAssertNotNil(weakProbe, "the stream holds its backend")
        XCTAssertEqual(dc_iostream_set_dtr(stream, 1), DC_STATUS_SUCCESS)
        XCTAssertEqual(weakProbe?.closeCount, 0)
        let probe = weakProbe
        XCTAssertEqual(dc_iostream_close(stream), DC_STATUS_SUCCESS)
        XCTAssertEqual(probe?.closeCount, 1)
    }

    func testTheBackendIsReleasedAfterClose() throws {
        weak var weakProbe: ProbeBackend?
        let stream: OpaquePointer = try {
            let probe = ProbeBackend()
            weakProbe = probe
            return try open(probe)
        }()
        XCTAssertNotNil(weakProbe)
        dc_iostream_close(stream)
        XCTAssertNil(weakProbe)
    }

    func testCountsAreClampedToTheBuffer() throws {
        final class Overcounting: ProbeBackendShim {
            override func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
                actual = buffer.count + 5
                return DC_STATUS_SUCCESS
            }
            override func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
                actual = -3
                return DC_STATUS_SUCCESS
            }
        }
        let stream = try open(Overcounting())
        defer { dc_iostream_close(stream) }
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(stream, &buffer, buffer.count, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(actual, 4)
        XCTAssertEqual(dc_iostream_write(stream, buffer, buffer.count, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(actual, 0)
    }

    // MARK: - Upstream vtables

    /// usbhid.c's dc_usbhid_vtable (hidapi build) with a working device: NULL entries are SUCCESS in dc_iostream_*, poll and ioctl return UNSUPPORTED.
    private static let usbHIDTable: [DCIOStreamOperation: dc_status_t] = [
        .setTimeout: DC_STATUS_SUCCESS, .setBreak: DC_STATUS_SUCCESS, .setDTR: DC_STATUS_SUCCESS,
        .setRTS: DC_STATUS_SUCCESS, .getLines: DC_STATUS_SUCCESS, .getAvailable: DC_STATUS_SUCCESS,
        .configure: DC_STATUS_SUCCESS, .poll: DC_STATUS_UNSUPPORTED, .read: DC_STATUS_SUCCESS, .write: DC_STATUS_SUCCESS,
        .ioctl: DC_STATUS_UNSUPPORTED, .flush: DC_STATUS_SUCCESS, .purge: DC_STATUS_SUCCESS,
        .sleep: DC_STATUS_SUCCESS, .close: DC_STATUS_SUCCESS,
    ]

    /// usb.c's dc_usb_vtable: as usbhid.c, but its ioctl handles control transfers.
    private static var usbTable: [DCIOStreamOperation: dc_status_t] {
        var table = usbHIDTable
        table[.ioctl] = DC_STATUS_SUCCESS
        return table
    }

    private final class HIDReports: DCUSBHIDStreamBackend {
        var timeouts: [Int32] = []
        var writes: [[UInt8]] = []
        var closes = 0
        func setTimeout(_ timeout: Int32) -> dc_status_t { timeouts.append(timeout); return DC_STATUS_SUCCESS }
        func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
            buffer.copyBytes(from: [0x3F, 0x01])
            actual = 2
            return DC_STATUS_SUCCESS
        }
        func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
            writes.append(Array(data))
            actual = data.count
            return DC_STATUS_SUCCESS
        }
        func close() -> dc_status_t { closes += 1; return DC_STATUS_SUCCESS }
    }

    private final class USBBulk: DCUSBStreamBackend {
        var requests: [UInt32] = []
        func setTimeout(_ timeout: Int32) -> dc_status_t { timeout == 0 ? DC_STATUS_UNSUPPORTED : DC_STATUS_SUCCESS }
        func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
            buffer.copyBytes(from: [0x01, 0x02])
            actual = 2
            return DC_STATUS_SUCCESS
        }
        func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
            actual = data.count
            return DC_STATUS_SUCCESS
        }
        func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t {
            requests.append(request)
            return DC_STATUS_SUCCESS
        }
        func close() -> dc_status_t { DC_STATUS_SUCCESS }
    }

    func testUSBHIDBackendMatchesUpstreamUSBHID() throws {
        let backend = HIDReports()
        let stream = try open(backend, DC_TRANSPORT_USBHID)
        XCTAssertEqual(dc_iostream_get_transport(stream), DC_TRANSPORT_USBHID)
        let start = DispatchTime.now()
        let results = StreamOps.runAll(stream, timeout: 3000, readSize: 64, sleep: 500)

        XCTAssertEqual(results.statuses, Self.usbHIDTable)
        XCTAssertEqual(results.lines, 0)
        XCTAssertEqual(results.available, 0)
        XCTAssertEqual(results.read, [0x3F, 0x01])
        XCTAssertEqual(results.written, StreamOps.written.count)
        XCTAssertEqual(results.ioctlBuffer, StreamOps.ioctlInput, "an unsupported ioctl leaves the buffer alone")
        // usbhid.c has no sleep, so a 500 ms sleep returns at once there too.
        XCTAssertLessThan(milliseconds(since: start), 250)
        XCTAssertEqual(backend.timeouts, [3000])
        XCTAssertEqual(backend.writes, [StreamOps.written])
        XCTAssertEqual(backend.closes, 1)
    }

    func testUSBBackendMatchesUpstreamUSB() throws {
        let backend = USBBulk()
        let stream = try open(backend, DC_TRANSPORT_USB)
        let results = StreamOps.runAll(stream, timeout: 3000)
        XCTAssertEqual(results.statuses, Self.usbTable)
        XCTAssertEqual(results.lines, 0)
        XCTAssertEqual(results.available, 0)
        XCTAssertEqual(backend.requests, [StreamOps.ioctlRequest])

        // usb.c refuses a 0 ms timeout; a backend that does the same keeps that answer.
        let again = try open(USBBulk(), DC_TRANSPORT_USB)
        defer { dc_iostream_close(again) }
        XCTAssertEqual(dc_iostream_set_timeout(again, 0), DC_STATUS_UNSUPPORTED)
    }
}

#endif
