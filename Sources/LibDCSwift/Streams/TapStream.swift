#if os(macOS)
import Foundation
import Clibdivecomputer

/// A pass-through over an opened iostream (a `dc_serial_open` port, say) that logs packets on `channel`, can record a `.dcrec`, and ends a blocked read, poll or sleep with `DC_STATUS_CANCELLED`; writes can't be interrupted (serial_posix blocks in select and tcdrain).
public final class TapStream: DCIOStreamBackend {
    /// The longest a blocked read, poll or sleep waits between cancel checks; half of 100 ms so a cancel lands within 100 ms.
    public static let cancelCheckMilliseconds: Int32 = 50

    /// The inner stream's transport, to open the tap's own stream with.
    public let transport: dc_transport_t
    /// `PacketEvent.channel` for this stream's packets.
    public let channel: String
    public let recorder: DCStreamRecorder?

    private var inner: OpaquePointer?
    private let cancelLock = NSLock()
    private var cancelCheck: (() -> Bool)?
    private var timeout: Int32?
    private var innerTimeout: Int32?
    private var slicedReads = true

    /// Takes ownership of `inner`: `close()` closes it, and so does deinit if `close()` never ran.
    public init(inner: OpaquePointer, channel: String? = nil, recorder: DCStreamRecorder? = nil,
                isCancelled: (() -> Bool)? = nil) {
        self.inner = inner
        transport = dc_iostream_get_transport(inner)
        self.channel = channel ?? DCRecording.name(of: transport)
        self.recorder = recorder
        cancelCheck = isCancelled
        // serial_posix starts at -1; for other streams the starting timeout is unknown, so reads go straight through until one is set.
        if transport == DC_TRANSPORT_SERIAL {
            timeout = -1
            innerTimeout = -1
        }
        recorder?.begin(transport: transport)
    }

    deinit {
        if let inner { dc_iostream_close(inner) }
    }

    /// While `isCancelled` returns true, reads, polls and sleeps give up with `DC_STATUS_CANCELLED`; nil clears it.
    public func setCancellation(_ isCancelled: (() -> Bool)?) {
        cancelLock.lock(); defer { cancelLock.unlock() }
        cancelCheck = isCancelled
    }

    private var cancelled: Bool {
        cancelLock.lock()
        let check = cancelCheck
        cancelLock.unlock()
        return check?() ?? false
    }

    // MARK: - DCIOStreamBackend

    public func setTimeout(_ timeout: Int32) -> dc_status_t {
        let status = inner.map { dc_iostream_set_timeout($0, timeout) } ?? DC_STATUS_IO
        if status == DC_STATUS_SUCCESS {
            self.timeout = timeout
            innerTimeout = timeout
        }
        recorder?.append(.setTimeout(timeout, status: status))
        return status
    }

    public func setBreak(_ value: UInt32) -> dc_status_t {
        let status = inner.map { dc_iostream_set_break($0, value) } ?? DC_STATUS_IO
        recorder?.append(.setBreak(value, status: status))
        return status
    }

    public func setDTR(_ value: UInt32) -> dc_status_t {
        let status = inner.map { dc_iostream_set_dtr($0, value) } ?? DC_STATUS_IO
        recorder?.append(.setDTR(value, status: status))
        return status
    }

    public func setRTS(_ value: UInt32) -> dc_status_t {
        let status = inner.map { dc_iostream_set_rts($0, value) } ?? DC_STATUS_IO
        recorder?.append(.setRTS(value, status: status))
        return status
    }

    public func getLines(_ value: inout UInt32) -> dc_status_t {
        var lines: UInt32 = 0
        let status = inner.map { dc_iostream_get_lines($0, &lines) } ?? DC_STATUS_IO
        value = lines
        recorder?.append(.getLines(value: lines, status: status))
        return status
    }

    public func getAvailable(_ value: inout Int) -> dc_status_t {
        var available = 0
        let status = inner.map { dc_iostream_get_available($0, &available) } ?? DC_STATUS_IO
        value = available
        recorder?.append(.getAvailable(value: available, status: status))
        return status
    }

    public func configure(_ configuration: DCSerialConfiguration) -> dc_status_t {
        let status = inner.map {
            dc_iostream_configure($0, configuration.baudrate, configuration.databits, configuration.parity,
                                  configuration.stopbits, configuration.flowcontrol)
        } ?? DC_STATUS_IO
        recorder?.append(.configure(configuration, status: status))
        return status
    }

    public func poll(_ timeout: Int32) -> dc_status_t {
        let status = cancellablePoll(timeout)
        recorder?.append(.poll(timeout: timeout, status: status))
        return status
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
        actual = 0
        let status: dc_status_t
        if inner == nil {
            status = DC_STATUS_IO
        } else if cancelled {
            status = DC_STATUS_CANCELLED
        } else {
            status = cancellableRead(buffer, &actual)
        }
        if wantsBytes {
            let bytes = Array(UnsafeRawBufferPointer(rebasing: buffer[0..<actual]))
            logPacket(.inbound, bytes)
            recorder?.append(.read(size: buffer.count, data: bytes, status: status))
        }
        return status
    }

    public func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
        var written = 0
        let status = inner.map { dc_iostream_write($0, data.baseAddress, data.count, &written) } ?? DC_STATUS_IO
        actual = written
        if wantsBytes {
            let bytes = Array(data)
            logPacket(.outbound, Array(bytes.prefix(written)))
            recorder?.append(.write(data: bytes, actual: written, status: status))
        }
        return status
    }

    public func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t {
        let direction = DCRecording.ioctlDirection(request)
        let input = recorder != nil && direction.write ? Array(data) : []
        let status = inner.map { dc_iostream_ioctl($0, request, data.baseAddress, data.count) } ?? DC_STATUS_IO
        if let recorder {
            recorder.append(.ioctl(request: request, input: input, output: direction.read ? Array(data) : [], status: status))
        }
        return status
    }

    public func flush() -> dc_status_t {
        let status = inner.map { dc_iostream_flush($0) } ?? DC_STATUS_IO
        recorder?.append(.flush(status: status))
        return status
    }

    public func purge(_ direction: dc_direction_t) -> dc_status_t {
        let status = inner.map { dc_iostream_purge($0, direction) } ?? DC_STATUS_IO
        recorder?.append(.purge(direction, status: status))
        return status
    }

    public func sleep(_ milliseconds: UInt32) -> dc_status_t {
        let status = cancellableSleep(milliseconds)
        recorder?.append(.sleep(milliseconds: milliseconds, status: status))
        return status
    }

    public func close() -> dc_status_t {
        guard let inner else { return DC_STATUS_SUCCESS }
        self.inner = nil
        let status = dc_iostream_close(inner)
        recorder?.append(.close(status: status))
        return status
    }

    // MARK: - Cancellable waits

    private var wantsBytes: Bool { recorder != nil || Logger.shared.shouldShowRawData }

    private func logPacket(_ direction: PacketDirection, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        Logger.shared.logPacket(direction: direction, data: Data(bytes), channel: channel)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func deadline(after milliseconds: Int32) -> UInt64? {
        milliseconds > 0 ? now() + UInt64(milliseconds) * 1_000_000 : nil
    }

    /// Rounded up, so the slice that reaches the deadline doesn't spin on 0.
    private static func millisecondsLeft(_ deadline: UInt64) -> Int32 {
        let now = now()
        guard deadline > now else { return 0 }
        return Int32(clamping: (deadline - now + 999_999) / 1_000_000)
    }

    private static func slice(until deadline: UInt64?) -> Int32 {
        deadline.map { min(cancelCheckMilliseconds, millisecondsLeft($0)) } ?? cancelCheckMilliseconds
    }

    private static func expired(_ deadline: UInt64?) -> Bool {
        deadline.map { now() >= $0 } ?? false
    }

    private func setInnerTimeout(_ inner: OpaquePointer, _ value: Int32) -> dc_status_t {
        guard innerTimeout != value else { return DC_STATUS_SUCCESS }
        let status = dc_iostream_set_timeout(inner, value)
        if status == DC_STATUS_SUCCESS { innerTimeout = value }
        return status
    }

    /// A plain inner read, with the inner timeout put back to `timeout` first (slices leave it at 0).
    private func directRead(_ inner: OpaquePointer, _ buffer: UnsafeMutableRawBufferPointer, from start: Int,
                            timeout: Int32?, _ actual: inout Int) -> dc_status_t {
        if let timeout { _ = setInnerTimeout(inner, timeout) }
        var count = 0
        let rest = UnsafeMutableRawBufferPointer(rebasing: buffer[start...])
        let status = dc_iostream_read(inner, rest.baseAddress, rest.count, &count)
        actual = start + count
        return status
    }

    // Keeps serial_posix's rules: -1 blocks, 0 takes what is there, N ms is a deadline, a timeout keeps the partial count.
    private func cancellableRead(_ buffer: UnsafeMutableRawBufferPointer, _ actual: inout Int) -> dc_status_t {
        guard let inner else { return DC_STATUS_IO }
        guard slicedReads, let timeout, timeout != 0, buffer.count > 0 else {
            return directRead(inner, buffer, from: 0, timeout: timeout, &actual)
        }
        let deadline = Self.deadline(after: timeout)
        while true {
            let ready = dc_iostream_poll(inner, Self.slice(until: deadline))
            if ready == DC_STATUS_SUCCESS {
                guard setInnerTimeout(inner, 0) == DC_STATUS_SUCCESS else {
                    slicedReads = false
                    return directRead(inner, buffer, from: actual, timeout: remaining(deadline), &actual)
                }
                var count = 0
                let rest = UnsafeMutableRawBufferPointer(rebasing: buffer[actual...])
                let status = dc_iostream_read(inner, rest.baseAddress, rest.count, &count)
                actual += count
                // SUCCESS short of the size is a packet stream's one-report read: hand it back as is.
                if status != DC_STATUS_TIMEOUT { return status }
                if count == 0 {
                    // Ready but empty: an always-ready poll or end of file; a plain read handles both as the inner stream would.
                    slicedReads = false
                    return directRead(inner, buffer, from: actual, timeout: remaining(deadline), &actual)
                }
            } else if ready == DC_STATUS_UNSUPPORTED {
                slicedReads = false
                return directRead(inner, buffer, from: actual, timeout: actual == 0 ? timeout : remaining(deadline), &actual)
            } else if ready != DC_STATUS_TIMEOUT {
                return ready
            }
            if cancelled { return DC_STATUS_CANCELLED }
            if Self.expired(deadline) { return DC_STATUS_TIMEOUT }
        }
    }

    private func remaining(_ deadline: UInt64?) -> Int32 {
        deadline.map(Self.millisecondsLeft) ?? -1
    }

    private func cancellablePoll(_ timeout: Int32) -> dc_status_t {
        guard let inner else { return DC_STATUS_IO }
        if cancelled { return DC_STATUS_CANCELLED }
        if timeout == 0 { return dc_iostream_poll(inner, 0) }
        let deadline = Self.deadline(after: timeout)
        while true {
            let status = dc_iostream_poll(inner, Self.slice(until: deadline))
            if status != DC_STATUS_TIMEOUT { return status }
            if cancelled { return DC_STATUS_CANCELLED }
            if Self.expired(deadline) { return DC_STATUS_TIMEOUT }
        }
    }

    private func cancellableSleep(_ milliseconds: UInt32) -> dc_status_t {
        guard let inner else { return DC_STATUS_IO }
        var left = milliseconds
        repeat {
            if cancelled { return DC_STATUS_CANCELLED }
            let step = min(left, UInt32(Self.cancelCheckMilliseconds))
            let status = dc_iostream_sleep(inner, step)
            if status != DC_STATUS_SUCCESS { return status }
            left -= step
        } while left > 0
        return DC_STATUS_SUCCESS
    }
}
#endif
