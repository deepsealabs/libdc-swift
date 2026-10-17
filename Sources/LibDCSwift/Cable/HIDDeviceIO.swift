#if os(macOS)
import Foundation
import IOKit
import IOKit.hid

/// The IOHIDDevice calls `HIDStream` makes, named after them; tests pass a fake that checks their order.
public protocol HIDDeviceIO: AnyObject {
    /// kIOHIDMaxInputReportSizeKey; nil when the device doesn't say.
    var maxInputReportSize: Int? { get }
    /// IOHIDDeviceOpen with kIOHIDOptionsTypeSeizeDevice when `seize`, else kIOHIDOptionsTypeNone.
    func open(seize: Bool) -> IOReturn
    /// IOHIDDeviceRegisterInputReportCallback: each input report is copied into `buffer`, then `handler` sees it there, on the dispatch queue.
    func registerInputReportHandler(buffer: UnsafeMutablePointer<UInt8>, length: Int,
                                    _ handler: @escaping (_ reportID: UInt32, _ report: UnsafeBufferPointer<UInt8>) -> Void)
    func registerRemovalHandler(_ handler: @escaping () -> Void)
    /// IOHIDDeviceSetDispatchQueue, once.
    func setDispatchQueue(_ queue: DispatchQueue)
    /// IOHIDDeviceSetCancelHandler: runs on the dispatch queue after `cancel()`, once every pending callback has.
    func setCancelHandler(_ handler: @escaping () -> Void)
    func activate()
    func cancel()
    /// A synchronous IOHIDDeviceSetReport(kIOHIDReportTypeOutput), as hidapi's hid_write sends it.
    func setOutputReport(reportID: Int, _ bytes: UnsafeRawBufferPointer) -> IOReturn
    /// IOHIDDeviceClose with the options `open` used.
    func close(seize: Bool) -> IOReturn
}

/// The dive computer vendors libdivecomputer's USB HID families use; the only ones a HID match ever names.
public enum HIDVendors {
    /// Suunto, Scubapro, and Keil (whose VID the Aladin Square uses; its other PIDs are debug probes).
    public static let vendorIDs: [UInt16] = [0x1493, 0x2e6c, 0xc251]
    /// kHIDPage_GenericDesktop: keyboards and mice, whose open can raise the Input Monitoring prompt.
    static let genericDesktopUsagePage: UInt32 = 0x01
}

/// The IOHIDDevice for one registry entry. It is only ever opened per device, never through IOHIDManagerOpen.
public final class IOKitHIDDevice: HIDDeviceIO {
    private final class Handlers {
        var report: ((UInt32, UnsafeBufferPointer<UInt8>) -> Void)?
        var removal: (() -> Void)?
    }

    private let device: IOHIDDevice
    private let handlers = Handlers()

    public init(device: IOHIDDevice) {
        self.device = device
    }

    /// The device with this registry entry ID, or nil once it is gone.
    public convenience init?(registryID: UInt64) {
        guard let matching = IORegistryEntryIDMatching(registryID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
        self.init(device: device)
    }

    public var maxInputReportSize: Int? {
        (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
    }

    private static func options(seize: Bool) -> IOOptionBits {
        IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
    }

    public func open(seize: Bool) -> IOReturn {
        IOHIDDeviceOpen(device, Self.options(seize: seize))
    }

    // The context is `handlers`, which lives as long as this object; HIDStream keeps it until the cancel handler has run.
    public func registerInputReportHandler(buffer: UnsafeMutablePointer<UInt8>, length: Int,
                                           _ handler: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void) {
        handlers.report = handler
        IOHIDDeviceRegisterInputReportCallback(device, buffer, length, { context, _, _, _, reportID, report, reportLength in
            guard let context else { return }
            let handlers = Unmanaged<Handlers>.fromOpaque(context).takeUnretainedValue()
            handlers.report?(reportID, UnsafeBufferPointer(start: report, count: max(reportLength, 0)))
        }, Unmanaged.passUnretained(handlers).toOpaque())
    }

    public func registerRemovalHandler(_ handler: @escaping () -> Void) {
        handlers.removal = handler
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<Handlers>.fromOpaque(context).takeUnretainedValue().removal?()
        }, Unmanaged.passUnretained(handlers).toOpaque())
    }

    public func setDispatchQueue(_ queue: DispatchQueue) {
        IOHIDDeviceSetDispatchQueue(device, queue)
    }

    public func setCancelHandler(_ handler: @escaping () -> Void) {
        IOHIDDeviceSetCancelHandler(device, handler)
    }

    public func activate() {
        IOHIDDeviceActivate(device)
    }

    public func cancel() {
        IOHIDDeviceCancel(device)
    }

    public func setOutputReport(reportID: Int, _ bytes: UnsafeRawBufferPointer) -> IOReturn {
        if let base = bytes.baseAddress, bytes.count > 0 {
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID),
                                        base.assumingMemoryBound(to: UInt8.self), bytes.count)
        }
        // An empty report (a lone zero report ID) still needs a valid pointer.
        var empty: UInt8 = 0
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), &empty, 0)
    }

    public func close(seize: Bool) -> IOReturn {
        IOHIDDeviceClose(device, Self.options(seize: seize))
    }
}
#endif
