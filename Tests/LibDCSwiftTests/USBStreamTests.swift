#if os(macOS)
import XCTest
import IOKit
import IOKit.usb
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `USBStream` (USBBridge.m) against a fake interface: each operation as usb.c's libusb build answers it, the control ioctl's layout and bounds, and USB's bulk rules.
final class USBStreamTests: XCTestCase {
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

    private func open(_ device: FakeUSBDevice, cancel: (() -> Bool)? = nil) throws -> (stream: OpaquePointer, usb: USBStream) {
        let usb = USBStream(device: device, endpointIn: FakeUSBDevice.endpointIn, endpointOut: FakeUSBDevice.endpointOut)
        usb.cancelCheck = cancel
        var stream: OpaquePointer?
        XCTAssertEqual(usb.open(&stream, context: context), DC_STATUS_SUCCESS)
        return (try XCTUnwrap(stream), usb)
    }

    private func read(_ stream: OpaquePointer, _ size: Int) -> (status: dc_status_t, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: size)
        var actual = 0
        let status = dc_iostream_read(stream, &buffer, size, &actual)
        return (status, Array(buffer.prefix(actual)))
    }

    private func ioctl(_ stream: OpaquePointer, _ request: UInt32, _ buffer: inout [UInt8]) -> dc_status_t {
        let size = buffer.count
        return buffer.withUnsafeMutableBytes { dc_iostream_ioctl(stream, request, $0.baseAddress, size) }
    }

    private static func bytes(_ count: Int, seed: Int = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }
    }

    // MARK: - The 15 operations

    /// usb.c's dc_usb_vtable with a working device: NULL entries are SUCCESS in dc_iostream_*, poll is UNSUPPORTED, and ioctl knows only the control requests.
    private static let usbTable: [DCIOStreamOperation: dc_status_t] = [
        .setTimeout: DC_STATUS_SUCCESS, .setBreak: DC_STATUS_SUCCESS, .setDTR: DC_STATUS_SUCCESS,
        .setRTS: DC_STATUS_SUCCESS, .getLines: DC_STATUS_SUCCESS, .getAvailable: DC_STATUS_SUCCESS,
        .configure: DC_STATUS_SUCCESS, .poll: DC_STATUS_UNSUPPORTED, .read: DC_STATUS_SUCCESS, .write: DC_STATUS_SUCCESS,
        .ioctl: DC_STATUS_UNSUPPORTED, .flush: DC_STATUS_SUCCESS, .purge: DC_STATUS_SUCCESS,
        .sleep: DC_STATUS_SUCCESS, .close: DC_STATUS_SUCCESS,
    ]

    func testEveryOperationAnswersAsUSBCDoes() throws {
        let device = FakeUSBDevice()
        device.queue([0x01, 0x02])
        let (stream, usb) = try open(device)
        XCTAssertEqual(dc_iostream_get_transport(stream), DC_TRANSPORT_USB)
        let start = DispatchTime.now()
        let results = StreamOps.runAll(stream, timeout: 3000, readSize: 64, sleep: 500)

        XCTAssertEqual(results.statuses, Self.usbTable)
        XCTAssertEqual(results.lines, 0)
        XCTAssertEqual(results.available, 0)
        XCTAssertEqual(results.read, [0x01, 0x02])
        XCTAssertEqual(results.written, StreamOps.written.count)
        XCTAssertEqual(results.ioctlBuffer, StreamOps.ioctlInput, "an unknown request leaves the buffer alone")
        // usb.c has no sleep, so a 500 ms sleep returns at once there too.
        XCTAssertLessThan(milliseconds(since: start), 250)
        XCTAssertEqual(device.calls.filter { if case .control = $0 { return true } else { return false } }, [],
                       "configure, the lines, purge, flush and the unknown ioctl never reach the device")
        XCTAssertEqual(device.calls.last, .close)
        XCTAssertEqual(device.closeCount, 1)
        XCTAssertTrue(usb.isClosed)
    }

    func testAllFifteenCallbacksAreInstalled() throws {
        // Every one answers something only usb.c's table would, so a NULL callback (always SUCCESS) would show.
        let device = FakeUSBDevice()
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_poll(stream, 0), DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(dc_iostream_set_timeout(stream, 0), DC_STATUS_UNSUPPORTED)
        var request = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(ioctl(stream, StreamOps.ioctlRequest, &request), DC_STATUS_UNSUPPORTED)
        device.readFailures = [kIOReturnNotResponding]
        XCTAssertEqual(read(stream, 4).status, DC_STATUS_IO)
        device.writeResult = kIOReturnNotResponding
        var written = 0
        XCTAssertEqual(dc_iostream_write(stream, [1, 2], 2, &written), DC_STATUS_IO)
    }

    // MARK: - Timeouts

    func testTimeoutsFollowUSBC() throws {
        let device = FakeUSBDevice()
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        _ = read(stream, 1)
        XCTAssertEqual(device.reads.last?.timeout, 0, "usb.c starts with no timeout")
        XCTAssertEqual(dc_iostream_set_timeout(stream, 0), DC_STATUS_UNSUPPORTED, "libusb has no polling read")
        XCTAssertEqual(dc_iostream_set_timeout(stream, 2000), DC_STATUS_SUCCESS)
        _ = read(stream, 1)
        let timed = try XCTUnwrap(device.reads.last?.timeout)
        XCTAssertGreaterThan(timed, 1900)
        XCTAssertLessThanOrEqual(timed, 2000)
        XCTAssertEqual(dc_iostream_set_timeout(stream, -1), DC_STATUS_SUCCESS)
        _ = read(stream, 1)
        XCTAssertEqual(device.reads.last?.timeout, 0, "negative waits for ever")

        var setup = USBControl.command(0x01)
        XCTAssertEqual(dc_iostream_set_timeout(stream, 1500), DC_STATUS_SUCCESS)
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &setup), DC_STATUS_SUCCESS)
        guard case .control(_, _, let controlTimeout) = try XCTUnwrap(device.calls.last) else { return XCTFail("no control") }
        XCTAssertEqual(controlTimeout, 1500, "control transfers take the stream's timeout")
        var written = 0
        XCTAssertEqual(dc_iostream_write(stream, [9], 1, &written), DC_STATUS_SUCCESS)
        XCTAssertEqual(device.calls.last, .write([9], timeout: 0), "usb.c's writes have no timeout")
    }

    // MARK: - Control transfers

    func testTheControlSetupIsReadAsUSBCLaysItOut() throws {
        let device = FakeUSBDevice()
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        // bmRequestType, bRequest, wValue, wIndex, wLength: little-endian, at offsets 0, 1, 2, 4, 6.
        var buffer: [UInt8] = [0x41, 0x7E, 0x34, 0x12, 0x78, 0x56, 0x03, 0x00, 0xAA, 0xBB, 0xCC]
        XCTAssertEqual(MemoryLayout<dc_usb_control_t>.size, 8)
        XCTAssertEqual(MemoryLayout<dc_usb_control_t>.offset(of: \.wValue), 2)
        XCTAssertEqual(MemoryLayout<dc_usb_control_t>.offset(of: \.wIndex), 4)
        XCTAssertEqual(MemoryLayout<dc_usb_control_t>.offset(of: \.wLength), 6)
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &buffer), DC_STATUS_SUCCESS)
        XCTAssertEqual(device.calls.last, .control(FakeUSBDevice.Setup(bmRequestType: 0x41, bRequest: 0x7E, wValue: 0x1234,
                                                                       wIndex: 0x5678, wLength: 3),
                                                   data: [0xAA, 0xBB, 0xCC], timeout: 0))
    }

    func testAControlReadFillsTheDataStageAfterTheSetup() throws {
        let device = FakeUSBDevice()
        device.onControl = { setup, _ in (kIOReturnSuccess, [0xDE, 0xAD, 0xBE, 0xEF].suffix(Int(setup.wLength)), nil) }
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        var control = dc_usb_control_t(bmRequestType: 0xC0, bRequest: 0x05, wValue: 0, wIndex: 1, wLength: 4)
        var buffer = withUnsafeBytes(of: &control) { Array($0) } + [0, 0, 0, 0]
        XCTAssertEqual(ioctl(stream, USBControl.controlRead, &buffer), DC_STATUS_SUCCESS)
        XCTAssertEqual(Array(buffer.prefix(8)), withUnsafeBytes(of: &control) { Array($0) }, "the setup is left as it was")
        XCTAssertEqual(Array(buffer.suffix(4)), [0xDE, 0xAD, 0xBE, 0xEF])

        // A request with no data stage hands the device no buffer.
        var command = USBControl.command(0x09)
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &command), DC_STATUS_SUCCESS)
        XCTAssertEqual(device.calls.last, .control(FakeUSBDevice.Setup(bmRequestType: 0x40, bRequest: 0x09), data: [], timeout: 0))
    }

    func testWLengthBeyondTheBufferIsInvalidArgsAndNeverReachesTheDevice() throws {
        let device = FakeUSBDevice()
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        func setup(wLength: UInt16) -> [UInt8] { [0x40, 0x01, 0, 0, 0, 0, UInt8(wLength & 0xFF), UInt8(wLength >> 8)] }

        var short = [UInt8](repeating: 0, count: 7)
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &short), DC_STATUS_INVALIDARGS, "shorter than the setup")
        var empty: [UInt8] = []
        XCTAssertEqual(ioctl(stream, USBControl.controlRead, &empty), DC_STATUS_INVALIDARGS)
        var oneOver = setup(wLength: 5) + [1, 2, 3, 4]
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &oneOver), DC_STATUS_INVALIDARGS)
        var allOver = setup(wLength: 0xFFFF)
        XCTAssertEqual(ioctl(stream, USBControl.controlRead, &allOver), DC_STATUS_INVALIDARGS)
        XCTAssertEqual(device.calls, [], "nothing reached the device")

        var exact = setup(wLength: 4) + [1, 2, 3, 4]
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &exact), DC_STATUS_SUCCESS)
        var spare = setup(wLength: 2) + [7, 8, 9, 10]
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &spare), DC_STATUS_SUCCESS, "a longer buffer is fine")
        XCTAssertEqual(device.controls.map(\.wLength), [4, 2])
        XCTAssertEqual(device.calls.last, .control(FakeUSBDevice.Setup(bmRequestType: 0x40, bRequest: 0x01, wLength: 2),
                                                   data: [7, 8], timeout: 0))
    }

    func testControlFailuresMapAsLibusbAndUSBCDo() throws {
        let cases: [(IOReturn, dc_status_t)] = [
            (USBReturn.pipeStalled, DC_STATUS_IO), (kIOReturnNotResponding, DC_STATUS_IO),
            (USBReturn.transactionTimeout, DC_STATUS_TIMEOUT), (kIOReturnTimeout, DC_STATUS_TIMEOUT),
            (kIOReturnExclusiveAccess, DC_STATUS_NOACCESS), (kIOReturnBadArgument, DC_STATUS_INVALIDARGS),
            (kIOReturnNoMemory, DC_STATUS_NOMEMORY), (kIOReturnUnderrun, DC_STATUS_SUCCESS),
        ]
        for (result, expected) in cases {
            let device = FakeUSBDevice()
            device.onControl = { _, _ in (result, [], nil) }
            let (stream, _) = try open(device)
            var command = USBControl.command(0x01)
            XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &command), expected, String(format: "0x%08x", result))
            XCTAssertFalse(device.calls.contains { if case .clearStall = $0 { return true } else { return false } },
                           "the default pipe has no data toggle to put back")
            dc_iostream_close(stream)
        }
    }

    // MARK: - Bulk reads

    func testAReadAsksForOnePacketAtATimeUntilTheSizeIsMet() throws {
        let device = FakeUSBDevice()
        let payload = Self.bytes(200)
        let next = Self.bytes(30, seed: 9)
        device.queue(payload)
        device.queue(next)
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        let (status, bytes) = read(stream, 200)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(bytes, payload)
        XCTAssertEqual(device.reads.map(\.length), [64, 64, 64, 8])
        XCTAssertEqual(read(stream, 64).bytes, next, "the next transfer starts where that one ended")
    }

    func testAShortPacketEndsTheRead() throws {
        let device = FakeUSBDevice()
        let payload = Self.bytes(100)
        device.queue(payload)
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 2000), DC_STATUS_SUCCESS)
        let (status, bytes) = read(stream, 8192)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(bytes, payload)
        XCTAssertEqual(device.reads.map(\.length), [64, 64], "the second packet held 36 bytes")
    }

    func testATimeoutKeepsWhatArrivedBeforeIt() throws {
        let device = FakeUSBDevice()
        let payload = Self.bytes(128)
        device.queue(payload)
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 2000), DC_STATUS_SUCCESS)
        // Two full packets and nothing after: only the timeout ends the transfer.
        let (status, bytes) = read(stream, 8192)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertEqual(bytes, payload, "the partial count atomics_cobalt.c appends")
        XCTAssertEqual(device.calls.suffix(2), [.read(length: 64, timeout: device.reads.last!.timeout), .clearStall(endpoint: 0x82)])

        let silent = read(stream, 16)
        XCTAssertEqual(silent.status, DC_STATUS_TIMEOUT)
        XCTAssertEqual(silent.bytes, [])
    }

    func testAZeroLengthPacketEndsAFullRead() throws {
        let device = FakeUSBDevice()
        device.sendsZeroLengthPacket = true
        let payload = Self.bytes(128)
        device.queue(payload)
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        let (status, bytes) = read(stream, 8192)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(bytes, payload)
        XCTAssertFalse(device.calls.contains(.clearStall(endpoint: 0x82)))
    }

    func testTheTimeoutCoversTheWholeRead() throws {
        let device = FakeUSBDevice()
        device.waitsOnSilence = true
        device.queue(Self.bytes(64))
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 150), DC_STATUS_SUCCESS)
        let start = DispatchTime.now()
        let (status, bytes) = read(stream, 8192)
        let elapsed = milliseconds(since: start)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertEqual(bytes.count, 64)
        XCTAssertGreaterThanOrEqual(elapsed, 140)
        XCTAssertLessThan(elapsed, 600)
        let waits = device.reads.map(\.timeout)
        XCTAssertEqual(waits.count, 2)
        XCTAssertLessThanOrEqual(waits[1], waits[0], "the second packet gets what is left of the 150 ms")
        XCTAssertGreaterThan(waits[1], 0, "never 0, which would wait for ever")
    }

    func testAPacketBiggerThanTheRequestOverrunsIt() throws {
        let device = FakeUSBDevice()
        device.queue(Self.bytes(64))
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(read(stream, 16).status, DC_STATUS_IO, "kIOReturnOverrun, as libusb's LIBUSB_ERROR_OVERFLOW")
    }

    func testReadFailuresMapAsLibusbAndUSBCDo() throws {
        let cases: [(IOReturn, dc_status_t)] = [
            (USBReturn.pipeStalled, DC_STATUS_IO), (kIOReturnNotResponding, DC_STATUS_IO), (kIOReturnAborted, DC_STATUS_IO),
            (kIOReturnExclusiveAccess, DC_STATUS_NOACCESS), (kIOReturnNotPermitted, DC_STATUS_NOACCESS),
            (kIOReturnNoDevice, DC_STATUS_NODEVICE), (kIOReturnNotOpen, DC_STATUS_NODEVICE),
            (kIOReturnBadArgument, DC_STATUS_INVALIDARGS), (kIOReturnNoResources, DC_STATUS_NOMEMORY),
        ]
        for (result, expected) in cases {
            let device = FakeUSBDevice()
            device.readFailures = [result]
            let (stream, usb) = try open(device)
            XCTAssertEqual(read(stream, 16).status, expected, String(format: "0x%08x", result))
            XCTAssertFalse(usb.isRemoved, "the device is still there")
            dc_iostream_close(stream)
        }
    }

    func testAFailureWithTheDeviceGoneIsNoDeviceAndRunsTheRemovalHandlerOnce() throws {
        let device = FakeUSBDevice()
        let (stream, usb) = try open(device)
        defer { dc_iostream_close(stream) }
        let removals = Flag()
        var count = 0
        usb.removalHandler = { count += 1; removals.value = true }
        device.detach()
        XCTAssertEqual(read(stream, 16).status, DC_STATUS_NODEVICE)
        var command = USBControl.command(0x0A)
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &command), DC_STATUS_NODEVICE)
        XCTAssertTrue(usb.isRemoved)
        XCTAssertTrue(removals.value)
        XCTAssertEqual(count, 1)
    }

    func testAnUnplugDuringABlockedReadEndsIt() throws {
        let device = FakeUSBDevice()
        device.waitsOnSilence = true
        let (stream, usb) = try open(device)
        defer { dc_iostream_close(stream) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { device.detach() }
        let start = DispatchTime.now()
        XCTAssertEqual(read(stream, 16).status, DC_STATUS_NODEVICE)
        XCTAssertLessThan(milliseconds(since: start), 1000)
        XCTAssertTrue(usb.isRemoved)
    }

    // MARK: - Bulk writes

    func testAWriteIsOneTransferOnTheOutEndpoint() throws {
        let device = FakeUSBDevice()
        let (stream, _) = try open(device)
        defer { dc_iostream_close(stream) }
        let payload = Self.bytes(300)
        var written = 0
        XCTAssertEqual(dc_iostream_write(stream, payload, payload.count, &written), DC_STATUS_SUCCESS)
        XCTAssertEqual(written, 300)
        XCTAssertEqual(device.calls, [.write(payload, timeout: 0)])
        device.writeResult = USBReturn.pipeStalled
        XCTAssertEqual(dc_iostream_write(stream, payload, payload.count, &written), DC_STATUS_IO)
        XCTAssertEqual(written, 0, "IOUSBLib reports nothing for a failed write")
    }

    // MARK: - Cancel

    func testACancelledStreamTouchesNothing() throws {
        let device = FakeUSBDevice()
        device.queue([1, 2, 3])
        let (stream, _) = try open(device, cancel: { true })
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(read(stream, 3).status, DC_STATUS_CANCELLED)
        var written = 0
        XCTAssertEqual(dc_iostream_write(stream, [1], 1, &written), DC_STATUS_CANCELLED)
        var command = USBControl.command(0x09)
        XCTAssertEqual(ioctl(stream, USBControl.controlWrite, &command), DC_STATUS_CANCELLED)
        XCTAssertEqual(device.calls, [])
    }

    func testACancelAbortsABlockedReadWithinACheck() throws {
        let device = FakeUSBDevice()
        device.waitsOnSilence = true
        let cancelled = Flag()
        let (stream, _) = try open(device, cancel: { cancelled.value })
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 5000), DC_STATUS_SUCCESS)
        let flagged = Instant()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            flagged.mark()
            cancelled.value = true
        }
        XCTAssertEqual(read(stream, 8192).status, DC_STATUS_CANCELLED)
        XCTAssertLessThan(milliseconds(since: flagged.value), 150, "within one 50 ms check, well inside the 5 s timeout")
        XCTAssertEqual(device.aborts, 1)
        XCTAssertFalse(device.calls.contains(.clearStall(endpoint: 0x82)))
    }

    func testABlockedReadThatTimesOutIsNeverAborted() throws {
        let device = FakeUSBDevice()
        device.waitsOnSilence = true
        let (stream, _) = try open(device, cancel: { false })
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 200), DC_STATUS_SUCCESS)
        XCTAssertEqual(read(stream, 64).status, DC_STATUS_TIMEOUT)
        XCTAssertEqual(device.aborts, 0)
        XCTAssertEqual(USBStream.cancelCheckMilliseconds, 50)
    }

    // MARK: - Lifetime

    func testTheStreamLivesUntilCloseAndClosesTheDeviceOnce() throws {
        let device = FakeUSBDevice()
        weak var weakStream: USBStream?
        let stream: OpaquePointer = try {
            let opened = try open(device)
            weakStream = opened.usb
            return opened.stream
        }()
        XCTAssertNotNil(weakStream, "the iostream holds it")
        XCTAssertEqual(device.closeCount, 0)
        XCTAssertEqual(dc_iostream_close(stream), DC_STATUS_SUCCESS)
        XCTAssertNil(weakStream)
        XCTAssertEqual(device.closeCount, 1)
    }

    func testASecondOpenIsRefused() throws {
        let device = FakeUSBDevice()
        let (stream, usb) = try open(device)
        defer { dc_iostream_close(stream) }
        var again: OpaquePointer?
        XCTAssertEqual(usb.open(&again, context: context), DC_STATUS_INVALIDARGS)
        XCTAssertNil(again)
        XCTAssertEqual(device.closeCount, 0, "the first iostream still has it")
    }
}
#endif
