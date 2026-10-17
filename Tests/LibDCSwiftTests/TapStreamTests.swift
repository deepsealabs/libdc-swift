#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `TapStream` over a probe, a pty serial port (`serial_posix.c`) and packet streams.
final class TapStreamTests: XCTestCase {

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

    /// The tap's own iostream, as a driver would hold it.
    private func outer(_ tap: TapStream, context: OpaquePointer? = nil) throws -> OpaquePointer {
        try DCCustomStream.open(backend: tap, transport: tap.transport, context: context ?? self.context)
    }

    private func probeStream(_ probe: ProbeBackend, _ transport: dc_transport_t = DC_TRANSPORT_SERIAL) throws -> OpaquePointer {
        try DCCustomStream.open(backend: probe, transport: transport, context: context)
    }

    // MARK: - Forwarding

    func testForwardsEveryOperationWithItsArgumentsAndRecordsIt() throws {
        let statuses: [DCIOStreamOperation: dc_status_t] = [
            .setTimeout: DC_STATUS_SUCCESS, .setBreak: DC_STATUS_IO, .setDTR: DC_STATUS_NOACCESS, .setRTS: DC_STATUS_NODEVICE,
            .getLines: DC_STATUS_PROTOCOL, .getAvailable: DC_STATUS_DATAFORMAT, .configure: DC_STATUS_UNSUPPORTED,
            .poll: DC_STATUS_TIMEOUT, .read: DC_STATUS_TIMEOUT, .write: DC_STATUS_IO, .ioctl: DC_STATUS_PROTOCOL,
            .flush: DC_STATUS_NOMEMORY, .purge: DC_STATUS_INVALIDARGS, .sleep: DC_STATUS_CANCELLED, .close: DC_STATUS_DONE,
        ]
        let probe = ProbeBackend(statuses: statuses)
        probe.readReply = [0xDE, 0xAD]
        probe.writeActual = 2
        probe.lines = 5
        probe.available = 7
        probe.ioctlReply = [9, 8, 7, 6]
        let recorder = DCStreamRecorder()
        let tap = TapStream(inner: try probeStream(probe, DC_TRANSPORT_USBHID), recorder: recorder)
        XCTAssertEqual(tap.transport, DC_TRANSPORT_USBHID)
        XCTAssertEqual(tap.channel, "usbhid")

        let results = StreamOps.runAll(try outer(tap), timeout: 0, sleep: 25)

        XCTAssertEqual(results.statuses, statuses)
        XCTAssertEqual(results.lines, 5)
        XCTAssertEqual(results.available, 7)
        XCTAssertEqual(results.read, [0xDE, 0xAD])
        XCTAssertEqual(results.written, 2)
        XCTAssertEqual(results.ioctlBuffer, [9, 8, 7, 6])
        XCTAssertEqual(probe.log.map(\.operation), DCIOStreamOperation.allCases, "one inner call per operation, in order")
        XCTAssertEqual(probe.log, [
            .setTimeout(0, status: DC_STATUS_SUCCESS),
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
        XCTAssertEqual(recorder.recording().exchanges, probe.log)
        XCTAssertEqual(recorder.recording().transport, DC_TRANSPORT_USBHID)
    }

    func testASerialPortAnswersTheSameWithAndWithoutTheTap() throws {
        let bare = try PtyPort()
        let stopBare = bare.drainInBackground()
        defer { stopBare() }
        let direct = StreamOps.runAll(bare.takeStream(), timeout: 0, sleep: 5)

        let tapped = try PtyPort()
        let stopTapped = tapped.drainInBackground()
        defer { stopTapped() }
        let tap = TapStream(inner: tapped.takeStream())
        let viaTap = StreamOps.runAll(try outer(tap, context: tapped.context), timeout: 0, sleep: 5)

        XCTAssertEqual(viaTap, direct)
        XCTAssertEqual(direct.statuses[.read], DC_STATUS_TIMEOUT)
        XCTAssertEqual(direct.statuses[.write], DC_STATUS_SUCCESS)
        XCTAssertEqual(direct.statuses[.close], DC_STATUS_SUCCESS)
    }

    func testCloseClosesTheInnerStreamOnceAndDeinitClosesAnOpenOne() throws {
        let closed = ProbeBackend()
        let tap = TapStream(inner: try probeStream(closed))
        XCTAssertEqual(tap.close(), DC_STATUS_SUCCESS)
        XCTAssertEqual(tap.close(), DC_STATUS_SUCCESS)
        XCTAssertEqual(tap.setDTR(1), DC_STATUS_IO, "a closed tap has no stream to talk to")
        XCTAssertEqual(closed.closeCount, 1)

        let abandoned = ProbeBackend()
        do { _ = TapStream(inner: try probeStream(abandoned)) }
        XCTAssertEqual(abandoned.closeCount, 1)
    }

    // MARK: - Timeouts and cancel on a serial port

    private struct Tapped {
        let port: PtyPort
        let tap: TapStream
        let stream: OpaquePointer
        let cancelled: Flag
    }

    private func tappedPort(recorder: DCStreamRecorder? = nil) throws -> Tapped {
        let port = try PtyPort()
        let cancelled = Flag()
        let tap = TapStream(inner: port.takeStream(), recorder: recorder, isCancelled: { cancelled.value })
        let stream = try outer(tap, context: port.context)
        addTeardownBlock { dc_iostream_close(stream) }
        return Tapped(port: port, tap: tap, stream: stream, cancelled: cancelled)
    }

    private final class ReadResult: @unchecked Sendable {
        var status = DC_STATUS_SUCCESS
        var bytes: [UInt8] = []
        var finished = DispatchTime.now()
    }

    private func readInBackground(_ stream: OpaquePointer, size: Int) -> (ReadResult, DispatchSemaphore) {
        let result = ReadResult()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: size)
            var actual = 0
            result.status = dc_iostream_read(stream, &buffer, size, &actual)
            result.bytes = Array(buffer.prefix(actual))
            result.finished = DispatchTime.now()
            done.signal()
        }
        return (result, done)
    }

    /// Hosted CI runners can overshoot a 50 ms wait by 100 ms or more, so there the wall clock only shows the wait ends; the slice tests below hold everywhere.
    private var cancelBound: Double { ProcessInfo.processInfo.environment["CI"] == "true" ? 500 : 100 }

    private func cancelLatency(_ t: Tapped, _ done: DispatchSemaphore, finished: () -> DispatchTime) -> Double {
        usleep(200_000)
        let cancelledAt = DispatchTime.now()
        t.cancelled.value = true
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "the blocked call never returned")
        return Double(finished().uptimeNanoseconds - cancelledAt.uptimeNanoseconds) / 1_000_000
    }

    func testCancelGivesUpABlockedReadWithin100Milliseconds() throws {
        let t = try tappedPort()
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, -1), DC_STATUS_SUCCESS)
        let (result, done) = readInBackground(t.stream, size: 4)
        let latency = cancelLatency(t, done) { result.finished }
        XCTAssertEqual(result.status, DC_STATUS_CANCELLED)
        XCTAssertEqual(result.bytes, [])
        XCTAssertLessThan(latency, cancelBound)
    }

    func testCancelKeepsThePartialCountOfADeadlineRead() throws {
        let t = try tappedPort()
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, 10_000), DC_STATUS_SUCCESS)
        t.port.send([0x01, 0x02])
        let (result, done) = readInBackground(t.stream, size: 4)
        let latency = cancelLatency(t, done) { result.finished }
        XCTAssertEqual(result.status, DC_STATUS_CANCELLED)
        XCTAssertEqual(result.bytes, [0x01, 0x02])
        XCTAssertLessThan(latency, cancelBound)
    }

    func testCancelGivesUpABlockedPollAndSleep() throws {
        let t = try tappedPort()
        final class Finished: @unchecked Sendable { var at = DispatchTime.now(); var status = DC_STATUS_SUCCESS }
        let stream = t.stream

        let poll = Finished(), pollDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            poll.status = dc_iostream_poll(stream, -1)
            poll.at = DispatchTime.now()
            pollDone.signal()
        }
        XCTAssertLessThan(cancelLatency(t, pollDone) { poll.at }, cancelBound)
        XCTAssertEqual(poll.status, DC_STATUS_CANCELLED)

        t.cancelled.value = false
        let sleep = Finished(), sleepDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sleep.status = dc_iostream_sleep(stream, 5_000)
            sleep.at = DispatchTime.now()
            sleepDone.signal()
        }
        XCTAssertLessThan(cancelLatency(t, sleepDone) { sleep.at }, cancelBound)
        XCTAssertEqual(sleep.status, DC_STATUS_CANCELLED)
    }

    /// Counts the inner waits; the cancel check turns true during the `cancelAfter`th one.
    private final class CountingWaits: ProbeBackendShim {
        let cancelled: Flag
        let cancelAfter: Int
        private(set) var polls: [Int32] = []
        private(set) var sleeps: [UInt32] = []

        init(cancelled: Flag, cancelAfter: Int) {
            self.cancelled = cancelled
            self.cancelAfter = cancelAfter
        }

        override func poll(_ timeout: Int32) -> dc_status_t {
            polls.append(timeout)
            if polls.count == cancelAfter { cancelled.value = true }
            return DC_STATUS_TIMEOUT
        }

        override func sleep(_ milliseconds: UInt32) -> dc_status_t {
            sleeps.append(milliseconds)
            if sleeps.count == cancelAfter { cancelled.value = true }
            return DC_STATUS_SUCCESS
        }
    }

    private func countingTap(cancelAfter: Int) throws -> (OpaquePointer, CountingWaits) {
        let cancelled = Flag()
        let waits = CountingWaits(cancelled: cancelled, cancelAfter: cancelAfter)
        let inner = try DCCustomStream.open(backend: waits, transport: DC_TRANSPORT_SERIAL, context: context)
        let stream = try outer(TapStream(inner: inner, isCancelled: { cancelled.value }))
        addTeardownBlock { dc_iostream_close(stream) }
        return (stream, waits)
    }

    func testEveryInnerWaitIsAtMost50MillisecondsAndTheCancelEndsTheNextOne() throws {
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        let slice = TapStream.cancelCheckMilliseconds
        XCTAssertEqual(slice, 50)

        let (read, readWaits) = try countingTap(cancelAfter: 3)
        XCTAssertEqual(dc_iostream_set_timeout(read, -1), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_read(read, &buffer, 4, &actual), DC_STATUS_CANCELLED)
        XCTAssertEqual(readWaits.polls, [slice, slice, slice], "the cancel is seen as the slice it landed in ends")

        let (deadline, deadlineWaits) = try countingTap(cancelAfter: 2)
        XCTAssertEqual(dc_iostream_set_timeout(deadline, 10_000), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_read(deadline, &buffer, 4, &actual), DC_STATUS_CANCELLED)
        XCTAssertEqual(deadlineWaits.polls, [slice, slice])

        let (short, shortWaits) = try countingTap(cancelAfter: .max)
        XCTAssertEqual(dc_iostream_set_timeout(short, 30), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_read(short, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(shortWaits.polls.first, 30, "min(slice, remaining)")
        XCTAssertTrue(shortWaits.polls.allSatisfy { $0 <= 30 })

        let (poll, pollWaits) = try countingTap(cancelAfter: 3)
        XCTAssertEqual(dc_iostream_poll(poll, -1), DC_STATUS_CANCELLED)
        XCTAssertEqual(pollWaits.polls, [slice, slice, slice])

        let (sleep, sleepWaits) = try countingTap(cancelAfter: 3)
        XCTAssertEqual(dc_iostream_sleep(sleep, 5_000), DC_STATUS_CANCELLED)
        XCTAssertEqual(sleepWaits.sleeps, [50, 50, 50])

        let (whole, wholeWaits) = try countingTap(cancelAfter: .max)
        XCTAssertEqual(dc_iostream_sleep(whole, 120), DC_STATUS_SUCCESS)
        XCTAssertEqual(wholeWaits.sleeps, [50, 50, 20], "the slices add up to the sleep")
    }

    func testOnceCancelledWaitsGiveUpAtOnceAndControlCallsStillGoThrough() throws {
        let probe = ProbeBackend()
        let cancelled = Flag()
        cancelled.value = true
        let stream = try outer(TapStream(inner: try probeStream(probe), isCancelled: { cancelled.value }))
        defer { dc_iostream_close(stream) }
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 9
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_CANCELLED)
        XCTAssertEqual(actual, 0)
        XCTAssertEqual(dc_iostream_poll(stream, 1000), DC_STATUS_CANCELLED)
        XCTAssertEqual(dc_iostream_sleep(stream, 1000), DC_STATUS_CANCELLED)
        XCTAssertEqual(probe.log, [], "nothing reached the device")
        // A driver's close path may still send its goodbye.
        XCTAssertEqual(dc_iostream_write(stream, [0x01] as [UInt8], 1, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_set_dtr(stream, 0), DC_STATUS_SUCCESS)
        XCTAssertEqual(probe.log.map(\.operation), [.write, .setDTR])
    }

    func testSetCancellationReplacesTheCheck() throws {
        let probe = ProbeBackend()
        let tap = TapStream(inner: try probeStream(probe))
        var buffer = [UInt8](repeating: 0, count: 1)
        var actual = 0
        tap.setCancellation { true }
        XCTAssertEqual(buffer.withUnsafeMutableBytes { tap.read(into: $0, actual: &actual) }, DC_STATUS_CANCELLED)
        tap.setCancellation(nil)
        XCTAssertEqual(tap.setTimeout(0), DC_STATUS_SUCCESS)
        XCTAssertEqual(buffer.withUnsafeMutableBytes { tap.read(into: $0, actual: &actual) }, DC_STATUS_SUCCESS)
    }

    func testReadsKeepTheSerialDriversTimeoutRules() throws {
        let t = try tappedPort()

        // N ms: a deadline, and the partial count on a timeout.
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, 200), DC_STATUS_SUCCESS)
        t.port.send([0x01, 0x02])
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        var start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        var elapsed = milliseconds(since: start)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x01, 0x02])
        XCTAssertGreaterThanOrEqual(elapsed, 195)
        // Wide upper bound: hosted runners schedule late.
        XCTAssertLessThan(elapsed, 500)

        // N ms: bytes that arrive in time complete the read.
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, 1000), DC_STATUS_SUCCESS)
        let port = t.port
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { port.send([0x05, 0x06, 0x07, 0x08]) }
        start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 4, &actual), DC_STATUS_SUCCESS)
        elapsed = milliseconds(since: start)
        XCTAssertEqual(buffer, [0x05, 0x06, 0x07, 0x08])
        XCTAssertGreaterThanOrEqual(elapsed, 90)
        XCTAssertLessThan(elapsed, 600)

        // 0: whatever is there, at once.
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, 0), DC_STATUS_SUCCESS)
        t.port.send([0x0A])
        usleep(20_000)
        start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(actual, 1)
        XCTAssertEqual(buffer[0], 0x0A)
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(actual, 0)
        XCTAssertLessThan(milliseconds(since: start), 50)

        // -1: blocks until every byte is in.
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, -1), DC_STATUS_SUCCESS)
        t.port.send([0x11, 0x12])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { port.send([0x13, 0x14]) }
        start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 4, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(buffer, [0x11, 0x12, 0x13, 0x14])
        XCTAssertGreaterThanOrEqual(milliseconds(since: start), 140)
    }

    func testAnUnsetTimeoutOnASerialPortBlocksLikeTheDriversDefault() throws {
        let t = try tappedPort()
        let port = t.port
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { port.send([0x21, 0x22]) }
        var buffer = [UInt8](repeating: 0, count: 2)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 2, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(buffer, [0x21, 0x22])
    }

    func testRecordingKeepsTheDriversCallsNotThePollSlices() throws {
        let recorder = DCStreamRecorder()
        let t = try tappedPort(recorder: recorder)
        XCTAssertEqual(dc_iostream_set_timeout(t.stream, 1000), DC_STATUS_SUCCESS)
        t.port.send([0x01, 0x02])
        let port = t.port
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { port.send([0x03, 0x04]) }
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(t.stream, &buffer, 4, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_sleep(t.stream, 120), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_poll(t.stream, 0), DC_STATUS_TIMEOUT)

        XCTAssertEqual(recorder.recording().exchanges, [
            .setTimeout(1000, status: DC_STATUS_SUCCESS),
            .read(size: 4, data: [0x01, 0x02, 0x03, 0x04], status: DC_STATUS_SUCCESS),
            .sleep(milliseconds: 120, status: DC_STATUS_SUCCESS),
            .poll(timeout: 0, status: DC_STATUS_TIMEOUT),
        ])
        XCTAssertEqual(recorder.recording().transport, DC_TRANSPORT_SERIAL)
    }

    // MARK: - Packet streams

    /// One report per read, like BLE and USB HID; `poll` is what the real stream's missing or unsupported poll answers.
    private final class PacketQueue: ProbeBackendShim {
        private let condition = NSCondition()
        private var packets: [[UInt8]] = []
        private var timeout: Int32 = -1
        private let pollStatus: dc_status_t

        init(poll: dc_status_t) { pollStatus = poll }

        func deliver(_ packet: [UInt8]) {
            condition.lock()
            packets.append(packet)
            condition.broadcast()
            condition.unlock()
        }

        override func setTimeout(_ timeout: Int32) -> dc_status_t {
            condition.lock(); self.timeout = timeout; condition.unlock()
            return DC_STATUS_SUCCESS
        }

        override func poll(_ timeout: Int32) -> dc_status_t { pollStatus }

        override func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(Double(max(timeout, 0)) / 1000)
            while packets.isEmpty {
                if timeout == 0 { return DC_STATUS_TIMEOUT }
                if timeout < 0 {
                    condition.wait()
                } else if !condition.wait(until: deadline) {
                    return DC_STATUS_TIMEOUT
                }
            }
            let packet = Array(packets.removeFirst().prefix(buffer.count))
            buffer.copyBytes(from: packet)
            actual = packet.count
            return DC_STATUS_SUCCESS
        }
    }

    private func checkOnePacketPerRead(poll: dc_status_t) throws {
        let queue = PacketQueue(poll: poll)
        let inner = try DCCustomStream.open(backend: queue, transport: DC_TRANSPORT_BLE, context: context)
        let stream = try outer(TapStream(inner: inner))
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 1000), DC_STATUS_SUCCESS)

        queue.deliver([0x01, 0x02, 0x03])
        queue.deliver([0x04, 0x05])
        var buffer = [UInt8](repeating: 0, count: 64)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 64, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x01, 0x02, 0x03])
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 64, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x04, 0x05])

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { queue.deliver([0x06]) }
        let start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 64, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x06])
        XCTAssertGreaterThanOrEqual(milliseconds(since: start), 90)

        XCTAssertEqual(dc_iostream_set_timeout(stream, 100), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 64, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(actual, 0)
    }

    func testAStreamWhosePollAlwaysSaysReadyKeepsOneReportPerRead() throws {
        // BLE's iostream has no poll, so dc_iostream_poll answers SUCCESS whether or not a packet is in.
        try checkOnePacketPerRead(poll: DC_STATUS_SUCCESS)
    }

    func testAStreamWithoutPollKeepsOneReportPerRead() throws {
        try checkOnePacketPerRead(poll: DC_STATUS_UNSUPPORTED)
    }

    // MARK: - Packet log

    func testPacketsAreLoggedOnTheStreamsChannel() throws {
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

        let probe = ProbeBackend()
        probe.readReply = [0x07, 0x08, 0x09]
        probe.writeActual = 2
        let stream = try outer(TapStream(inner: try probeStream(probe), channel: "serial-test"))
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 0), DC_STATUS_SUCCESS)
        var actual = 0
        XCTAssertEqual(dc_iostream_write(stream, [0x01, 0x02, 0x03] as [UInt8], 3, &actual), DC_STATUS_SUCCESS)
        var buffer = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 8, &actual), DC_STATUS_SUCCESS)

        XCTAssertEqual(events.map(\.direction), [.outbound, .inbound])
        XCTAssertEqual(events.map(\.channel), ["serial-test", "serial-test"])
        XCTAssertEqual(events.map(\.characteristicUUID), ["", ""])
        XCTAssertEqual(events.map { [UInt8]($0.data) }, [[0x01, 0x02], [0x07, 0x08, 0x09]], "only the bytes that crossed")

        logger.logPacket(direction: .inbound, data: Data([0xAA]), characteristicUUID: "2A19")
        XCTAssertEqual(events.last?.channel, PacketEvent.bleChannel)
        XCTAssertEqual(events.last?.characteristicUUID, "2A19")

        events.removeAll()
        logger.shouldShowRawData = false
        XCTAssertEqual(dc_iostream_write(stream, [0x01] as [UInt8], 1, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(events.count, 0, "packet logging stays opt-in")
    }
}
#endif
