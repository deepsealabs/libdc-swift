#if os(macOS)
import XCTest
import IOKit
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// HIDStream against a fake IOHIDDevice: the lifecycle IOHIDDevice.h sets, and usbhid.c's hidapi semantics op for op.
final class HIDStreamTests: XCTestCase {

    private func started(_ device: FakeHIDDevice = FakeHIDDevice(), seize: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) -> HIDStream {
        let stream = HIDStream(device: device, seize: seize)
        XCTAssertEqual(stream.start(), kIOReturnSuccess, file: file, line: line)
        addTeardownBlock { _ = stream.close() }
        return stream
    }

    private func read(_ stream: HIDStream, size: Int = 64) -> (status: dc_status_t, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0xEE, count: size)
        var actual = 0
        let status = buffer.withUnsafeMutableBytes { stream.read(into: $0, actual: &actual) }
        return (status, Array(buffer.prefix(actual)))
    }

    private func write(_ stream: HIDStream, _ bytes: [UInt8]) -> (status: dc_status_t, actual: Int) {
        var actual = -1
        let status = bytes.withUnsafeBytes { stream.write($0, actual: &actual) }
        return (status, actual)
    }

    private static func report(_ first: UInt8, _ length: Int = 64) -> [UInt8] {
        [first] + (1..<length).map { UInt8(truncatingIfNeeded: $0) }
    }

    // MARK: - Lifecycle

    func testStartRegistersEverythingBeforeActivating() {
        let device = FakeHIDDevice(maxInputReportSize: 64)
        let stream = started(device)
        XCTAssertEqual(stream.state, .active)
        XCTAssertEqual(device.calls, [.open(seize: true), .registerInputReport(length: 64), .registerRemoval, .setDispatchQueue,
                                      .setCancelHandler, .activate])
        XCTAssertEqual(device.violations, [])
    }

    func testCloseCancelsThenTheHandlerClosesTheDevice() {
        let device = FakeHIDDevice()
        let stream = HIDStream(device: device)
        XCTAssertEqual(stream.start(), kIOReturnSuccess)
        XCTAssertEqual(stream.close(), DC_STATUS_SUCCESS)
        XCTAssertEqual(stream.state, .closed)
        XCTAssertEqual(Array(device.calls.suffix(3)), [.cancel, .cancelHandlerRan, .close(seize: true)])
        XCTAssertEqual(device.violations, [])
        XCTAssertEqual(stream.close(), DC_STATUS_SUCCESS, "a second close does nothing")
        XCTAssertEqual(device.calls.filter { $0 == .cancel }.count, 1)
    }

    func testANonSeizingStreamOpensAndClosesShared() {
        let device = FakeHIDDevice()
        let stream = HIDStream(device: device, seize: false)
        XCTAssertEqual(stream.start(), kIOReturnSuccess)
        _ = stream.close()
        XCTAssertEqual(device.calls.first, .open(seize: false))
        XCTAssertEqual(device.calls.last, .close(seize: false))
    }

    func testAFailedOpenCallsNothingElse() {
        for result in [kIOReturnExclusiveAccess, kIOReturnNotPermitted, kIOReturnNoDevice] {
            let device = FakeHIDDevice()
            device.openResult = result
            let stream = HIDStream(device: device)
            XCTAssertEqual(stream.start(), result)
            XCTAssertEqual(stream.state, .closed)
            XCTAssertEqual(device.calls, [.open(seize: true)], "no callbacks, queue or close after a failed open")
            XCTAssertEqual(read(stream).status, DC_STATUS_IO)
            XCTAssertEqual(write(stream, [0x00, 0x01]).status, DC_STATUS_IO)
            XCTAssertEqual(stream.close(), DC_STATUS_SUCCESS)
            XCTAssertEqual(device.calls, [.open(seize: true)])
        }
    }

    func testStartRunsOnce() {
        let device = FakeHIDDevice()
        let stream = started(device)
        XCTAssertNotEqual(stream.start(), kIOReturnSuccess)
        XCTAssertEqual(device.calls.filter { $0 == .open(seize: true) }.count, 1)
    }

    func testTheReportBufferLivesUntilTheCancelHandlerRuns() throws {
        let device = FakeHIDDevice()
        device.holdsCancelHandler = true
        var stream: HIDStream? = HIDStream(device: device, seize: true, cancelHandlerTimeout: .milliseconds(50))
        XCTAssertEqual(stream?.start(), kIOReturnSuccess)
        weak var inbox: HIDReportInbox?
        inbox = stream?.reportInbox
        XCTAssertEqual(stream?.close(), DC_STATUS_SUCCESS, "close gives up waiting, but frees nothing")
        stream = nil
        XCTAssertNotNil(inbox, "IOKit may still copy a report into the buffer until the cancel handler runs")
        device.deliver(Self.report(0x3f))
        device.settle()
        XCTAssertFalse(device.calls.contains(.close(seize: true)), "the device is closed by the handler, not before it")

        device.runCancelHandler()
        device.settle()
        XCTAssertNil(inbox, "the handler lets go of the buffer even though IOKit keeps the handler")
        XCTAssertEqual(Array(device.calls.suffix(2)), [.cancelHandlerRan, .close(seize: true)])
        XCTAssertEqual(device.violations, [])
    }

    func testDroppingAnOpenStreamCancelsIt() {
        let device = FakeHIDDevice()
        var stream: HIDStream? = HIDStream(device: device)
        XCTAssertEqual(stream?.start(), kIOReturnSuccess)
        stream = nil
        device.settle()
        XCTAssertEqual(Array(device.calls.suffix(3)), [.cancel, .cancelHandlerRan, .close(seize: true)])
    }

    // MARK: - Reads

    func testAReadIsOneReportWithItsReportIDByte() {
        let device = FakeHIDDevice()
        let stream = started(device)
        _ = stream.setTimeout(1000)
        let eonSteel = Self.report(0x3f)
        device.deliver(eonSteel, id: 0x3f)
        let first = read(stream)
        XCTAssertEqual(first.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(first.bytes, eonSteel, "suunto_eonsteel_receive_usb checks buf[0] == 0x3f")

        device.deliver(Self.report(0x01))
        device.deliver(Self.report(0x02))
        let one = read(stream, size: 256)
        XCTAssertEqual(one.bytes, Self.report(0x01), "a large buffer still gets one report, never two joined")
        XCTAssertEqual(read(stream, size: 256).bytes, Self.report(0x02))
    }

    func testAShortBufferTakesTheStartOfTheReportAndDropsTheRest() {
        let device = FakeHIDDevice()
        let stream = started(device)
        _ = stream.setTimeout(1000)
        device.deliver(Self.report(0x10))
        device.deliver(Self.report(0x20))
        XCTAssertEqual(read(stream, size: 10).bytes, Array(Self.report(0x10).prefix(10)))
        XCTAssertEqual(read(stream, size: 64).bytes, Self.report(0x20), "the cut-off rest of the first report is gone, as in hidapi")
    }

    func testATimeoutIsSuccessWithNothingRead() {
        let device = FakeHIDDevice()
        let stream = started(device)
        XCTAssertEqual(stream.setTimeout(120), DC_STATUS_SUCCESS)
        let start = DispatchTime.now()
        let result = read(stream)
        let elapsed = milliseconds(since: start)
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS, "usbhid.c's hidapi read returns SUCCESS with 0 bytes on a timeout")
        XCTAssertEqual(result.bytes, [])
        XCTAssertGreaterThanOrEqual(elapsed, 115)
        XCTAssertLessThan(elapsed, 1000)

        XCTAssertEqual(stream.setTimeout(0), DC_STATUS_SUCCESS)
        let poll = DispatchTime.now()
        XCTAssertEqual(read(stream).status, DC_STATUS_SUCCESS)
        XCTAssertLessThan(milliseconds(since: poll), 50, "a 0 timeout doesn't wait")
    }

    func testABlockingReadWaitsForTheReport() {
        let device = FakeHIDDevice()
        let stream = started(device)
        XCTAssertEqual(stream.setTimeout(-1), DC_STATUS_SUCCESS)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { device.deliver(Self.report(0x3f)) }
        let start = DispatchTime.now()
        let result = read(stream)
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(result.bytes.first, 0x3f)
        XCTAssertGreaterThanOrEqual(milliseconds(since: start), 140)
    }

    func testRemovalReadsAsIOOnceTheQueuedReportsAreRead() {
        let device = FakeHIDDevice()
        let stream = started(device)
        _ = stream.setTimeout(5000)
        device.deliver(Self.report(0x3f))
        device.remove()
        device.settle()
        XCTAssertTrue(stream.isRemoved)
        XCTAssertEqual(read(stream).bytes, Self.report(0x3f), "hidapi hands back what arrived before the unplug")
        let start = DispatchTime.now()
        XCTAssertEqual(read(stream).status, DC_STATUS_IO)
        XCTAssertLessThan(milliseconds(since: start), 100, "no wait for the timeout")
        XCTAssertEqual(write(stream, [0x3f, 1]).status, DC_STATUS_IO)
        XCTAssertFalse(device.calls.contains { if case .setReport = $0 { return true } else { return false } })

        _ = stream.close()
        XCTAssertFalse(device.calls.contains(.close(seize: true)), "an unplugged device is never closed, as in hidapi")
        XCTAssertTrue(device.calls.contains(.cancelHandlerRan))
    }

    func testRemovalWakesABlockedRead() {
        let device = FakeHIDDevice()
        let stream = started(device)
        _ = stream.setTimeout(-1)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { device.remove() }
        let start = DispatchTime.now()
        XCTAssertEqual(read(stream).status, DC_STATUS_IO)
        XCTAssertLessThan(milliseconds(since: start), 1000)
    }

    func testTheRemovalHandlerRunsOnceRemovedOrAtOnce() {
        let device = FakeHIDDevice()
        let stream = started(device)
        let calls = Flag()
        stream.setRemovalHandler { calls.value = true }
        XCTAssertFalse(calls.value)
        device.remove()
        device.settle()
        XCTAssertTrue(calls.value)
        let late = Flag()
        stream.setRemovalHandler { late.value = true }
        XCTAssertTrue(late.value, "set after the removal, it runs at once")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var marked: DispatchTime?
        func mark() { lock.lock(); marked = .now(); lock.unlock() }
        var millisecondsSince: Double? {
            lock.lock(); defer { lock.unlock() }
            return marked.map { milliseconds(since: $0) }
        }
    }

    func testCancelEndsABlockedRead() throws {
        let device = FakeHIDDevice()
        let stream = started(device)
        _ = stream.setTimeout(-1)
        let cancelled = Flag()
        let cancelledAt = Clock()
        stream.setCancellation { cancelled.value }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            cancelledAt.mark()
            cancelled.value = true
        }
        XCTAssertEqual(read(stream).status, DC_STATUS_CANCELLED)
        XCTAssertLessThan(try XCTUnwrap(cancelledAt.millisecondsSince), 100, "within a cancel check of the cancel")
        XCTAssertEqual(read(stream).status, DC_STATUS_CANCELLED)
        XCTAssertEqual(write(stream, [0x00, 0x01]).actual, 2, "writes still go out after a cancel, so a quit command does")
    }

    func testAtMostThirtyReportsWaitAndTheOldestGo() {
        let device = FakeHIDDevice()
        let stream = started(device)
        for index in 0..<35 { device.deliver(Self.report(UInt8(index))) }
        device.settle()
        XCTAssertEqual(stream.reportInbox.queuedCount, HIDStream.maxQueuedReports)
        XCTAssertEqual(stream.reportInbox.dropped, 5)
        _ = stream.setTimeout(0)
        XCTAssertEqual(read(stream).bytes.first, 5, "hidapi drops the oldest")
    }

    func testTheBufferIsTheDevicesLargestReportAndNeverUnder64() {
        let large = FakeHIDDevice(maxInputReportSize: 512)
        _ = started(large)
        XCTAssertEqual(large.calls[1], .registerInputReport(length: 512))
        let unknown = FakeHIDDevice(maxInputReportSize: nil)
        _ = started(unknown)
        XCTAssertEqual(unknown.calls[1], .registerInputReport(length: 64))
        let small = FakeHIDDevice(maxInputReportSize: 8)
        _ = started(small)
        XCTAssertEqual(small.calls[1], .registerInputReport(length: 64))
    }

    func testAReadAfterCloseIsIO() {
        let stream = started()
        _ = stream.close()
        XCTAssertEqual(read(stream).status, DC_STATUS_IO)
        XCTAssertEqual(write(stream, [0x3f]).status, DC_STATUS_IO)
    }

    // MARK: - Writes

    func testAZeroReportIDIsNotSentAndActualIsTheWholeSize() {
        let device = FakeHIDDevice()
        let stream = started(device)
        // uwatec_smart_usbhid_send: [0, size + 1, cmd, ...] padded to 33 bytes.
        let g2 = [0x00, 0x01, 0x1b] + [UInt8](repeating: 0, count: 30)
        let result = write(stream, g2)
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(result.actual, 33, "hidapi counts the report-ID byte")
        XCTAssertEqual(device.reportsSent.last?.id, 0)
        XCTAssertEqual(device.reportsSent.last?.bytes, Array(g2.dropFirst()))
    }

    func testANonZeroReportIDIsSentAsTheFirstByte() {
        let device = FakeHIDDevice()
        let stream = started(device)
        let eonSteel = Self.report(0x3f)
        let result = write(stream, eonSteel)
        XCTAssertEqual(result.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(result.actual, 64)
        XCTAssertEqual(device.reportsSent.last?.id, 0x3f)
        XCTAssertEqual(device.reportsSent.last?.bytes, eonSteel, "the report ID stays in the data, as hidapi's set_report sends it")
    }

    func testEdgeWrites() {
        let device = FakeHIDDevice()
        let stream = started(device)
        let empty = write(stream, [])
        XCTAssertEqual(empty.status, DC_STATUS_SUCCESS)
        XCTAssertEqual(empty.actual, 0)
        XCTAssertTrue(device.reportsSent.isEmpty, "usbhid.c sends nothing for an empty write")

        let lone = write(stream, [0x00])
        XCTAssertEqual(lone.actual, 1)
        XCTAssertEqual(device.reportsSent.last?.id, 0)
        XCTAssertEqual(device.reportsSent.last?.bytes, [])

        device.setReportResult = kIOReturnNotResponding
        let failed = write(stream, [0x3f, 0x01])
        XCTAssertEqual(failed.status, DC_STATUS_IO)
        XCTAssertEqual(failed.actual, 0)
    }

    // MARK: - The other operations, through libdivecomputer

    func testEveryOperationAnswersAsUSBHIDDoes() throws {
        let device = FakeHIDDevice()
        let stream = HIDStream(device: device)
        XCTAssertEqual(stream.start(), kIOReturnSuccess)
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        defer { dc_context_free(context) }
        let iostream = try DCCustomStream.open(backend: stream, transport: DC_TRANSPORT_USBHID, context: context)
        XCTAssertEqual(dc_iostream_get_transport(iostream), DC_TRANSPORT_USBHID)
        let start = DispatchTime.now()
        let results = StreamOps.runAll(iostream, timeout: 0, readSize: 64, sleep: 500)
        XCTAssertLessThan(milliseconds(since: start), 300, "usbhid.c has no sleep, so a 500 ms sleep returns at once")
        let expected: [DCIOStreamOperation: dc_status_t] = [
            .setTimeout: DC_STATUS_SUCCESS, .setBreak: DC_STATUS_SUCCESS, .setDTR: DC_STATUS_SUCCESS,
            .setRTS: DC_STATUS_SUCCESS, .getLines: DC_STATUS_SUCCESS, .getAvailable: DC_STATUS_SUCCESS,
            .configure: DC_STATUS_SUCCESS, .poll: DC_STATUS_UNSUPPORTED, .read: DC_STATUS_SUCCESS, .write: DC_STATUS_SUCCESS,
            .ioctl: DC_STATUS_UNSUPPORTED, .flush: DC_STATUS_SUCCESS, .purge: DC_STATUS_SUCCESS,
            .sleep: DC_STATUS_SUCCESS, .close: DC_STATUS_SUCCESS,
        ]
        XCTAssertEqual(results.statuses, expected)
        XCTAssertEqual(results.read, [], "a 0 ms read with nothing waiting")
        XCTAssertEqual(results.written, StreamOps.written.count)
        XCTAssertEqual(device.reportsSent.last?.id, Int(StreamOps.written[0]))
        XCTAssertEqual(stream.state, .closed, "dc_iostream_close closed the stream")
        XCTAssertEqual(device.calls.last, .close(seize: true))
    }

    func testPurgeKeepsQueuedReportsAsUSBHIDDoes() {
        let device = FakeHIDDevice()
        let stream = started(device)
        device.deliver(Self.report(0x01))
        device.settle()
        XCTAssertEqual(stream.purge(DC_DIRECTION_ALL), DC_STATUS_SUCCESS)
        _ = stream.setTimeout(0)
        XCTAssertEqual(read(stream).bytes, Self.report(0x01), "usbhid.c has no purge, so nothing is dropped")
    }
}
#endif
