#if os(macOS)
import Foundation
import IOKit
import Clibdivecomputer

/// libdivecomputer's USB HID transport on an IOHIDDevice, answering each operation as usbhid.c's hidapi build does (see Docs/MACOS_USB_HID.md for the lifecycle).
public final class HIDStream: DCUSBHIDStreamBackend {
    public enum State: Equatable, Sendable {
        case created
        /// `start()` is opening the device and registering its callbacks.
        case opened
        case active
        /// IOHIDDeviceCancel was called and the cancel handler hasn't run.
        case cancelling
        case closed
    }

    /// hidapi's macOS backend keeps this many unread reports and drops the oldest.
    public static let maxQueuedReports = 30
    /// The longest a blocked read waits between cancel checks.
    public static let cancelCheckMilliseconds: Int32 = TapStream.cancelCheckMilliseconds
    /// libdivecomputer's HID drivers read 64-byte reports, so the buffer is never smaller even when the device doesn't say.
    static let minimumReportBuffer = 64

    public let seize: Bool
    /// How long `close()` waits for the cancel handler; the device and buffer stay alive past it until the handler runs.
    let cancelHandlerTimeout: DispatchTimeInterval
    private let device: HIDDeviceIO
    private let queue = DispatchQueue(label: "com.libdcswift.hid")
    private let inbox: HIDReportInbox
    private let cancelHandlerRan = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var currentState = State.created
    // hidapi's path starts blocking (-1), as usbhid.c sets it at open.
    private var timeout: Int32 = -1
    private var cancelCheck: (() -> Bool)?
    private var removalHandler: (() -> Void)?

    /// Seizes the device by default, as hidapi does on macOS: an app that has it open shared is cut off, and one that has seized it makes the open fail with kIOReturnExclusiveAccess.
    public convenience init(device: HIDDeviceIO, seize: Bool = true) {
        self.init(device: device, seize: seize, cancelHandlerTimeout: .seconds(2))
    }

    init(device: HIDDeviceIO, seize: Bool, cancelHandlerTimeout: DispatchTimeInterval) {
        self.device = device
        self.seize = seize
        self.cancelHandlerTimeout = cancelHandlerTimeout
        inbox = HIDReportInbox(capacity: max(device.maxInputReportSize ?? 0, Self.minimumReportBuffer))
    }

    deinit {
        lock.lock()
        let active = currentState == .active
        currentState = .closed
        lock.unlock()
        if active { device.cancel() }
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    /// The device went away; reports that arrived before still read.
    public var isRemoved: Bool { inbox.isRemoved }

    var reportInbox: HIDReportInbox { inbox }

    /// Opens the device and activates it, once, returning IOHIDDeviceOpen's result (kIOReturnError for a second start); after a failure nothing else was called and the stream is closed.
    @discardableResult
    public func start() -> IOReturn {
        lock.lock()
        guard currentState == .created else {
            lock.unlock()
            return kIOReturnError
        }
        currentState = .opened
        lock.unlock()
        let opened = device.open(seize: seize)
        guard opened == kIOReturnSuccess else {
            lock.lock()
            currentState = .closed
            lock.unlock()
            return opened
        }

        let inbox = inbox
        // Weak: the stream and the cancel handler own the inbox, so it goes once neither needs it.
        device.registerInputReportHandler(buffer: inbox.buffer, length: inbox.capacity) { [weak inbox] _, report in
            inbox?.deliver(report)
        }
        device.registerRemovalHandler { [weak self, weak inbox] in
            inbox?.markRemoved()
            self?.deviceRemoved()
        }
        device.setDispatchQueue(queue)
        // The handler owns what IOKit may still touch until it runs: the device and the buffer reports are copied into.
        var owned: (device: HIDDeviceIO, inbox: HIDReportInbox)? = (device, inbox)
        let seize = seize
        let ran = cancelHandlerRan
        device.setCancelHandler {
            guard let resources = owned else { return }
            owned = nil
            // hidapi never closes an unplugged device.
            if !resources.inbox.isRemoved {
                let closed = resources.device.close(seize: seize)
                if closed != kIOReturnSuccess { logWarning(String(format: "IOHIDDeviceClose failed: 0x%08x", closed)) }
            }
            ran.signal()
        }
        device.activate()

        lock.lock()
        currentState = .active
        lock.unlock()
        return kIOReturnSuccess
    }

    /// While `isCancelled` returns true, reads give up with `DC_STATUS_CANCELLED`; writes still go out, so a driver's quit command does.
    public func setCancellation(_ isCancelled: (() -> Bool)?) {
        lock.lock(); defer { lock.unlock() }
        cancelCheck = isCancelled
    }

    /// Runs on the stream's queue when the device is removed, or at once if it already has been.
    public func setRemovalHandler(_ handler: (() -> Void)?) {
        lock.lock()
        removalHandler = handler
        lock.unlock()
        if inbox.isRemoved { handler?() }
    }

    private var cancelled: Bool {
        lock.lock()
        let check = cancelCheck
        lock.unlock()
        return check?() ?? false
    }

    private func deviceRemoved() {
        lock.lock()
        let handler = removalHandler
        lock.unlock()
        handler?()
    }

    private var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentState == .active
    }

    // MARK: - DCUSBHIDStreamBackend

    // hidapi's path: negative blocks, 0 polls, N waits N ms.
    public func setTimeout(_ timeout: Int32) -> dc_status_t {
        lock.lock(); defer { lock.unlock() }
        self.timeout = timeout < 0 ? -1 : timeout
        return DC_STATUS_SUCCESS
    }

    /// One report per call, report-ID byte included as IOKit delivered it, cut to the buffer; a timeout is SUCCESS with nothing read, as hid_read_timeout's 0.
    public func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t {
        actual = 0
        lock.lock()
        let active = currentState == .active
        let timeout = self.timeout
        lock.unlock()
        guard active else { return DC_STATUS_IO }
        let deadline = timeout > 0 ? DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000 : nil
        while true {
            if cancelled { return DC_STATUS_CANCELLED }
            let wait: Int32
            if timeout == 0 {
                wait = 0
            } else if let deadline {
                wait = min(Self.cancelCheckMilliseconds, Self.millisecondsLeft(deadline))
            } else {
                wait = Self.cancelCheckMilliseconds
            }
            switch inbox.take(into: buffer, waitingAtMost: wait) {
            case .report(let count):
                actual = count
                return DC_STATUS_SUCCESS
            case .removed:
                return DC_STATUS_IO
            case .empty:
                break
            }
            if timeout == 0 { return DC_STATUS_SUCCESS }
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { return DC_STATUS_SUCCESS }
        }
    }

    /// As hidapi's hid_write: a zero report ID isn't sent, any other is sent as the report's first byte, and `actual` is the whole size either way.
    public func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t {
        actual = 0
        // usbhid.c sends nothing for an empty write.
        guard !data.isEmpty else { return DC_STATUS_SUCCESS }
        guard isActive, !inbox.isRemoved else { return DC_STATUS_IO }
        let reportID = Int(data[0])
        let result = reportID == 0
            ? device.setOutputReport(reportID: 0, UnsafeRawBufferPointer(rebasing: data[1...]))
            : device.setOutputReport(reportID: reportID, data)
        guard result == kIOReturnSuccess else {
            logWarning(String(format: "IOHIDDeviceSetReport failed: 0x%08x", result))
            return DC_STATUS_IO
        }
        actual = data.count
        return DC_STATUS_SUCCESS
    }

    /// Cancels the device and waits for the cancel handler, which closes it (unless it was removed) and only then releases it and the report buffer.
    public func close() -> dc_status_t {
        lock.lock()
        let wasActive = currentState == .active
        if wasActive {
            currentState = .cancelling
        } else if currentState == .created {
            currentState = .closed
        }
        lock.unlock()
        guard wasActive else { return DC_STATUS_SUCCESS }
        device.cancel()
        if cancelHandlerRan.wait(timeout: .now() + cancelHandlerTimeout) == .timedOut {
            logWarning("The HID device's cancel handler hasn't run; it closes and releases the device when it does")
        }
        lock.lock()
        currentState = .closed
        lock.unlock()
        return DC_STATUS_SUCCESS
    }

    /// Rounded up, so the slice that reaches the deadline doesn't spin on 0.
    private static func millisecondsLeft(_ deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0 }
        return Int32(clamping: (deadline - now + 999_999) / 1_000_000)
    }
}

/// The buffer IOKit copies input reports into and the reports not read yet, owned by the cancel handler once the device is active.
final class HIDReportInbox {
    enum Take: Equatable {
        case report(Int)
        case removed
        case empty
    }

    let capacity: Int
    let buffer: UnsafeMutablePointer<UInt8>
    private let condition = NSCondition()
    private var reports: [[UInt8]] = []
    private var removed = false
    private var droppedCount = 0

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    var isRemoved: Bool {
        condition.lock(); defer { condition.unlock() }
        return removed
    }

    var queuedCount: Int {
        condition.lock(); defer { condition.unlock() }
        return reports.count
    }

    var dropped: Int {
        condition.lock(); defer { condition.unlock() }
        return droppedCount
    }

    func deliver(_ report: UnsafeBufferPointer<UInt8>) {
        let bytes = Array(report.prefix(capacity))
        condition.lock()
        if reports.count >= HIDStream.maxQueuedReports {
            reports.removeFirst()
            droppedCount += 1
            logWarning("Dropped the oldest unread HID report: more than \(HIDStream.maxQueuedReports) are waiting")
        }
        reports.append(bytes)
        condition.signal()
        condition.unlock()
    }

    func markRemoved() {
        condition.lock()
        removed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The oldest report, cut to `buffer`, waiting once for up to `milliseconds` when there is none; removal reads after the reports that came before it.
    func take(into buffer: UnsafeMutableRawBufferPointer, waitingAtMost milliseconds: Int32) -> Take {
        condition.lock()
        defer { condition.unlock() }
        if reports.isEmpty, !removed, milliseconds > 0 {
            _ = condition.wait(until: Date(timeIntervalSinceNow: Double(milliseconds) / 1000))
        }
        if !reports.isEmpty {
            let report = reports.removeFirst()
            let count = min(report.count, buffer.count)
            if count > 0 { buffer.copyBytes(from: report[0..<count]) }
            return .report(count)
        }
        return removed ? .removed : .empty
    }
}
#endif
