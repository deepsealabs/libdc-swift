#if os(macOS)
import XCTest
import IOKit
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// An IOHIDDevice stand-in that logs every call, delivers reports through the registered buffer on the dispatch queue, and flags anything IOHIDDevice.h forbids.
final class FakeHIDDevice: HIDDeviceIO, @unchecked Sendable {
    enum Call: Equatable {
        case open(seize: Bool)
        case registerInputReport(length: Int)
        case registerRemoval
        case setDispatchQueue
        case setCancelHandler
        case activate
        case setReport(id: Int, bytes: [UInt8])
        case cancel
        case cancelHandlerRan
        case close(seize: Bool)
    }

    var maxInputReportSize: Int?
    var openResult: IOReturn = kIOReturnSuccess
    var setReportResult: IOReturn = kIOReturnSuccess
    /// Holds the cancel handler back until `runCancelHandler()`, as a queue still busy with events would.
    var holdsCancelHandler = false
    /// The computer on the other end: the input reports it sends for each output report.
    var computer: ((_ reportID: Int, _ bytes: [UInt8]) -> [[UInt8]])?

    private let lock = NSLock()
    private var log: [Call] = []
    private var broken: [String] = []
    private var queue: DispatchQueue?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var bufferLength = 0
    private var onReport: ((UInt32, UnsafeBufferPointer<UInt8>) -> Void)?
    private var onRemoval: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var activated = false
    private var cancelled = false
    private var handlerRan = false

    init(maxInputReportSize: Int? = 64) {
        self.maxInputReportSize = maxInputReportSize
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// The output reports sent, in order.
    var reportsSent: [(id: Int, bytes: [UInt8])] {
        calls.compactMap { if case .setReport(let id, let bytes) = $0 { return (id, bytes) } else { return nil } }
    }

    /// IOHIDDevice.h rules the stream broke.
    var violations: [String] {
        lock.lock(); defer { lock.unlock() }
        return broken
    }

    var cancelHandlerHasRun: Bool {
        lock.lock(); defer { lock.unlock() }
        return handlerRan
    }

    private func record(_ call: Call, unless rule: Bool = false, _ violation: @autoclosure () -> String = "") {
        lock.lock(); defer { lock.unlock() }
        log.append(call)
        if rule { broken.append(violation()) }
    }

    func open(seize: Bool) -> IOReturn {
        record(.open(seize: seize), unless: activated || cancelled, "opened after activation")
        return openResult
    }

    func registerInputReportHandler(buffer: UnsafeMutablePointer<UInt8>, length: Int,
                                    _ handler: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void) {
        record(.registerInputReport(length: length), unless: activated, "registered the report callback after activation")
        lock.lock()
        self.buffer = buffer
        bufferLength = length
        onReport = handler
        lock.unlock()
    }

    func registerRemovalHandler(_ handler: @escaping () -> Void) {
        record(.registerRemoval, unless: activated, "registered the removal callback after activation")
        lock.lock(); onRemoval = handler; lock.unlock()
    }

    func setDispatchQueue(_ queue: DispatchQueue) {
        lock.lock()
        let twice = self.queue != nil
        self.queue = queue
        lock.unlock()
        record(.setDispatchQueue, unless: twice || activated, "set the dispatch queue twice or after activation")
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        record(.setCancelHandler, unless: activated, "set the cancel handler after activation")
        lock.lock(); onCancel = handler; lock.unlock()
    }

    func activate() {
        lock.lock()
        let missing = queue == nil || onCancel == nil || onReport == nil
        activated = true
        lock.unlock()
        record(.activate, unless: missing, "activated before the queue, cancel handler and report callback were set")
    }

    func cancel() {
        lock.lock()
        let early = !activated
        let again = cancelled
        cancelled = true
        let hold = holdsCancelHandler
        lock.unlock()
        record(.cancel, unless: early, "cancelled a device that was never activated")
        if !again, !hold { scheduleCancelHandler() }
    }

    /// Runs a held cancel handler; the handler closure stays stored, as nothing says IOKit drops it.
    func runCancelHandler() {
        scheduleCancelHandler()
    }

    private func scheduleCancelHandler() {
        lock.lock()
        let queue = queue
        lock.unlock()
        queue?.async { [self] in
            record(.cancelHandlerRan)
            lock.lock()
            handlerRan = true
            let handler = onCancel
            lock.unlock()
            handler?()
        }
    }

    func setOutputReport(reportID: Int, _ bytes: UnsafeRawBufferPointer) -> IOReturn {
        lock.lock()
        let outside = !activated || cancelled
        let result = setReportResult
        let computer = computer
        lock.unlock()
        let sent = Array(bytes)
        record(.setReport(id: reportID, bytes: sent), unless: outside, "sent a report on a device that isn't active")
        if result == kIOReturnSuccess, let computer {
            for reply in computer(reportID, sent) { deliver(reply) }
        }
        return result
    }

    func close(seize: Bool) -> IOReturn {
        lock.lock()
        let early = cancelled && !handlerRan
        lock.unlock()
        record(.close(seize: seize), unless: early, "closed before the cancel handler ran")
        return kIOReturnSuccess
    }

    /// Copies `report` into the registered buffer and calls the report callback on the dispatch queue, as IOKit does.
    func deliver(_ report: [UInt8], id: UInt32 = 0) {
        lock.lock()
        let queue = queue
        lock.unlock()
        queue?.async { [self] in
            lock.lock()
            let late = handlerRan
            let buffer = buffer
            let length = bufferLength
            let handler = onReport
            if late { broken.append("a report arrived after the cancel handler") }
            lock.unlock()
            guard !late, let buffer, let handler else { return }
            let count = min(report.count, length)
            report.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: count) }
            handler(id, UnsafeBufferPointer(start: buffer, count: count))
        }
    }

    /// The device goes away, as an unplug or a computer leaving USB mode does.
    func remove() {
        lock.lock()
        let queue = queue
        setReportResult = kIOReturnNoDevice
        lock.unlock()
        queue?.async { [self] in
            lock.lock()
            let handler = onRemoval
            lock.unlock()
            handler?()
        }
    }

    /// Waits until everything queued so far on the dispatch queue has run.
    func settle() {
        lock.lock()
        let queue = queue
        lock.unlock()
        queue?.sync {}
    }
}
#endif
