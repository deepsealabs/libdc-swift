#if os(macOS)
import Foundation
import Clibdivecomputer
import LibDCBridge

extension DiveComputerSession {
    /// Where cable opens block: libdivecomputer's open talks to the computer, for up to the driver's timeout. Concurrent, so an
    /// open(2) stuck on a CDC-ACM node after wake (Apple FB6153687) holds only its own open; the lease still allows one session.
    static let cableQueue = DispatchQueue(label: "com.libdcswift.cable", attributes: .concurrent)

    /// Opens `model` on a serial, USB HID or raw USB endpoint through a `TapStream`, throwing `CableError`; with `discovery`, an unplug cancels the session.
    public static func open(
        _ endpoint: CableEndpoint,
        model: DCModel,
        discovery: CableDiscovering? = nil,
        recorder: DCStreamRecorder? = nil,
        deviceStorage: DeviceStorage = .shared,
        lease: DiveComputerSessionLease = .shared
    ) async throws -> DiveComputerSession {
        try await open(endpoint, model: model, discovery: discovery, recorder: recorder, deviceStorage: deviceStorage,
                       lease: lease, hidDevice: IOKitHIDDevice.make, usbDevice: IOKitUSBDevice.make)
    }

    /// `hidDevice` makes the IOHIDDevice a USB HID endpoint names, and `usbDevice` opens a raw USB endpoint's interface; tests pass fakes.
    static func open(
        _ endpoint: CableEndpoint,
        model: DCModel,
        discovery: CableDiscovering?,
        recorder: DCStreamRecorder?,
        deviceStorage: DeviceStorage,
        lease: DiveComputerSessionLease,
        hidDevice: @escaping HIDDeviceFactory,
        usbDevice: @escaping USBDeviceFactory = IOKitUSBDevice.make
    ) async throws -> DiveComputerSession {
        let cancellation = CableOpenCancellation()
        let request = CableOpenRequest(endpoint: endpoint, model: model, discovery: discovery, recorder: recorder,
                                       deviceStorage: deviceStorage, lease: lease, cancellation: cancellation,
                                       hidDevice: hidDevice, usbDevice: usbDevice)
        let session = try await runCableOpen(cancellation: cancellation) { try openCable(request) }
        return try handOver(session, cancellation: cancellation)
    }

    /// Runs `open` on the cable queue. A cancel throws `CableError.cancelled` at once, even while `open` is blocked (in open(2), say);
    /// `open` then finishes on its own and a session it returns is closed. A serial open takes the lease only once its port is open,
    /// so one stuck in open(2) blocks only another open of the same port.
    static func runCableOpen(cancellation: CableOpenCancellation,
                             _ open: @escaping @Sendable () throws -> DiveComputerSession) async throws -> DiveComputerSession {
        let gate = CableOpenGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DiveComputerSession, Error>) in
                guard gate.install(continuation) else { return }
                cableQueue.async {
                    let result = Result { try open() }
                    if !gate.finish(result), case .success(let late) = result { late.close() }
                }
            }
        } onCancel: {
            cancellation.cancel()
            gate.finish(.failure(CableError.cancelled))
        }
    }

    static func openCable(_ request: CableOpenRequest) throws -> DiveComputerSession {
        switch request.endpoint.transport {
        case .usbHID:
            return try openHID(request.endpoint, model: request.model, discovery: request.discovery, recorder: request.recorder,
                               deviceStorage: request.deviceStorage, lease: request.lease,
                               cancellation: request.cancellation, makeDevice: request.hidDevice)
        case .usb:
            return try openUSB(request.endpoint, model: request.model, discovery: request.discovery, recorder: request.recorder,
                               deviceStorage: request.deviceStorage, lease: request.lease,
                               cancellation: request.cancellation, makeDevice: request.usbDevice)
        default:
            return try openSerial(request.endpoint, model: request.model, discovery: request.discovery,
                                  recorder: request.recorder, deviceStorage: request.deviceStorage,
                                  lease: request.lease, cancellation: request.cancellation)
        }
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
        claims: EndpointClaims = .shared,
        opening: SerialOpensInFlight = .shared
    ) throws -> DiveComputerSession {
        guard endpoint.transport == .serial else { throw CableError.unsupportedTransport(endpoint.transport) }
        guard endpoint.status != .driverMissing, let path = endpoint.calloutPath, let locator = endpoint.locator else {
            throw CableError.driverMissing
        }
        guard model.transports.contains(.serial) else { throw CableError.unsupportedTransport(.serial) }
        // Checked before the port opens, since opening it raises DTR.
        guard DeviceConfiguration.hasDescriptor(family: model.dcFamily, model: model.model) else {
            throw CableError.unsupportedTransport(.serial)
        }
        guard !cancellation.isCancelled else { throw CableError.cancelled }
        // Refused here while another session is open; the open itself takes the lease in the wrap, once the port is open.
        guard !lease.isHeld, opening.begin(path) else { throw CableError.sessionInProgress }
        defer { opening.end(path) }

        var context: OpaquePointer?
        guard dc_context_new(&context) == DC_STATUS_SUCCESS, let context else { throw CableError.protocolError(DC_STATUS_NOMEMORY) }
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.context = context
        let factory = SerialTapFactory(recorder: recorder, cancellation: cancellation, lease: lease)
        let status = withExtendedLifetime(factory) {
            open_serial_device(data, path, model.dcFamily, model.model, SerialTapFactory.wrap,
                               Unmanaged.passUnretained(factory).toOpaque())
        }
        guard status == DC_STATUS_SUCCESS else {
            data.deinitialize(count: 1)
            data.deallocate()
            if factory.leaseTaken { lease.release() }
            guard factory.wrapCalled else { throw SerialPortPreflight.explain(status, path: path) }
            guard factory.leaseTaken else { throw CableError.sessionInProgress }
            throw CableError.deviceFailed(status, family: model.family, portPresent: access(path, F_OK) == 0)
        }

        let session = openedCable(devicePtr: data, displayName: model.name, storageKey: locator.locatorKey,
                                  locator: locator, deviceStorage: deviceStorage, lease: lease)
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

/// Makes the IOHIDDevice a USB HID endpoint names, or nil once it is gone.
typealias HIDDeviceFactory = (CableEndpoint) -> HIDDeviceIO?

/// An open's arguments, handed to the cable queue; the open is their only user until it returns.
struct CableOpenRequest: @unchecked Sendable {
    let endpoint: CableEndpoint
    let model: DCModel
    let discovery: CableDiscovering?
    let recorder: DCStreamRecorder?
    let deviceStorage: DeviceStorage
    let lease: DiveComputerSessionLease
    let cancellation: CableOpenCancellation
    var hidDevice: HIDDeviceFactory = IOKitHIDDevice.make
    var usbDevice: USBDeviceFactory = IOKitUSBDevice.make
}

/// Resumes an open's continuation once: with the open's result, or with `cancelled` when the task is cancelled first.
final class CableOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DiveComputerSession, Error>?
    private var finished = false

    /// False when a cancel already finished the gate; the continuation has then been resumed with `cancelled`.
    func install(_ continuation: CheckedContinuation<DiveComputerSession, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CableError.cancelled)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// False when the gate was already finished, so `result` reached no one.
    @discardableResult
    func finish(_ result: Result<DiveComputerSession, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
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

/// The ports a serial open is in progress on: a second open of one would block in the same open(2) as the first.
final class SerialOpensInFlight {
    static let shared = SerialOpensInFlight()

    private let lock = NSLock()
    private var paths: Set<String> = []

    func begin(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.insert(path).inserted
    }

    func end(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        paths.remove(path)
    }
}

/// Builds the `TapStream` around the port `open_serial_device` opens, taking the session lease once the port is open.
final class SerialTapFactory {
    let recorder: DCStreamRecorder?
    let cancellation: CableOpenCancellation
    let lease: DiveComputerSessionLease
    private(set) var wrapCalled = false
    /// False after a wrap only when another session took the lease first; the wrap then closed the port.
    private(set) var leaseTaken = false
    private(set) var tap: TapStream?

    init(recorder: DCStreamRecorder?, cancellation: CableOpenCancellation, lease: DiveComputerSessionLease) {
        self.recorder = recorder
        self.cancellation = cancellation
        self.lease = lease
    }

    static let wrap: libdc_iostream_wrap_t = { context, inner, userdata in
        guard let userdata, let inner else { return nil }
        let factory = Unmanaged<SerialTapFactory>.fromOpaque(userdata).takeUnretainedValue()
        factory.wrapCalled = true
        guard factory.lease.tryAcquire() else {
            dc_iostream_close(inner)
            return nil
        }
        factory.leaseTaken = true
        let cancellation = factory.cancellation
        let tap = TapStream(inner: inner, recorder: factory.recorder, isCancelled: { cancellation.isCancelled })
        guard let stream = try? DCCustomStream.open(backend: tap, transport: tap.transport, context: context) else {
            // Dropping the tap closes inner.
            return nil
        }
        factory.tap = tap
        return stream
    }

    /// From here the tap also gives up once the session is cancelled or released, and switches to its closing limits as the session closes.
    func attach(_ session: DiveComputerSession) {
        let cancellation = cancellation
        tap?.setCancellation { [weak session] in cancellation.isCancelled || (session?.isCancelled ?? true) }
        if let tap { session.onClosing { tap.beginClosing() } }
    }
}

/// Opens and closes the port as serial_posix does, for the errno behind a failed `dc_serial_open`, which reports busy and not permitted alike.
enum SerialPortPreflight {
    static func check(_ path: String) -> CableError? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return CableError(openErrno: errno) }
        Darwin.close(fd)
        return nil
    }

    /// Only after `dc_serial_open` failed, so a port that opens is touched once, as upstream does.
    static func explain(_ status: dc_status_t, path: String) -> CableError {
        switch status {
        case DC_STATUS_NOACCESS, DC_STATUS_NODEVICE, DC_STATUS_IO:
            return check(path) ?? CableError.portOpenFailed(status)
        default:
            return CableError.portOpenFailed(status)
        }
    }
}
#endif
