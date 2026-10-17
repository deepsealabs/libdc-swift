#if os(macOS)
import Foundation
import Clibdivecomputer

/// An iostream conversation in order (each operation, its arguments, what came back), saved as `.dcrec` JSON for `ScriptedStream`; it holds no port path, adapter serial or wall-clock time.
public struct DCRecording: Equatable {
    public static let fileExtension = "dcrec"
    public static let currentVersion = 1

    public var version: Int
    /// The transport drivers see on replay (`dc_iostream_get_transport`).
    public var transport: dc_transport_t
    public var family: dc_family_t?
    public var model: UInt32?
    public var exchanges: [Exchange]

    public init(transport: dc_transport_t, family: dc_family_t? = nil, model: UInt32? = nil, exchanges: [Exchange] = []) {
        version = Self.currentVersion
        self.transport = transport
        self.family = family
        self.model = model
        self.exchanges = exchanges
    }

    /// One operation with its arguments and its result.
    public enum Exchange: Equatable {
        case setTimeout(Int32, status: dc_status_t)
        case setBreak(UInt32, status: dc_status_t)
        case setDTR(UInt32, status: dc_status_t)
        case setRTS(UInt32, status: dc_status_t)
        case getLines(value: UInt32, status: dc_status_t)
        case getAvailable(value: Int, status: dc_status_t)
        case configure(DCSerialConfiguration, status: dc_status_t)
        case poll(timeout: Int32, status: dc_status_t)
        /// `data` is what came back (the partial count on a timeout) for a read of `size` bytes.
        case read(size: Int, data: [UInt8], status: dc_status_t)
        /// `data` is everything the driver asked to write; `actual` is how much went out.
        case write(data: [UInt8], actual: Int, status: dc_status_t)
        /// `input` is the request buffer going in (write requests), `output` what came back (read requests).
        case ioctl(request: UInt32, input: [UInt8], output: [UInt8], status: dc_status_t)
        case flush(status: dc_status_t)
        case purge(dc_direction_t, status: dc_status_t)
        case sleep(milliseconds: UInt32, status: dc_status_t)
        case close(status: dc_status_t)

        public var operation: DCIOStreamOperation {
            switch self {
            case .setTimeout: return .setTimeout
            case .setBreak: return .setBreak
            case .setDTR: return .setDTR
            case .setRTS: return .setRTS
            case .getLines: return .getLines
            case .getAvailable: return .getAvailable
            case .configure: return .configure
            case .poll: return .poll
            case .read: return .read
            case .write: return .write
            case .ioctl: return .ioctl
            case .flush: return .flush
            case .purge: return .purge
            case .sleep: return .sleep
            case .close: return .close
            }
        }

        public var status: dc_status_t {
            switch self {
            case .setTimeout(_, let status), .setBreak(_, let status), .setDTR(_, let status), .setRTS(_, let status),
                 .getLines(_, let status), .getAvailable(_, let status), .configure(_, let status), .poll(_, let status),
                 .read(_, _, let status), .write(_, _, let status), .ioctl(_, _, _, let status), .flush(let status),
                 .purge(_, let status), .sleep(_, let status), .close(let status):
                return status
            }
        }
    }

    public enum FormatError: Error, Equatable {
        case notADCRec
        case unsupportedVersion(Int)
        case unknownTransport(String)
        case unknownStatus(String)
        case missingField(DCIOStreamOperation, String)
        case badHex(String)
    }

    // MARK: - .dcrec

    /// The `.dcrec` bytes: JSON with one exchange per line, so fixtures diff cleanly.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = ["{", "  \"format\": \"dcrec\",", "  \"version\": \(version),",
                     "  \"transport\": \"\(Self.name(of: transport))\","]
        if let family { lines.append("  \"family\": \(family.rawValue),") }
        if let model { lines.append("  \"model\": \(model),") }
        let rows = try exchanges.map { "    " + String(decoding: try encoder.encode(Row($0)), as: UTF8.self) }
        if rows.isEmpty {
            lines.append("  \"exchanges\": []")
        } else {
            lines.append("  \"exchanges\": [")
            lines.append(rows.joined(separator: ",\n"))
            lines.append("  ]")
        }
        lines.append("}")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public init(dcrec data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format == "dcrec" else { throw FormatError.notADCRec }
        guard file.version >= 1, file.version <= Self.currentVersion else { throw FormatError.unsupportedVersion(file.version) }
        guard let transport = Self.transport(named: file.transport) else { throw FormatError.unknownTransport(file.transport) }
        self.init(transport: transport, family: file.family.map(dc_family_t.init(rawValue:)), model: file.model,
                  exchanges: try file.exchanges.map { try $0.exchange() })
        version = file.version
    }

    public init(contentsOf url: URL) throws {
        try self.init(dcrec: try Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    private struct File: Decodable {
        let format: String
        let version: Int
        let transport: String
        let family: UInt32?
        let model: UInt32?
        let exchanges: [Row]
    }

    private struct Row: Codable {
        var op: DCIOStreamOperation
        var status: String
        var value: Int64?
        var timeout: Int32?
        var baudrate: UInt32?
        var databits: UInt32?
        var parity: UInt32?
        var stopbits: UInt32?
        var flowcontrol: UInt32?
        var size: Int?
        var data: String?
        var actual: Int?
        var request: UInt32?
        var input: String?
        var output: String?
        var direction: UInt32?
        var milliseconds: UInt32?

        init(_ exchange: Exchange) {
            op = exchange.operation
            status = DCRecording.name(of: exchange.status)
            switch exchange {
            case .setTimeout(let timeout, _), .poll(let timeout, _):
                self.timeout = timeout
            case .setBreak(let value, _), .setDTR(let value, _), .setRTS(let value, _), .getLines(let value, _):
                self.value = Int64(value)
            case .getAvailable(let value, _):
                self.value = Int64(value)
            case .configure(let configuration, _):
                baudrate = configuration.baudrate
                databits = configuration.databits
                parity = configuration.parity.rawValue
                stopbits = configuration.stopbits.rawValue
                flowcontrol = configuration.flowcontrol.rawValue
            case .read(let size, let data, _):
                self.size = size
                self.data = DCRecording.hex(data)
            case .write(let data, let actual, _):
                self.data = DCRecording.hex(data)
                self.actual = actual
            case .ioctl(let request, let input, let output, _):
                self.request = request
                self.input = DCRecording.hex(input)
                self.output = DCRecording.hex(output)
            case .purge(let direction, _):
                self.direction = direction.rawValue
            case .sleep(let milliseconds, _):
                self.milliseconds = milliseconds
            case .flush, .close:
                break
            }
        }

        private func need<T>(_ field: T?, _ name: String) throws -> T {
            guard let field else { throw FormatError.missingField(op, name) }
            return field
        }

        private func bytes(_ field: String?, _ name: String) throws -> [UInt8] {
            try DCRecording.bytes(fromHex: try need(field, name))
        }

        func exchange() throws -> Exchange {
            guard let status = DCRecording.status(named: status) else { throw FormatError.unknownStatus(status) }
            switch op {
            case .setTimeout: return .setTimeout(try need(timeout, "timeout"), status: status)
            case .setBreak: return .setBreak(UInt32(truncatingIfNeeded: try need(value, "value")), status: status)
            case .setDTR: return .setDTR(UInt32(truncatingIfNeeded: try need(value, "value")), status: status)
            case .setRTS: return .setRTS(UInt32(truncatingIfNeeded: try need(value, "value")), status: status)
            case .getLines: return .getLines(value: UInt32(truncatingIfNeeded: try need(value, "value")), status: status)
            case .getAvailable: return .getAvailable(value: Int(try need(value, "value")), status: status)
            case .configure:
                return .configure(DCSerialConfiguration(
                    baudrate: try need(baudrate, "baudrate"), databits: try need(databits, "databits"),
                    parity: dc_parity_t(rawValue: try need(parity, "parity")),
                    stopbits: dc_stopbits_t(rawValue: try need(stopbits, "stopbits")),
                    flowcontrol: dc_flowcontrol_t(rawValue: try need(flowcontrol, "flowcontrol"))), status: status)
            case .poll: return .poll(timeout: try need(timeout, "timeout"), status: status)
            case .read: return .read(size: try need(size, "size"), data: try bytes(data, "data"), status: status)
            case .write: return .write(data: try bytes(data, "data"), actual: try need(actual, "actual"), status: status)
            case .ioctl:
                return .ioctl(request: try need(request, "request"), input: try bytes(input, "input"),
                              output: try bytes(output, "output"), status: status)
            case .flush: return .flush(status: status)
            case .purge: return .purge(dc_direction_t(rawValue: try need(direction, "direction")), status: status)
            case .sleep: return .sleep(milliseconds: try need(milliseconds, "milliseconds"), status: status)
            case .close: return .close(status: status)
            }
        }
    }

    // MARK: - Names

    private static let statusNames: [(dc_status_t, String)] = [
        (DC_STATUS_SUCCESS, "success"), (DC_STATUS_DONE, "done"), (DC_STATUS_UNSUPPORTED, "unsupported"),
        (DC_STATUS_INVALIDARGS, "invalidargs"), (DC_STATUS_NOMEMORY, "nomemory"), (DC_STATUS_NODEVICE, "nodevice"),
        (DC_STATUS_NOACCESS, "noaccess"), (DC_STATUS_IO, "io"), (DC_STATUS_TIMEOUT, "timeout"),
        (DC_STATUS_PROTOCOL, "protocol"), (DC_STATUS_DATAFORMAT, "dataformat"), (DC_STATUS_CANCELLED, "cancelled"),
    ]

    private static let transportNames: [(dc_transport_t, String)] = [
        (DC_TRANSPORT_NONE, "none"), (DC_TRANSPORT_SERIAL, "serial"), (DC_TRANSPORT_USB, "usb"),
        (DC_TRANSPORT_USBHID, "usbhid"), (DC_TRANSPORT_IRDA, "irda"), (DC_TRANSPORT_BLUETOOTH, "bluetooth"),
        (DC_TRANSPORT_BLE, "ble"),
    ]

    static func name(of status: dc_status_t) -> String {
        statusNames.first { $0.0 == status }?.1 ?? String(status.rawValue)
    }

    static func status(named name: String) -> dc_status_t? {
        statusNames.first { $0.1 == name }?.0 ?? Int32(name).map(dc_status_t.init(rawValue:))
    }

    static func name(of transport: dc_transport_t) -> String {
        transportNames.first { $0.0 == transport }?.1 ?? String(transport.rawValue)
    }

    static func transport(named name: String) -> dc_transport_t? {
        transportNames.first { $0.1 == name }?.0
    }

    /// `DC_IOCTL_DIR`, which Swift can't import: READ means the caller reads what the stream fills in.
    static func ioctlDirection(_ request: UInt32) -> (read: Bool, write: Bool) {
        let direction = (request >> 30) & 0x3
        return (direction & 0x1 != 0, direction & 0x2 != 0)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func bytes(fromHex hex: String) throws -> [UInt8] {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { throw FormatError.badHex(String(hex.prefix(16))) }
        func nibble(_ c: UInt8) throws -> UInt8 {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: throw FormatError.badHex(String(hex.prefix(16)))
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            out.append(try nibble(chars[index]) << 4 | nibble(chars[index + 1]))
            index += 2
        }
        return out
    }
}

/// Rewrites bytes in `DCStreamRecorder.recording()` so a fixture carries no real serial, date or position; it sees each direction as one stream (a pattern split across reads is still found) and must keep the length, or the bytes are zeroed.
public struct DCRecordScrubber {
    public let scrub: (_ bytes: [UInt8], _ direction: PacketDirection) -> [UInt8]

    public init(_ scrub: @escaping (_ bytes: [UInt8], _ direction: PacketDirection) -> [UInt8]) {
        self.scrub = scrub
    }

    public static let none = DCRecordScrubber { bytes, _ in bytes }

    /// Swaps every occurrence of each pattern (a serial number's bytes, say) for a stand-in of the same length, both ways.
    public static func replacing(_ replacements: [(pattern: [UInt8], replacement: [UInt8])]) -> DCRecordScrubber {
        precondition(replacements.allSatisfy { !$0.pattern.isEmpty && $0.pattern.count == $0.replacement.count },
                     "scrub patterns must be non-empty and the same length as their replacement")
        return DCRecordScrubber { bytes, _ in
            var out = bytes
            for (pattern, replacement) in replacements {
                var index = 0
                while index + pattern.count <= out.count {
                    if out[index..<(index + pattern.count)].elementsEqual(pattern) {
                        out.replaceSubrange(index..<(index + pattern.count), with: replacement)
                        index += pattern.count
                    } else {
                        index += 1
                    }
                }
            }
            return out
        }
    }

    /// This scrubber, then `next`.
    public func then(_ next: DCRecordScrubber) -> DCRecordScrubber {
        DCRecordScrubber { bytes, direction in next.scrub(self.scrub(bytes, direction), direction) }
    }

    func apply(_ bytes: [UInt8], _ direction: PacketDirection) -> [UInt8] {
        let scrubbed = scrub(bytes, direction)
        guard scrubbed.count == bytes.count else {
            logWarning("A recording scrubber changed the byte count (\(bytes.count) to \(scrubbed.count)); zeroing those bytes")
            return [UInt8](repeating: 0, count: bytes.count)
        }
        return scrubbed
    }
}

/// Collects a `TapStream`'s exchanges for a `.dcrec`; `recording()` applies the scrubber. Thread-safe.
public final class DCStreamRecorder {
    public let scrubber: DCRecordScrubber
    private let lock = NSLock()
    private var transport = DC_TRANSPORT_NONE
    private var log: [DCRecording.Exchange] = []

    public init(scrubber: DCRecordScrubber = .none) {
        self.scrubber = scrubber
    }

    /// How many exchanges so far.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return log.count
    }

    /// The exchanges so far, scrubbed.
    public func recording(family: dc_family_t? = nil, model: UInt32? = nil) -> DCRecording {
        lock.lock()
        let exchanges = log
        let transport = transport
        lock.unlock()
        return DCRecording(transport: transport, family: family, model: model, exchanges: Self.scrub(exchanges, scrubber))
    }

    func begin(transport: dc_transport_t) {
        lock.lock(); defer { lock.unlock() }
        self.transport = transport
    }

    func append(_ exchange: DCRecording.Exchange) {
        lock.lock(); defer { lock.unlock() }
        log.append(exchange)
    }

    private static func scrub(_ exchanges: [DCRecording.Exchange], _ scrubber: DCRecordScrubber) -> [DCRecording.Exchange] {
        var inbound: [UInt8] = [], outbound: [UInt8] = []
        for exchange in exchanges {
            switch exchange {
            case .read(_, let data, _): inbound += data
            case .write(let data, _, _): outbound += data
            default: break
            }
        }
        inbound = scrubber.apply(inbound, .inbound)
        outbound = scrubber.apply(outbound, .outbound)
        var inIndex = 0, outIndex = 0
        return exchanges.map { exchange in
            switch exchange {
            case .read(let size, let data, let status):
                defer { inIndex += data.count }
                return .read(size: size, data: Array(inbound[inIndex..<(inIndex + data.count)]), status: status)
            case .write(let data, let actual, let status):
                defer { outIndex += data.count }
                return .write(data: Array(outbound[outIndex..<(outIndex + data.count)]), actual: actual, status: status)
            case .ioctl(let request, let input, let output, let status):
                return .ioctl(request: request, input: scrubber.apply(input, .outbound),
                              output: scrubber.apply(output, .inbound), status: status)
            default:
                return exchange
            }
        }
    }
}
#endif
