#if os(macOS)
import Foundation
import Clibdivecomputer

public struct DCCustomStreamError: Error, Equatable {
    /// What `dc_custom_open` returned.
    public let status: dc_status_t
}

/// A `dc_custom_open` iostream that routes every operation to a Swift `DCIOStreamBackend`.
public enum DCCustomStream {
    /// Opens an iostream on `backend` (kept alive until `dc_iostream_close`) that drivers see as `transport`; the caller owns it.
    public static func open(backend: DCIOStreamBackend, transport: dc_transport_t, context: OpaquePointer?) throws -> OpaquePointer {
        let retained = Unmanaged.passRetained(Holder(backend))
        var iostream: OpaquePointer?
        var cbs = callbacks
        let status = dc_custom_open(&iostream, context, transport, &cbs, retained.toOpaque())
        guard status == DC_STATUS_SUCCESS, let iostream else {
            retained.release()
            throw DCCustomStreamError(status: status == DC_STATUS_SUCCESS ? DC_STATUS_NOMEMORY : status)
        }
        return iostream
    }

    private final class Holder {
        let backend: DCIOStreamBackend
        init(_ backend: DCIOStreamBackend) { self.backend = backend }
    }

    private static func backend(_ userdata: UnsafeMutableRawPointer?) -> DCIOStreamBackend? {
        userdata.map { Unmanaged<Holder>.fromOpaque($0).takeUnretainedValue().backend }
    }

    // All 15 set: custom.c answers SUCCESS for a NULL callback without calling anything.
    static let callbacks: dc_custom_cbs_t = {
        var cbs = dc_custom_cbs_t()
        cbs.set_timeout = { userdata, timeout in
            backend(userdata)?.setTimeout(timeout) ?? DC_STATUS_INVALIDARGS
        }
        cbs.set_break = { userdata, value in
            backend(userdata)?.setBreak(value) ?? DC_STATUS_INVALIDARGS
        }
        cbs.set_dtr = { userdata, value in
            backend(userdata)?.setDTR(value) ?? DC_STATUS_INVALIDARGS
        }
        cbs.set_rts = { userdata, value in
            backend(userdata)?.setRTS(value) ?? DC_STATUS_INVALIDARGS
        }
        cbs.get_lines = { userdata, value in
            guard let backend = backend(userdata) else { return DC_STATUS_INVALIDARGS }
            var lines: UInt32 = 0
            let status = backend.getLines(&lines)
            value?.pointee = lines
            return status
        }
        cbs.get_available = { userdata, value in
            guard let backend = backend(userdata) else { return DC_STATUS_INVALIDARGS }
            var available = 0
            let status = backend.getAvailable(&available)
            value?.pointee = available
            return status
        }
        cbs.configure = { userdata, baudrate, databits, parity, stopbits, flowcontrol in
            backend(userdata)?.configure(DCSerialConfiguration(baudrate: baudrate, databits: databits, parity: parity,
                                                               stopbits: stopbits, flowcontrol: flowcontrol))
                ?? DC_STATUS_INVALIDARGS
        }
        cbs.poll = { userdata, timeout in
            backend(userdata)?.poll(timeout) ?? DC_STATUS_INVALIDARGS
        }
        cbs.read = { userdata, data, size, actual in
            actual?.pointee = 0
            guard let backend = backend(userdata), data != nil || size == 0 else { return DC_STATUS_INVALIDARGS }
            var count = 0
            let status = backend.read(into: UnsafeMutableRawBufferPointer(start: data, count: size), actual: &count)
            actual?.pointee = min(max(count, 0), size)
            return status
        }
        cbs.write = { userdata, data, size, actual in
            actual?.pointee = 0
            guard let backend = backend(userdata), data != nil || size == 0 else { return DC_STATUS_INVALIDARGS }
            var count = 0
            let status = backend.write(UnsafeRawBufferPointer(start: data, count: size), actual: &count)
            actual?.pointee = min(max(count, 0), size)
            return status
        }
        cbs.ioctl = { userdata, request, data, size in
            guard let backend = backend(userdata), data != nil || size == 0 else { return DC_STATUS_INVALIDARGS }
            return backend.ioctl(request, UnsafeMutableRawBufferPointer(start: data, count: size))
        }
        cbs.flush = { userdata in
            backend(userdata)?.flush() ?? DC_STATUS_INVALIDARGS
        }
        cbs.purge = { userdata, direction in
            backend(userdata)?.purge(direction) ?? DC_STATUS_INVALIDARGS
        }
        cbs.sleep = { userdata, milliseconds in
            backend(userdata)?.sleep(milliseconds) ?? DC_STATUS_INVALIDARGS
        }
        cbs.close = { userdata in
            guard let userdata else { return DC_STATUS_INVALIDARGS }
            let holder = Unmanaged<Holder>.fromOpaque(userdata)
            let status = holder.takeUnretainedValue().backend.close()
            holder.release()
            return status
        }
        return cbs
    }()
}
#endif
