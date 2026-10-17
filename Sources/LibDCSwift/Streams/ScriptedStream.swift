#if os(macOS)
import Foundation
import Clibdivecomputer

/// Replays a `DCRecording` (or hand-written exchanges) strictly and without waiting: a call that isn't the next exchange with the same arguments and bytes fails with `DC_STATUS_IO`, as does every later call, and is kept in `deviation`; a script that ends before `close` accepts it.
public final class ScriptedStream: DCIOStreamBackend {
    public struct Deviation: Equatable, CustomStringConvertible {
        /// The exchange the call was matched against.
        public let index: Int
        /// Nil past the end of the script.
        public let expected: DCRecording.Exchange?
        public let attempted: DCIOStreamOperation
        public let detail: String

        public var description: String {
            "exchange \(index): \(detail) (expected \(expected.map { "\($0.operation.rawValue)" } ?? "end of script"), got \(attempted.rawValue))"
        }
    }

    public let transport: dc_transport_t
    public let exchanges: [DCRecording.Exchange]
    private let lock = NSLock()
    private var index = 0
    private var firstDeviation: Deviation?

    public init(_ exchanges: [DCRecording.Exchange], transport: dc_transport_t) {
        self.exchanges = exchanges
        self.transport = transport
    }

    public convenience init(recording: DCRecording) {
        self.init(recording.exchanges, transport: recording.transport)
    }

    public var deviation: Deviation? {
        lock.lock(); defer { lock.unlock() }
        return firstDeviation
    }

    /// Exchanges played so far.
    public var consumed: Int {
        lock.lock(); defer { lock.unlock() }
        return index
    }

    /// Every exchange played and none deviated.
    public var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return firstDeviation == nil && index == exchanges.count
    }

    /// `match` returns the reply for a matching exchange, or why it doesn't match.
    private func step(_ attempted: DCIOStreamOperation, _ match: (DCRecording.Exchange) -> Result<dc_status_t, Mismatch>) -> dc_status_t {
        lock.lock(); defer { lock.unlock() }
        guard firstDeviation == nil else { return DC_STATUS_IO }
        guard index < exchanges.count else {
            if attempted == .close { return DC_STATUS_SUCCESS }
            let deviation = Deviation(index: index, expected: nil, attempted: attempted, detail: "past the end of the script")
            firstDeviation = deviation
            logError("ScriptedStream: \(deviation)")
            return DC_STATUS_IO
        }
        let expected = exchanges[index]
        let detail: String
        if expected.operation != attempted {
            detail = "unexpected \(attempted.rawValue)"
        } else {
            switch match(expected) {
            case .success(let status):
                index += 1
                return status
            case .failure(let mismatch):
                detail = mismatch.detail
            }
        }
        let deviation = Deviation(index: index, expected: expected, attempted: attempted, detail: detail)
        firstDeviation = deviation
        logError("ScriptedStream: \(deviation)")
        return DC_STATUS_IO
    }

    private struct Mismatch: Error {
        let detail: String
        init(_ detail: String) { self.detail = detail }
    }

    private static func check<T: Equatable>(_ name: String, _ got: T, _ expected: T) -> Mismatch? {
        got == expected ? nil : Mismatch("\(name) \(got), expected \(expected)")
    }

    private static func reply(_ mismatch: Mismatch?, _ status: dc_status_t) -> Result<dc_status_t, Mismatch> {
        mismatch.map { .failure($0) } ?? .success(status)
    }

    private static func describe(_ c: DCSerialConfiguration) -> String {
        let parity = ["N", "O", "E", "M", "S"]
        let stopbits = ["1", "1.5", "2"]
        let p = Int(c.parity.rawValue) < parity.count ? parity[Int(c.parity.rawValue)] : "?"
        let s = Int(c.stopbits.rawValue) < stopbits.count ? stopbits[Int(c.stopbits.rawValue)] : "?"
        return "\(c.baudrate) \(c.databits)\(p)\(s) flow \(c.flowcontrol.rawValue)"
    }

    private static func hexPreview(_ bytes: [UInt8]) -> String {
        bytes.count > 32 ? DCRecording.hex(Array(bytes.prefix(32))) + "... (\(bytes.count) bytes)" : DCRecording.hex(bytes)
    }

    // MARK: - DCIOStreamBackend

    public func setTimeout(_ timeout: Int32) -> dc_status_t {
        step(.setTimeout) { expected in
            guard case let .setTimeout(value, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("timeout", timeout, value), status)
        }
    }

    public func setBreak(_ value: UInt32) -> dc_status_t {
        step(.setBreak) { expected in
            guard case let .setBreak(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("break", value, want), status)
        }
    }

    public func setDTR(_ value: UInt32) -> dc_status_t {
        step(.setDTR) { expected in
            guard case let .setDTR(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("DTR", value, want), status)
        }
    }

    public func setRTS(_ value: UInt32) -> dc_status_t {
        step(.setRTS) { expected in
            guard case let .setRTS(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("RTS", value, want), status)
        }
    }

    public func getLines(_ value: inout UInt32) -> dc_status_t {
        var lines: UInt32 = 0
        let status = step(.getLines) { expected in
            guard case let .getLines(recorded, status) = expected else { return .failure(Mismatch("unexpected")) }
            lines = recorded
            return .success(status)
        }
        value = lines
        return status
    }

    public func getAvailable(_ value: inout Int) -> dc_status_t {
        var available = 0
        let status = step(.getAvailable) { expected in
            guard case let .getAvailable(recorded, status) = expected else { return .failure(Mismatch("unexpected")) }
            available = recorded
            return .success(status)
        }
        value = available
        return status
    }

    public func configure(_ configuration: DCSerialConfiguration) -> dc_status_t {
        step(.configure) { expected in
            guard case let .configure(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            guard configuration == want else {
                return .failure(Mismatch("configure \(Self.describe(configuration)), expected \(Self.describe(want))"))
            }
            return .success(status)
        }
    }

    public func poll(_ timeout: Int32) -> dc_status_t {
        step(.poll) { expected in
            guard case let .poll(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("poll timeout", timeout, want), status)
        }
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
        var count = 0
        let status = step(.read) { expected in
            guard case let .read(size, data, status) = expected else { return .failure(Mismatch("unexpected")) }
            if let mismatch = Self.check("read size", buffer.count, size) { return .failure(mismatch) }
            guard data.count <= buffer.count else { return .failure(Mismatch("scripted read returns \(data.count) bytes for \(buffer.count)")) }
            if !data.isEmpty { buffer.copyBytes(from: data) }
            count = data.count
            return .success(status)
        }
        actual = count
        return status
    }

    public func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
        var count = 0
        let status = step(.write) { expected in
            guard case let .write(want, written, status) = expected else { return .failure(Mismatch("unexpected")) }
            let bytes = Array(data)
            guard bytes == want else {
                return .failure(Mismatch("write \(Self.hexPreview(bytes)), expected \(Self.hexPreview(want))"))
            }
            count = written
            return .success(status)
        }
        actual = count
        return status
    }

    public func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t {
        let direction = DCRecording.ioctlDirection(request)
        return step(.ioctl) { expected in
            guard case let .ioctl(want, input, output, status) = expected else { return .failure(Mismatch("unexpected")) }
            if let mismatch = Self.check("ioctl request", request, want) { return .failure(mismatch) }
            if direction.write, Array(data) != input {
                return .failure(Mismatch("ioctl input \(Self.hexPreview(Array(data))), expected \(Self.hexPreview(input))"))
            }
            if direction.read {
                guard output.count <= data.count else { return .failure(Mismatch("scripted ioctl returns \(output.count) bytes for \(data.count)")) }
                if !output.isEmpty { data.copyBytes(from: output) }
            }
            return .success(status)
        }
    }

    public func flush() -> dc_status_t {
        step(.flush) { expected in
            guard case let .flush(status) = expected else { return .failure(Mismatch("unexpected")) }
            return .success(status)
        }
    }

    public func purge(_ direction: dc_direction_t) -> dc_status_t {
        step(.purge) { expected in
            guard case let .purge(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("purge direction", direction.rawValue, want.rawValue), status)
        }
    }

    public func sleep(_ milliseconds: UInt32) -> dc_status_t {
        step(.sleep) { expected in
            guard case let .sleep(want, status) = expected else { return .failure(Mismatch("unexpected")) }
            return Self.reply(Self.check("sleep", milliseconds, want), status)
        }
    }

    public func close() -> dc_status_t {
        step(.close) { expected in
            guard case let .close(status) = expected else { return .failure(Mismatch("unexpected")) }
            return .success(status)
        }
    }
}
#endif
