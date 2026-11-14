#if os(macOS)
import Foundation

/// Where a raw USB dive computer is read: its interface and bulk endpoints, as usb.c's `g_usb_config` lists them.
public struct USBInterfaceLayout: Hashable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let interfaceNumber: UInt8
    /// The bulk IN endpoint's address, direction bit set.
    public let endpointIn: UInt8
    public let endpointOut: UInt8

    public init(vendorID: UInt16, productID: UInt16, interfaceNumber: UInt8, endpointIn: UInt8, endpointOut: UInt8) {
        self.vendorID = vendorID
        self.productID = productID
        self.interfaceNumber = interfaceNumber
        self.endpointIn = endpointIn
        self.endpointOut = endpointOut
    }
}

/// The dive computers libdivecomputer reads over raw USB (`DC_TRANSPORT_USB`): the Atomic Aquatics Cobalt and Cobalt 2, which share 0471:0888.
public enum USBComputers {
    public static let all: [USBInterfaceLayout] = [
        USBInterfaceLayout(vendorID: 0x0471, productID: 0x0888, interfaceNumber: 0, endpointIn: 0x82, endpointOut: 0x02),
    ]

    public static func layout(vendorID: UInt16, productID: UInt16) -> USBInterfaceLayout? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// The USB vendors in `all`, for matching devices that come and go.
    static var vendorIDs: Set<UInt16> { Set(all.map(\.vendorID)) }
}
#endif
