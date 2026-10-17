#if os(macOS)
import Foundation
import Clibdivecomputer

/// The 15 operations of a libdivecomputer iostream, named as in `dc_custom_cbs_t`.
public enum DCIOStreamOperation: String, CaseIterable, Codable, Sendable {
    case setTimeout = "set_timeout"
    case setBreak = "set_break"
    case setDTR = "set_dtr"
    case setRTS = "set_rts"
    case getLines = "get_lines"
    case getAvailable = "get_available"
    case configure
    case poll
    case read
    case write
    case ioctl
    case flush
    case purge
    case sleep
    case close
}

/// The line settings `dc_iostream_configure` passes.
public struct DCSerialConfiguration: Equatable, Sendable {
    public var baudrate: UInt32
    public var databits: UInt32
    public var parity: dc_parity_t
    public var stopbits: dc_stopbits_t
    public var flowcontrol: dc_flowcontrol_t

    public init(baudrate: UInt32, databits: UInt32 = 8, parity: dc_parity_t = DC_PARITY_NONE,
                stopbits: dc_stopbits_t = DC_STOPBITS_ONE, flowcontrol: dc_flowcontrol_t = DC_FLOWCONTROL_NONE) {
        self.baudrate = baudrate
        self.databits = databits
        self.parity = parity
        self.stopbits = stopbits
        self.flowcontrol = flowcontrol
    }
}

/// A Swift iostream behind `DCCustomStream`, called on libdivecomputer's thread; every operation is required since `dc_custom_open` turns a missing one into a silent SUCCESS (a skipped DTR, RTS or sleep).
public protocol DCIOStreamBackend: AnyObject {
    func setTimeout(_ timeout: Int32) -> dc_status_t
    func setBreak(_ value: UInt32) -> dc_status_t
    func setDTR(_ value: UInt32) -> dc_status_t
    func setRTS(_ value: UInt32) -> dc_status_t
    func getLines(_ value: inout UInt32) -> dc_status_t
    func getAvailable(_ value: inout Int) -> dc_status_t
    func configure(_ configuration: DCSerialConfiguration) -> dc_status_t
    func poll(_ timeout: Int32) -> dc_status_t
    /// `actual` starts at 0; a timeout keeps the partial count.
    func read(into buffer: UnsafeMutableRawBufferPointer, actual: inout Int) -> dc_status_t
    func write(_ data: UnsafeRawBufferPointer, actual: inout Int) -> dc_status_t
    /// `data` is the request's buffer: read it for a write request, fill it for a read request.
    func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t
    func flush() -> dc_status_t
    func purge(_ direction: dc_direction_t) -> dc_status_t
    func sleep(_ milliseconds: UInt32) -> dc_status_t
    /// Called once, by `dc_iostream_close`; the stream then lets go of the backend.
    func close() -> dc_status_t
}

/// A backend standing in for libdivecomputer's USB HID transport: what `usbhid.c` leaves out answers as it does there, so a backend implements only `setTimeout`, `read`, `write` and `close`.
public protocol DCUSBHIDStreamBackend: DCIOStreamBackend {}

public extension DCUSBHIDStreamBackend {
    // usbhid.c's vtable has no entry for these, and dc_iostream_* returns SUCCESS for a missing entry.
    func setBreak(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setDTR(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setRTS(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func getLines(_ value: inout UInt32) -> dc_status_t { value = 0; return DC_STATUS_SUCCESS }
    func getAvailable(_ value: inout Int) -> dc_status_t { value = 0; return DC_STATUS_SUCCESS }
    func configure(_ configuration: DCSerialConfiguration) -> dc_status_t { DC_STATUS_SUCCESS }
    func flush() -> dc_status_t { DC_STATUS_SUCCESS }
    func purge(_ direction: dc_direction_t) -> dc_status_t { DC_STATUS_SUCCESS }
    // No sleep entry either, so upstream returns at once instead of sleeping.
    func sleep(_ milliseconds: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func poll(_ timeout: Int32) -> dc_status_t { DC_STATUS_UNSUPPORTED }
    func ioctl(_ request: UInt32, _ data: UnsafeMutableRawBufferPointer) -> dc_status_t { DC_STATUS_UNSUPPORTED }
}

/// A backend standing in for libdivecomputer's USB (bulk) transport, as `usb.c` answers; a backend implements `setTimeout`, `read`, `write`, `ioctl` (control transfers) and `close`.
public protocol DCUSBStreamBackend: DCIOStreamBackend {}

public extension DCUSBStreamBackend {
    // usb.c's vtable has no entry for these, and dc_iostream_* returns SUCCESS for a missing entry.
    func setBreak(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setDTR(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func setRTS(_ value: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func getLines(_ value: inout UInt32) -> dc_status_t { value = 0; return DC_STATUS_SUCCESS }
    func getAvailable(_ value: inout Int) -> dc_status_t { value = 0; return DC_STATUS_SUCCESS }
    func configure(_ configuration: DCSerialConfiguration) -> dc_status_t { DC_STATUS_SUCCESS }
    func flush() -> dc_status_t { DC_STATUS_SUCCESS }
    func purge(_ direction: dc_direction_t) -> dc_status_t { DC_STATUS_SUCCESS }
    func sleep(_ milliseconds: UInt32) -> dc_status_t { DC_STATUS_SUCCESS }
    func poll(_ timeout: Int32) -> dc_status_t { DC_STATUS_UNSUPPORTED }
}
#endif
