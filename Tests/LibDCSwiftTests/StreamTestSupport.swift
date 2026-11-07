#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A backend that answers each operation with a chosen status and logs what it was asked.
final class ProbeBackend: DCIOStreamBackend {
    var statuses: [DCIOStreamOperation: dc_status_t] = [:]
    var readReply: [UInt8] = []
    var writeActual: Int?
    var lines: UInt32 = 0
    var available = 0
    var ioctlReply: [UInt8] = []
    private(set) var log: [DCRecording.Exchange] = []
    private(set) var closeCount = 0

    init(statuses: [DCIOStreamOperation: dc_status_t] = [:]) { self.statuses = statuses }

    private func status(_ op: DCIOStreamOperation) -> dc_status_t { statuses[op] ?? DC_STATUS_SUCCESS }

    func setTimeout(_ timeout: Int32) -> dc_status_t { log.append(.setTimeout(timeout, status: status(.setTimeout))); return status(.setTimeout) }
    func setBreak(_ value: UInt32) -> dc_status_t { log.append(.setBreak(value, status: status(.setBreak))); return status(.setBreak) }
    func setDTR(_ value: UInt32) -> dc_status_t { log.append(.setDTR(value, status: status(.setDTR))); return status(.setDTR) }
    func setRTS(_ value: UInt32) -> dc_status_t { log.append(.setRTS(value, status: status(.setRTS))); return status(.setRTS) }
    func getLines(_ value: inout UInt32) -> dc_status_t {
        value = lines
        log.append(.getLines(value: lines, status: status(.getLines)))
        return status(.getLines)
    }
    func getAvailable(_ value: inout Int) -> dc_status_t {
        value = available
        log.append(.getAvailable(value: available, status: status(.getAvailable)))
        return status(.getAvailable)
    }
    func configure(_ configuration: DCSerialConfiguration) -> dc_status_t {
        log.append(.configure(configuration, status: status(.configure)))
        return status(.configure)
    }
    func poll(_ timeout: Int32) -> dc_status_t { log.append(.poll(timeout: timeout, status: status(.poll))); return status(.poll) }
    func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
        let reply = Array(readReply.prefix(buffer.count))
        if !reply.isEmpty { buffer.copyBytes(from: reply) }
        actual = reply.count
        log.append(.read(size: buffer.count, data: reply, status: status(.read)))
        return status(.read)
    }
    func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
        actual = writeActual ?? data.count
        log.append(.write(data: Array(data), actual: actual, status: status(.write)))
        return status(.write)
    }
    func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t {
        let input = Array(data)
        let reply = Array(ioctlReply.prefix(data.count))
        if !reply.isEmpty { data.copyBytes(from: reply) }
        log.append(.ioctl(request: request, input: input, output: reply, status: status(.ioctl)))
        return status(.ioctl)
    }
    func flush() -> dc_status_t { log.append(.flush(status: status(.flush))); return status(.flush) }
    func purge(_ direction: dc_direction_t) -> dc_status_t { log.append(.purge(direction, status: status(.purge))); return status(.purge) }
    func sleep(_ milliseconds: UInt32) -> dc_status_t {
        log.append(.sleep(milliseconds: milliseconds, status: status(.sleep)))
        return status(.sleep)
    }
    func close() -> dc_status_t {
        closeCount += 1
        log.append(.close(status: status(.close)))
        return status(.close)
    }
}

/// A concrete backend to subclass when a test overrides one or two operations.
class ProbeBackendShim: DCIOStreamBackend {
    func setTimeout(_ timeout: Int32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setBreak(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setDTR(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setRTS(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func getLines(_ value: inout UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func getAvailable(_ value: inout Int) -> dc_status_t { DC_STATUS_SUCCESS }
    func configure(_ configuration: DCSerialConfiguration) -> dc_status_t { DC_STATUS_SUCCESS }
    func poll(_ timeout: Int32) -> dc_status_t { DC_STATUS_SUCCESS }
    func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t { DC_STATUS_SUCCESS }
    func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t { DC_STATUS_SUCCESS }
    func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t { DC_STATUS_SUCCESS }
    func flush() -> dc_status_t { DC_STATUS_SUCCESS }
    func purge(_ direction: dc_direction_t) -> dc_status_t { DC_STATUS_SUCCESS }
    func sleep(_ milliseconds: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func close() -> dc_status_t { DC_STATUS_SUCCESS }
}

/// What one call of each of the 15 operations returned.
struct OperationResults: Equatable {
    var statuses: [DCIOStreamOperation: dc_status_t] = [:]
    var lines: UInt32 = 0
    var available = 0
    var read: [UInt8] = []
    var written = 0
    var ioctlBuffer: [UInt8] = []
}

enum StreamOps {
    static let configuration = DCSerialConfiguration(baudrate: 9600, databits: 7, parity: DC_PARITY_EVEN,
                                                     stopbits: DC_STOPBITS_TWO)
    static let written: [UInt8] = [0x55, 0xAA, 0x01]
    /// DC_IOCTL_IORW('t', 1, 4), a made-up request so no stream knows it.
    static let ioctlRequest: UInt32 = (3 << 30) | (4 << 16) | (UInt32(UInt8(ascii: "t")) << 8) | 1
    static let ioctlInput: [UInt8] = [1, 2, 3, 4]

    /// Calls every operation once through libdivecomputer, in vtable order, and closes the stream last.
    static func runAll(_ stream: OpaquePointer, timeout: Int32 = 0, readSize: Int = 4, sleep: UInt32 = 1) -> OperationResults {
        var r = OperationResults()
        r.statuses[.setTimeout] = dc_iostream_set_timeout(stream, timeout)
        r.statuses[.setBreak] = dc_iostream_set_break(stream, 0)
        r.statuses[.setDTR] = dc_iostream_set_dtr(stream, 1)
        r.statuses[.setRTS] = dc_iostream_set_rts(stream, 0)
        var lines: UInt32 = 0xFFFF
        r.statuses[.getLines] = dc_iostream_get_lines(stream, &lines)
        r.lines = lines
        var available = 99
        r.statuses[.getAvailable] = dc_iostream_get_available(stream, &available)
        r.available = available
        r.statuses[.configure] = dc_iostream_configure(stream, configuration.baudrate, configuration.databits,
                                                       configuration.parity, configuration.stopbits, configuration.flowcontrol)
        r.statuses[.poll] = dc_iostream_poll(stream, 0)
        var buffer = [UInt8](repeating: 0, count: readSize)
        var actual = 0
        r.statuses[.read] = dc_iostream_read(stream, &buffer, buffer.count, &actual)
        r.read = Array(buffer.prefix(actual))
        var count = 0
        r.statuses[.write] = dc_iostream_write(stream, written, written.count, &count)
        r.written = count
        var ioctlBuffer = ioctlInput
        r.statuses[.ioctl] = dc_iostream_ioctl(stream, ioctlRequest, &ioctlBuffer, ioctlBuffer.count)
        r.ioctlBuffer = ioctlBuffer
        r.statuses[.flush] = dc_iostream_flush(stream)
        r.statuses[.purge] = dc_iostream_purge(stream, DC_DIRECTION_ALL)
        r.statuses[.sleep] = dc_iostream_sleep(stream, sleep)
        r.statuses[.close] = dc_iostream_close(stream)
        return r
    }
}

/// A pseudo-terminal opened as a libdivecomputer serial port; `master` is the far end.
final class PtyPort {
    let master: Int32
    let context: OpaquePointer
    private(set) var stream: OpaquePointer?

    init() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { Darwin.close(master) }
            throw XCTSkip("No pseudo-terminal available here (errno \(errno))")
        }
        let path = String(cString: name)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var context: OpaquePointer?
        guard dc_context_new(&context) == DC_STATUS_SUCCESS, let context else {
            Darwin.close(master)
            throw XCTSkip("dc_context_new failed")
        }
        var stream: OpaquePointer?
        let status = dc_serial_open(&stream, context, path)
        guard status == DC_STATUS_SUCCESS, let stream else {
            dc_context_free(context)
            Darwin.close(master)
            throw XCTSkip("dc_serial_open on a pty failed (\(status.rawValue))")
        }
        // Raw mode comes with configure; until then the pty is a line-buffered, echoing terminal.
        guard dc_iostream_configure(stream, 9600, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE) == DC_STATUS_SUCCESS else {
            dc_iostream_close(stream)
            dc_context_free(context)
            Darwin.close(master)
            throw XCTSkip("configure on a pty failed")
        }
        self.master = master
        self.context = context
        self.stream = stream
    }

    /// Hands the serial stream to a new owner (a `TapStream`), so `deinit` leaves it alone.
    func takeStream() -> OpaquePointer {
        defer { stream = nil }
        return stream!
    }

    func send(_ bytes: [UInt8]) {
        XCTAssertEqual(Darwin.write(master, bytes, bytes.count), bytes.count)
    }

    /// Reads what the port wrote, up to `count` bytes or 1 s.
    func received(_ count: Int) -> [UInt8] {
        var out = [UInt8]()
        let deadline = Date().addingTimeInterval(1)
        var chunk = [UInt8](repeating: 0, count: 256)
        while out.count < count, Date() < deadline {
            let n = Darwin.read(master, &chunk, min(chunk.count, count - out.count))
            if n > 0 { out += chunk.prefix(n) } else { usleep(1000) }
        }
        return out
    }

    /// Keeps reading the far end so `tcdrain` in the port's writes can finish.
    func drainInBackground() -> () -> Void {
        let stop = Flag()
        let master = master
        DispatchQueue.global().async {
            var chunk = [UInt8](repeating: 0, count: 256)
            while !stop.value {
                if Darwin.read(master, &chunk, chunk.count) <= 0 { usleep(1000) }
            }
        }
        return { stop.value = true }
    }

    deinit {
        if let stream { dc_iostream_close(stream) }
        dc_context_free(context)
        Darwin.close(master)
    }
}

/// A thread-safe flag for cancel checks.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}
#endif
