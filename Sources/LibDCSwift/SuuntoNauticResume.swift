import Foundation
import Clibdivecomputer
import LibDCBridge

/// Carries a Suunto Nautic/Ocean dive's download over a dropped link: the driver keeps
/// the `/Data` received before the link went in a buffer per watch (up to 4 dives), and
/// the next download of that dive, on any later connection, reads only the rest
/// (`suunto_nautic_device_set_resume`). `DeviceConfiguration.openBLEDevice` attaches
/// the shared store to every Nautic/Ocean device it opens.
public final class SuuntoNauticResume {
    public static let shared = SuuntoNauticResume()

    private let lock = NSLock()
    /// One driver buffer per watch. Open devices point at them, so they live as long as the store.
    private var buffers: [String: OpaquePointer] = [:]

    public init() {}

    deinit {
        buffers.values.forEach { dc_buffer_free($0) }
    }

    /// Hands `watch`'s buffer to a device just opened for it. False for a device of another family.
    @discardableResult
    public func attach(_ device: OpaquePointer, watch: String) -> Bool {
        guard dc_device_get_type(device) == DC_FAMILY_SUUNTO_NAUTIC else { return false }
        lock.lock()
        let buffer = buffers[watch] ?? dc_buffer_new(0)
        if let buffer { buffers[watch] = buffer }
        lock.unlock()
        guard let buffer else { return false }
        return suunto_nautic_device_set_resume(device, buffer) == DC_STATUS_SUCCESS
    }

    /// The `/Data` bytes of dive `id` that a download on `device` carries on from; nil when none
    /// are kept. Call it on the queue that runs the downloads, never during one.
    public static func resumableBytes(of id: UInt32, on device: OpaquePointer) -> Int? {
        var size: UInt32 = 0
        guard suunto_nautic_device_get_resume(device, id, &size) == DC_STATUS_SUCCESS, size > 0 else { return nil }
        return Int(size)
    }
}
