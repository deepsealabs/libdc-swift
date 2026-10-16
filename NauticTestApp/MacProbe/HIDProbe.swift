#if os(macOS)
import Foundation
// IOHIDDevice is not Sendable-annotated; IOHIDDeviceCancel is documented as callable from any queue.
@preconcurrency import IOKit
import IOKit.hid
import IOKit.hidsystem

struct HIDDeviceInfo: Identifiable, Hashable {
    let id: UInt64
    let vendorID: Int
    let productID: Int
    let product: String?
    let manufacturer: String?
    let serial: String?
    let transport: String?
    let usagePage: Int?
    let usage: Int?
    let maxInputReport: Int?
    let maxOutputReport: Int?
    let maxFeatureReport: Int?

    var vidPid: String { ProbeText.vidPid(vendorID, productID) }
    var model: String? { HIDProbe.model(vendorID: vendorID, productID: productID) }
    var displayName: String { "\(model ?? product ?? "HID device") \(vidPid)" }
    var identify: HIDIdentify? { HIDIdentify(vendorID: vendorID, productID: productID) }

    /// Why Run open tests leaves this device to its own Open test; nil when it opens it.
    var autoSkipReason: String? {
        if usagePage == HIDProbe.genericDesktopUsagePage {
            return "keyboard or mouse usage page, whose open can raise the Input Monitoring prompt"
        }
        if model == nil && !HIDProbe.diveVendorIDs.contains(vendorID) {
            return "VID \(ProbeText.hex4(vendorID)) is shared with debug probes and this PID isn't a known model"
        }
        return nil
    }

    var usageSummary: String {
        let page = usagePage.map { String(format: "0x%04x", $0) } ?? "?"
        let use = usage.map { String(format: "0x%02x", $0) } ?? "?"
        return "usage page \(page) usage \(use)"
    }

    var reportSummary: String {
        func size(_ value: Int?) -> String { value.map(String.init) ?? "?" }
        return "max report in \(size(maxInputReport)) / out \(size(maxOutputReport)) / feature \(size(maxFeatureReport))"
    }

    init(_ device: IOHIDDevice) {
        func int(_ key: String) -> Int? { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue }
        func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
        id = Registry.registryID(IOHIDDeviceGetService(device))
        vendorID = int(kIOHIDVendorIDKey) ?? 0
        productID = int(kIOHIDProductIDKey) ?? 0
        product = string(kIOHIDProductKey)
        manufacturer = string(kIOHIDManufacturerKey)
        serial = string(kIOHIDSerialNumberKey)
        transport = string(kIOHIDTransportKey)
        usagePage = int(kIOHIDPrimaryUsagePageKey)
        usage = int(kIOHIDPrimaryUsageKey)
        maxInputReport = int(kIOHIDMaxInputReportSizeKey)
        maxOutputReport = int(kIOHIDMaxOutputReportSizeKey)
        maxFeatureReport = int(kIOHIDMaxFeatureReportSizeKey)
    }
}

enum HIDOpenMode: String, CaseIterable, Hashable {
    case seize
    case shared

    var options: IOOptionBits {
        switch self {
        case .seize: return IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        case .shared: return IOOptionBits(kIOHIDOptionsTypeNone)
        }
    }
}

struct HIDCommand {
    let name: String
    let reportID: CFIndex
    let payload: [UInt8]
    /// False for a report that can't answer this command, such as a late packet from the one before.
    let canBeReply: ([UInt8]) -> Bool
    let check: ([UInt8]) -> (ok: Bool, verdict: String)
}

/// Read-only commands that make each family answer, built byte for byte as libdc's HID path sends them.
enum HIDIdentify: String, Hashable {
    case uwatecSmart = "Uwatec smart"
    case eonSteel = "EON Steel"

    // Only known models: 1493 also covers Suunto's Ambit watches and c251 is Keil's VID, used by CMSIS-DAP probes.
    init?(vendorID: Int, productID: Int) {
        guard HIDProbe.model(vendorID: vendorID, productID: productID) != nil else { return nil }
        switch vendorID {
        case 0x1493: self = .eonSteel
        case 0x2e6c, 0xc251: self = .uwatecSmart
        default: return nil
        }
    }

    // Same order as uwatec_smart_device_open's handshake, then the CMD_MODEL a dump starts with.
    var commands: [HIDCommand] {
        switch self {
        case .uwatecSmart:
            return [
                Self.uwatec("handshake 1", command: 0x1b, expectOK: true),
                Self.uwatec("handshake 2", command: 0x1c, data: [0x10, 0x27, 0x00, 0x00], expectOK: true),
                Self.uwatec("model", command: 0x10, expectOK: false)
            ]
        case .eonSteel:
            return [Self.eonSteelInit]
        }
    }

    // libdc builds [0x00, size + 1, cmd, data] padded to 33; hidapi drops the zero report ID and sends 32.
    private static func uwatec(_ name: String, command: UInt8, data: [UInt8] = [], expectOK: Bool) -> HIDCommand {
        var payload = [UInt8](repeating: 0, count: 32)
        payload[0] = UInt8(data.count + 1)
        payload[1] = command
        payload.replaceSubrange(2..<(2 + data.count), with: data)
        // libdc reads a 1-byte answer, skipping empty packets and failing on longer ones.
        return HIDCommand(name: name, reportID: 0, payload: payload, canBeReply: { $0.count >= 2 && $0[0] == 1 }) { reply in
            guard reply.count >= 2 else { return (false, "reply has \(reply.count) bytes") }
            let length = reply[0]
            let answer = reply[1]
            if expectOK {
                let text = String(format: "length %d, answer 0x%02x", length, answer)
                return answer == 0x01 ? (true, text + " (OK)") : (false, text + ", expected 0x01")
            }
            return (length >= 1, String(format: "length %d, model 0x%02x", length, answer))
        }
    }

    // suunto_eonsteel_send's CMD_INIT: 0x3f, length, cmd, magic 1, seq 0, size, data, CRC32 over buf+2.
    private static var eonSteelInit: HIDCommand {
        let data: [UInt8] = [0x02, 0x00, 0x2a, 0x00]
        var payload = [UInt8](repeating: 0, count: 64)
        payload[0] = 0x3f
        payload[1] = UInt8(12 + data.count)
        payload[4] = 0x01
        payload[10] = UInt8(data.count)
        payload.replaceSubrange(14..<18, with: data)
        let crc = crc32(payload[2..<18])
        payload.replaceSubrange(18..<22, with: (0..<4).map { UInt8(truncatingIfNeeded: crc >> (8 * $0)) })
        return HIDCommand(name: "init", reportID: 0x3f, payload: payload, canBeReply: { reply in
            reply.count >= 14 && reply[0] == 0x3f && Self.sequence(reply) == 0
        }) { reply in
            guard reply.count >= 14 else { return (false, "reply has \(reply.count) bytes") }
            guard reply[0] == 0x3f else { return (false, String(format: "byte 0 is 0x%02x, expected report ID 0x3f", reply[0])) }
            let sequence = Self.sequence(reply)
            let length = (10..<14).reduce(0) { $0 | Int(reply[$1]) << (8 * ($1 - 10)) }
            let text = "byte 0 0x3f, packet length \(reply[1]), seq \(sequence), payload length \(length)"
            return sequence == 0 ? (true, text) : (false, text + ", expected seq 0")
        }
    }

    private static func sequence(_ reply: [UInt8]) -> Int {
        Int(reply[8]) | Int(reply[9]) << 8
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

struct HIDExchange: Hashable {
    let name: String
    let setReport: IOReturn
    let setReportMilliseconds: Int
    let replyMilliseconds: Int?
    let reply: String?
    let verdict: String?
    let ok: Bool

    var brief: String {
        if setReport != kIOReturnSuccess { return "\(name) SetReport FAILED" }
        guard let replyMilliseconds else { return "\(name) no reply" }
        return ok ? "\(name) ok in \(replyMilliseconds) ms" : "\(name) unexpected reply"
    }

    var step: ProbeStep {
        var parts = ["SetReport(Output) \(ProbeText.ioReturn(setReport)) in \(setReportMilliseconds) ms"]
        if setReport == kIOReturnSuccess {
            if let replyMilliseconds, let reply {
                parts.append("first input report after \(replyMilliseconds) ms, \(reply)")
            } else {
                parts.append("no input report within \(Int(HIDProbe.replyTimeout)) s")
            }
        }
        if let verdict { parts.append(verdict) }
        let detail = parts.joined(separator: "; ")
        return ok ? .ok(name, detail) : .failed(name, detail)
    }
}

struct HIDOpenResult: Hashable {
    let mode: HIDOpenMode
    let identify: HIDIdentify?
    let steps: [ProbeStep]
    let exchanges: [HIDExchange]
    let reports: Int
    let firstReport: String?
    let inputMonitoring: String

    var opened: Bool { steps.contains { $0.name == "IOHIDDeviceOpen" && $0.outcome == .ok } }

    var readSummary: String {
        guard opened else { return "-" }
        if identify != nil {
            return exchanges.isEmpty ? "identify not sent" : "identify: " + exchanges.map(\.brief).joined(separator: ", ")
        }
        return "listen only: \(reports) reports / \(Int(HIDProbe.listenSeconds)) s" + (firstReport.map { ", first \($0)" } ?? "")
    }
}

/// Matches by dive-computer vendor ID only; which matched devices get opened is decided per PID.
final class HIDWatcher {
    typealias Handler = (_ device: IOHIDDevice, _ matched: Bool) -> Void

    private let manager: IOHIDManager
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = HIDProbe.vendorIDs.map { [kIOHIDVendorIDKey: $0] } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().handler(device, true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().handler(device, false)
        }, context)
        IOHIDManagerSetDispatchQueue(manager, .main)
        // Keeps the manager alive until cancellation completes, per IOHIDManager.h.
        IOHIDManagerSetCancelHandler(manager) { [manager] in _ = manager }
        IOHIDManagerActivate(manager)
    }

    deinit {
        IOHIDManagerCancel(manager)
    }

    func snapshot() -> [HIDDeviceInfo] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        return (set as NSSet).allObjects.map { HIDDeviceInfo($0 as! IOHIDDevice) }
    }
}

enum HIDProbe {
    static let vendorIDs = [0x1493, 0x2e6c, 0xc251]
    // Suunto's and Scubapro's own VIDs; c251 belongs to Keil, so only its Aladin Square PID counts.
    static let diveVendorIDs: Set = [0x1493, 0x2e6c]
    static let genericDesktopUsagePage = 0x0001
    static let listenSeconds: Double = 2
    static let replyTimeout: Double = 2

    static let models: [(Int, Int, String)] = [
        (0x1493, 0x0030, "Suunto EON Steel"),
        (0x1493, 0x0033, "Suunto EON Core"),
        (0x1493, 0x0035, "Suunto D5"),
        (0x1493, 0x0036, "Suunto EON Steel Black"),
        (0x2e6c, 0x3201, "Scubapro G2 / G2 TEK"),
        (0x2e6c, 0x3211, "Scubapro G2 Console"),
        (0x2e6c, 0x4201, "Scubapro G2 HUD"),
        (0xc251, 0x2006, "Scubapro Aladin Square")
    ]

    static func model(vendorID: Int, productID: Int) -> String? {
        models.first { $0.0 == vendorID && $0.1 == productID }?.2
    }

    /// Checking never prompts; IOHIDRequestAccess or a gated IOHIDDeviceOpen does.
    static func inputMonitoringAccess() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        case kIOHIDAccessTypeUnknown: return "unknown"
        case let other: return "access type \(other.rawValue)"
        }
    }

    // Input callbacks land on the HID queue while the exchange waits on its own queue.
    private final class ReportSink: @unchecked Sendable {
        struct Report {
            let arrived: DispatchTime
            let id: UInt32
            let bytes: [UInt8]
        }

        let capacity: Int
        let buffer: UnsafeMutablePointer<UInt8>
        let arrival = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var kept: [Report] = []
        private var total = 0
        private var removed = false

        init(capacity: Int) {
            self.capacity = capacity
            buffer = .allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
        }

        deinit { buffer.deallocate() }

        func record(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: Int) {
            let copy = Array(UnsafeBufferPointer(start: bytes, count: min(length, capacity)))
            lock.withLock {
                total += 1
                if kept.count < 64 { kept.append(Report(arrived: .now(), id: reportID, bytes: copy)) }
            }
            arrival.signal()
        }

        func markRemoved() { lock.withLock { removed = true } }

        var keptCount: Int { lock.withLock { kept.count } }
        var count: Int { lock.withLock { total } }
        var wasRemoved: Bool { lock.withLock { removed } }
        func report(at index: Int) -> Report? { lock.withLock { index < kept.count ? kept[index] : nil } }
        func first() -> Report? { report(at: 0) }

        func discardSignals() {
            while arrival.wait(timeout: .now()) == .success {}
        }
    }

    private final class ExchangeLog: @unchecked Sendable {
        var exchanges: [HIDExchange] = []
    }

    // 16 bytes stops short of the serial number at offset 0x10 of the EON Steel init payload.
    private static func describe(_ report: ReportSink.Report) -> String {
        "id \(report.id), \(report.bytes.count) bytes: \(ProbeText.hex(report.bytes, limit: 16))"
    }

    /// Fresh IOHIDDevice per run: a device that was scheduled and cancelled cannot be scheduled again.
    @concurrent
    static func openTest(registryID: UInt64, mode: HIDOpenMode, identify: HIDIdentify?) async -> HIDOpenResult {
        func result(_ steps: [ProbeStep]) -> HIDOpenResult {
            HIDOpenResult(mode: mode, identify: identify, steps: steps, exchanges: [], reports: 0, firstReport: nil,
                          inputMonitoring: inputMonitoringAccess())
        }
        let service = Registry.service(registryID: registryID)
        guard service != 0 else { return result([.failed("lookup", "device is gone")]) }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
            return result([.failed("IOHIDDeviceCreate", "returned NULL")])
        }

        let open = IOHIDDeviceOpen(device, mode.options)
        guard open == kIOReturnSuccess else {
            return result([.failed("IOHIDDeviceOpen", ProbeText.ioReturn(open))])
        }
        var steps: [ProbeStep] = [.ok("IOHIDDeviceOpen", mode == .seize ? "kIOHIDOptionsTypeSeizeDevice" : "kIOHIDOptionsTypeNone")]

        let declared = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        let sink = ReportSink(capacity: max(declared, 64))
        let context = Unmanaged.passRetained(sink).toOpaque()
        let queue = DispatchQueue(label: "com.deepsealabs.DCTesterMac.hid.\(registryID)")
        let exchangeQueue = DispatchQueue(label: "com.deepsealabs.DCTesterMac.hid.exchange.\(registryID)")
        let log = ExchangeLog()

        IOHIDDeviceRegisterInputReportCallback(device, sink.buffer, sink.capacity, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            Unmanaged<ReportSink>.fromOpaque(context).takeUnretainedValue().record(reportID: reportID, bytes: report, length: length)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<ReportSink>.fromOpaque(context).takeUnretainedValue().markRemoved()
        }, context)
        IOHIDDeviceSetDispatchQueue(device, queue)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            IOHIDDeviceSetCancelHandler(device) { continuation.resume() }
            IOHIDDeviceActivate(device)
            if let identify {
                exchangeQueue.async {
                    for command in identify.commands {
                        let exchange = send(command, to: device, sink: sink)
                        log.exchanges.append(exchange)
                        if !exchange.ok { break }
                    }
                    IOHIDDeviceCancel(device)
                }
            } else {
                queue.asyncAfter(deadline: .now() + listenSeconds) { IOHIDDeviceCancel(device) }
            }
        }

        let removed = sink.wasRemoved ? ", device removed" : ""
        if identify == nil {
            steps.append(.ok("activate + listen", "\(sink.count) input reports in \(Int(listenSeconds)) s" + removed))
        } else {
            steps.append(.ok("activate", "\(sink.count) input reports during identify" + removed))
            steps += log.exchanges.map(\.step)
        }
        steps.append(.ok("IOHIDDeviceCancel", "cancel handler ran"))
        let close = IOHIDDeviceClose(device, mode.options)
        steps.append(close == kIOReturnSuccess ? .ok("IOHIDDeviceClose") : .failed("IOHIDDeviceClose", ProbeText.ioReturn(close)))
        let access = inputMonitoringAccess()
        steps.append(.ok("IOHIDCheckAccess(ListenEvent)", access))

        let outcome = HIDOpenResult(mode: mode, identify: identify, steps: steps, exchanges: log.exchanges,
                                    reports: sink.count, firstReport: sink.first().map(describe), inputMonitoring: access)
        Unmanaged<ReportSink>.fromOpaque(context).release()
        return outcome
    }

    // Synchronous SetReport, as hidapi's hid_write does; the reply wait runs off the HID queue so callbacks keep flowing.
    private static func send(_ command: HIDCommand, to device: IOHIDDevice, sink: ReportSink) -> HIDExchange {
        // Taken before the index, so every report from the index on arrived after it.
        let start = DispatchTime.now()
        sink.discardSignals()
        var index = sink.keptCount
        let sendStart = DispatchTime.now()
        let kr = command.payload.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, command.reportID, buffer.baseAddress!, buffer.count)
        }
        let sent = ProbeText.milliseconds(since: sendStart)
        guard kr == kIOReturnSuccess else {
            return HIDExchange(name: command.name, setReport: kr, setReportMilliseconds: sent, replyMilliseconds: nil,
                               reply: nil, verdict: nil, ok: false)
        }
        let deadline = DispatchTime.now() + replyTimeout
        var reply: ReportSink.Report?
        var skipped: [ReportSink.Report] = []
        repeat {
            while reply == nil, let next = sink.report(at: index) {
                index += 1
                if command.canBeReply(next.bytes) { reply = next } else { skipped.append(next) }
            }
        } while reply == nil && sink.arrival.wait(timeout: deadline) == .success
        // With no plausible reply, the first report still explains why, e.g. a missing report-ID byte.
        guard let answer = reply ?? skipped.first else {
            return HIDExchange(name: command.name, setReport: kr, setReportMilliseconds: sent, replyMilliseconds: nil,
                               reply: nil, verdict: nil, ok: false)
        }
        let elapsed = answer.arrived >= start ? Int((answer.arrived.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) : 0
        var check = command.check(answer.bytes)
        if reply == nil {
            check = (false, check.verdict + "; none of the \(skipped.count) reports could be this reply")
        } else if !skipped.isEmpty {
            check.verdict += "; skipped \(skipped.count) earlier reports that couldn't be this reply"
        }
        return HIDExchange(name: command.name, setReport: kr, setReportMilliseconds: sent, replyMilliseconds: elapsed,
                           reply: describe(answer), verdict: check.verdict, ok: check.ok)
    }
}
#endif
