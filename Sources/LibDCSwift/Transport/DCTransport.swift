import Foundation
import Clibdivecomputer
import LibDCBridge

/// How a host reaches a dive computer. The raw values are storage strings and never change.
public enum DCTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case ble
    /// A USB-serial cable or RS-232 adapter.
    case serial
    case usbHID = "usbhid"
    case usb
    /// A paired classic-Bluetooth computer reached through the serial port macOS makes for it.
    case classicBTSerial = "btserial"

    /// The iostream transport a download opens with; a paired classic-Bluetooth port is a serial port.
    public var dcValue: dc_transport_t {
        switch self {
        case .ble: return DC_TRANSPORT_BLE
        case .serial, .classicBTSerial: return DC_TRANSPORT_SERIAL
        case .usbHID: return DC_TRANSPORT_USBHID
        case .usb: return DC_TRANSPORT_USB
        }
    }

    /// `DC_TRANSPORT_SERIAL` is `.serial`; nil for IrDA, RFCOMM sockets and masks of several transports.
    public init?(dcValue: dc_transport_t) {
        switch dcValue {
        case DC_TRANSPORT_BLE: self = .ble
        case DC_TRANSPORT_SERIAL: self = .serial
        case DC_TRANSPORT_USBHID: self = .usbHID
        case DC_TRANSPORT_USB: self = .usb
        default: return nil
        }
    }
}

/// Cable transports this platform can download over.
public enum CableSupport {
    /// Serial, USB HID and raw USB on macOS; empty on iOS, which reaches computers over BLE only.
    public static var transports: Set<DCTransport> {
        let mask = libdc_cable_transports()
        return Set([DCTransport.serial, .usbHID, .usb].filter { mask & $0.dcValue.rawValue != 0 })
    }
}
