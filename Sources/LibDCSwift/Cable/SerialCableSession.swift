#if os(macOS)
import Foundation
import Clibdivecomputer
import LibDCBridge

extension DiveComputerSession {
    /// Where cable opens block: libdivecomputer's open talks to the computer, for up to the driver's timeout.
    static let cableQueue = DispatchQueue(label: "com.libdcswift.cable")

    /// Opens `model` on a serial endpoint through a `TapStream`, throwing `CableError`; with `discovery`, an unplug cancels the session.
    public static func open(
        _ endpoint: CableEndpoint,
        model: DCModel,
        discovery: CableDiscovering? = nil,
        recorder: DCStreamRecorder? = nil,
        deviceStorage: DeviceStorage = .shared,
        lease: DiveComputerSessionLease = .shared
    ) async throws -> DiveComputerSession {
        let cancellation = CableOpenCancellation()
        let request = SerialOpenRequest(endpoint: endpoint, model: model, discovery: discovery, recorder: recorder,
                                        deviceStorage: deviceStorage, lease: lease, cancellation: cancellation)
        let session = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DiveComputerSession, Error>) in
                cableQueue.async {
                    continuation.resume(with: Result {
                        try openSerial(request.endpoint, model: request.model, discovery: request.discovery,
                                       recorder: request.recorder, deviceStorage: request.deviceStorage,
                                       lease: request.lease, cancellation: request.cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try handOver(session, cancellation: cancellation)
    }

    /// A cancel that landed after the open's last check has already poisoned the session's tap, so it is closed, not returned.
    static func handOver(_ session: DiveComputerSession, cancellation: CableOpenCancellation) throws -> DiveComputerSession {
        guard cancellation.isCancelled || Task.isCancelled else { return session }
        session.close()
        throw CableError.cancelled
    }

    static func openSerial(
        _ endpoint: CableEndpoint,
        model: DCModel,
        discovery: CableDiscovering?,
        recorder: DCStreamRecorder?,
        deviceStorage: DeviceStorage,
        lease: DiveComputerSessionLease,
        cancellation: CableOpenCancellation,
        claims: SerialPortClaims = .shared
    ) throws -> DiveComputerSession {
        guard endpoint.transport == .serial else { throw CableError.unsupportedTransport(endpoint.transport) }
        guard endpoint.status != .driverMissing, let path = endpoint.calloutPath, let locator = endpoint.locator else {
            throw CableError.driverMissing
        }
        guard model.transports.contains(.serial) else { throw CableError.unsupportedTransport(.serial) }
        guard !cancellation.isCancelled else { throw CableError.cancelled }
        guard lease.tryAcquire() else { throw CableError.sessionInProgress }
        var leaseHeld = true
        defer { if leaseHeld { lease.release() } }

        if let refused = SerialPortPreflight.check(path) { throw refused }

        var context: OpaquePointer?
        guard dc_context_new(&context) == DC_STATUS_SUCCESS, let context else { throw CableError.protocolError(DC_STATUS_NOMEMORY) }
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.context = context
        let factory = SerialTapFactory(recorder: recorder, cancellation: cancellation)
        let status = withExtendedLifetime(factory) {
            open_serial_device(data, path, model.dcFamily, model.model, SerialTapFactory.wrap,
                               Unmanaged.passUnretained(factory).toOpaque())
        }
        guard status == DC_STATUS_SUCCESS else {
            data.deinitialize(count: 1)
            data.deallocate()
            guard factory.wrapCalled else { throw CableError.portOpenFailed(status) }
            throw CableError.deviceFailed(status, family: model.family, portPresent: access(path, F_OK) == 0)
        }

        let session = openedCable(devicePtr: data, displayName: model.name, storageKey: locator.locatorKey,
                                  locator: locator, deviceStorage: deviceStorage, lease: lease)
        leaseHeld = false
        factory.attach(session)
        claims.claim(path)
        session.onTeardown { claims.release(path) }
        discovery?.cancelOnRemoval(of: endpoint.id, session: session)
        if session.wasUnplugged {
            session.close()
            throw CableError.unplugged
        }
        if cancellation.isCancelled {
            session.close()
            throw CableError.cancelled
        }
        return session
    }
}

/// An open's arguments, handed to the cable queue; the open is their only user until it returns.
struct SerialOpenRequest: @unchecked Sendable {
    let endpoint: CableEndpoint
    let model: DCModel
    let discovery: CableDiscovering?
    let recorder: DCStreamRecorder?
    let deviceStorage: DeviceStorage
    let lease: DiveComputerSessionLease
    let cancellation: CableOpenCancellation
}

/// Set from the opening task's cancellation handler, read on the cable queue.
final class CableOpenCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

/// Builds the `TapStream` around the port `open_serial_device` opens.
final class SerialTapFactory {
    let recorder: DCStreamRecorder?
    let cancellation: CableOpenCancellation
    private(set) var wrapCalled = false
    private(set) var tap: TapStream?

    init(recorder: DCStreamRecorder?, cancellation: CableOpenCancellation) {
        self.recorder = recorder
        self.cancellation = cancellation
    }

    static let wrap: libdc_iostream_wrap_t = { context, inner, userdata in
        guard let userdata, let inner else { return nil }
        let factory = Unmanaged<SerialTapFactory>.fromOpaque(userdata).takeUnretainedValue()
        factory.wrapCalled = true
        let cancellation = factory.cancellation
        let tap = TapStream(inner: inner, recorder: factory.recorder, isCancelled: { cancellation.isCancelled })
        guard let stream = try? DCCustomStream.open(backend: tap, transport: tap.transport, context: context) else {
            // Dropping the tap closes inner.
            return nil
        }
        factory.tap = tap
        return stream
    }

    /// From here the tap also gives up once the session is cancelled, closing (an owned cable session cancels itself first) or released.
    func attach(_ session: DiveComputerSession) {
        let cancellation = cancellation
        tap?.setCancellation { [weak session] in cancellation.isCancelled || (session?.isCancelled ?? true) }
    }
}

/// Opens and closes the port as serial_posix will, since dc_serial_open reports busy and not permitted alike (NOACCESS).
enum SerialPortPreflight {
    static func check(_ path: String) -> CableError? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return CableError(openErrno: errno) }
        defer { Darwin.close(fd) }
        if ioctl(fd, TIOCEXCL) != 0, errno == EBUSY { return .busy }
        return nil
    }
}
#endif
