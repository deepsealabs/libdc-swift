import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge

/// One open `DiveComputerSession` at a time: a second (another window, say) is refused, not layered on. `NauticLinkLease` and legacy BLE connections don't take it.
public final class DiveComputerSessionLease {
    public static let shared = DiveComputerSessionLease()

    private let lock = NSLock()
    private var held = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init() {}

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    /// Takes the lease if it is free; never waits.
    public func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !held else { return false }
        held = true
        return true
    }

    /// Waits in turn; throws `CancellationError` if the task is cancelled meanwhile.
    public func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands the lease to the next waiter, if any.
    public func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            held = false
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.continuation.resume()
    }
}

public enum DiveComputerSessionError: Error, Equatable {
    /// Another session holds the lease.
    case busy
    /// `open_device_on_iostream` failed with this status.
    case openFailed(dc_status_t)
    /// The `device_data_t` to adopt has no open device.
    case noDevice
}

/// An open dive computer on any transport, running one `retrieveDiveLogs(session:)` at a time; `open` owns the device, `adopt` doesn't.
public final class DiveComputerSession {
    public let devicePtr: UnsafeMutablePointer<device_data_t>
    public let displayName: String
    /// The `DeviceStorage` key for this computer (a BLE peripheral UUID, for one).
    public let storageKey: String
    public let transport: dc_transport_t
    /// Where the computer was reached; for a computer with no serial its `unitStandIn` keys the fingerprint.
    public let locator: DiveComputerLocator?
    let deviceStorage: DeviceStorage

    private let ownsDevice: Bool
    private let lease: DiveComputerSessionLease
    private let lock = NSLock()
    private var cancelled = false
    private var downloading = false
    private var closed = false
    private var closeRequested = false
    private var cancelInstalled = false
    private var lookupContext: Unmanaged<DiveDataViewModel>?
    private var currentIdentity: DiveComputerIdentity?
#if os(macOS)
    private var unplugged = false
    private var teardownActions: [() -> Void] = []
#endif

    private init(devicePtr: UnsafeMutablePointer<device_data_t>, displayName: String, storageKey: String,
                 transport: dc_transport_t, locator: DiveComputerLocator?, deviceStorage: DeviceStorage, ownsDevice: Bool,
                 lease: DiveComputerSessionLease) {
        self.devicePtr = devicePtr
        self.displayName = displayName
        self.storageKey = storageKey
        self.transport = transport
        self.locator = locator
        self.deviceStorage = deviceStorage
        self.ownsDevice = ownsDevice
        self.lease = lease
    }

    deinit { close() }

    /// Takes ownership of `iostream` and `context` on every path, as `open_device_on_iostream` does; throws `.busy` while `lease` is held.
    public static func open(
        iostream: OpaquePointer,
        context: OpaquePointer,
        family: dc_family_t,
        model: UInt32,
        displayName: String,
        storageKey: String,
        locator: DiveComputerLocator? = nil,
        attempts: UInt32 = 1,
        retryMilliseconds: UInt32 = 0,
        deviceStorage: DeviceStorage = .shared,
        lease: DiveComputerSessionLease = .shared
    ) throws -> DiveComputerSession {
        guard lease.tryAcquire() else {
            dc_iostream_close(iostream)
            dc_context_free(context)
            throw DiveComputerSessionError.busy
        }
        let transport = dc_iostream_get_transport(iostream)
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.context = context
        let status = open_device_on_iostream(data, iostream, family, model, attempts, retryMilliseconds)
        guard status == DC_STATUS_SUCCESS else {
            data.deinitialize(count: 1)
            data.deallocate()
            lease.release()
            throw DiveComputerSessionError.openFailed(status)
        }
        let session = DiveComputerSession(devicePtr: data, displayName: displayName, storageKey: storageKey, transport: transport,
                                          locator: locator, deviceStorage: deviceStorage, ownsDevice: true, lease: lease)
        session.installCancelIfCable()
        return session
    }

    /// Wraps a device someone else opened (a BLE `openBLEDevice` connection, say); close the session before they close the device.
    public static func adopt(
        devicePtr: UnsafeMutablePointer<device_data_t>,
        displayName: String,
        storageKey: String,
        locator: DiveComputerLocator? = nil,
        deviceStorage: DeviceStorage = .shared,
        lease: DiveComputerSessionLease = .shared
    ) throws -> DiveComputerSession {
        guard devicePtr.pointee.device != nil else { throw DiveComputerSessionError.noDevice }
        guard lease.tryAcquire() else { throw DiveComputerSessionError.busy }
        let transport = devicePtr.pointee.iostream.map { dc_iostream_get_transport($0) } ?? DC_TRANSPORT_BLE
        let session = DiveComputerSession(devicePtr: devicePtr, displayName: displayName, storageKey: storageKey, transport: transport,
                                          locator: locator, deviceStorage: deviceStorage, ownsDevice: false, lease: lease)
        session.installCancelIfCable()
        return session
    }

    /// `adopt` keyed the way the `CBPeripheral` download is: the advertised name and the peripheral UUID.
    public static func adoptBLE(
        devicePtr: UnsafeMutablePointer<device_data_t>,
        peripheral: CBPeripheral,
        lease: DiveComputerSessionLease = .shared
    ) throws -> DiveComputerSession {
        try adopt(devicePtr: devicePtr, displayName: peripheral.name ?? "Unknown Device",
                  storageKey: peripheral.identifier.uuidString, locator: .ble(uuid: peripheral.identifier.uuidString), lease: lease)
    }

    /// The computer DEVINFO reported, once a download has seen it.
    public var identity: DiveComputerIdentity? {
        lock.lock(); defer { lock.unlock() }
        return currentIdentity
    }

    /// The locator's transport, else the iostream's.
    var identityTransport: DCTransport {
        locator?.transport ?? DCTransport(dcValue: transport) ?? .ble
    }

    var fingerprintStandIn: String? { locator?.unitStandIn }

    /// Reads the identity from DEVINFO (or the descriptor, for a family that never sends it) and keeps it; nil before DEVINFO.
    @discardableResult
    func refreshIdentity() -> DiveComputerIdentity? {
        guard let identity = DiveComputerIdentity(device: devicePtr, transport: identityTransport)
                ?? DiveComputerIdentity(descriptorOf: devicePtr, transport: identityTransport) else { return self.identity }
        lock.lock()
        currentIdentity = identity
        lock.unlock()
        return identity
    }

    /// The stored fingerprint the C lookup hands the device, keyed by identity rather than the descriptor's name.
    func storedFingerprintForLookup() -> Data? {
        lock.lock()
        let viewModel = lookupContext?.takeUnretainedValue()
        lock.unlock()
        guard let viewModel, let identity = refreshIdentity() else { return nil }
        return viewModel.getFingerprint(for: identity, standIn: fingerprintStandIn)
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    public var isDownloading: Bool {
        lock.lock(); defer { lock.unlock() }
        return downloading
    }

    /// Sticky: the running download stops, later ones end `.cancelled`, and non-BLE sessions also fail the next transfer.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    /// Releases the owned device, the lookup's view model and the lease; mid-download it cancels and closes when the download ends.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if downloading {
            cancelled = true
            closeRequested = true
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        teardown()
    }

    /// False when closed or already downloading.
    func beginDownload() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !closeRequested, !downloading else { return false }
        downloading = true
        return true
    }

    func endDownload() {
        lock.lock()
        downloading = false
        let closeNow = closeRequested && !closed
        if closeNow { closed = true }
        lock.unlock()
        if closeNow { teardown() }
    }

    /// The C lookup can run after the caller drops its view model (a closed window), so hold it until close; the lookup's context is this session, which teardown withdraws.
    func retainLookupContext(_ viewModel: DiveDataViewModel) {
        let retained = Unmanaged.passRetained(viewModel)
        lock.lock()
        let previous = lookupContext
        lookupContext = retained
        lock.unlock()
        devicePtr.pointee.fingerprint_context = Unmanaged.passUnretained(self).toOpaque()
        previous?.release()
    }

    func releaseLookupContext() {
        lock.lock()
        let previous = lookupContext
        lookupContext = nil
        lock.unlock()
        guard let previous else { return }
        devicePtr.pointee.fingerprint_context = nil
        devicePtr.pointee.lookup_fingerprint = nil
        previous.release()
    }

    private static let cancelCallback: dc_cancel_callback_t = { userdata in
        guard let userdata else { return 0 }
        return Unmanaged<DiveComputerSession>.fromOpaque(userdata).takeUnretainedValue().isCancelled ? 1 : 0
    }

    // BLE keeps the per-dive cancel only, so an adopted BLE link behaves as the CBPeripheral download does.
    private func installCancelIfCable() {
        guard transport != DC_TRANSPORT_BLE else { return }
        cancelInstalled = libdc_set_cancel(devicePtr, Self.cancelCallback, Unmanaged.passUnretained(self).toOpaque()) == DC_STATUS_SUCCESS
    }

    private func teardown() {
        if cancelInstalled {
            libdc_set_cancel(devicePtr, nil, nil)
            cancelInstalled = false
        }
        releaseLookupContext()
        if ownsDevice {
            libdc_close_device_data(devicePtr)
            devicePtr.deinitialize(count: 1)
            devicePtr.deallocate()
        }
#if os(macOS)
        runTeardownActions()
#endif
        lease.release()
    }
}

#if os(macOS)
extension DiveComputerSession {
    /// A session owning a device a cable opener opened on `lease`, which it already holds.
    static func openedCable(devicePtr: UnsafeMutablePointer<device_data_t>, displayName: String, storageKey: String,
                            locator: DiveComputerLocator, deviceStorage: DeviceStorage,
                            lease: DiveComputerSessionLease) -> DiveComputerSession {
        let transport = devicePtr.pointee.iostream.map { dc_iostream_get_transport($0) } ?? locator.transport.dcValue
        let session = DiveComputerSession(devicePtr: devicePtr, displayName: displayName, storageKey: storageKey,
                                          transport: transport, locator: locator, deviceStorage: deviceStorage,
                                          ownsDevice: true, lease: lease)
        session.installCancelIfCable()
        return session
    }

    /// Cancelled because its cable went away (see `CableDiscovering.cancelOnRemoval`).
    public var wasUnplugged: Bool {
        lock.lock(); defer { lock.unlock() }
        return unplugged
    }

    func markUnplugged() {
        lock.lock(); defer { lock.unlock() }
        unplugged = true
        cancelled = true
    }

    /// Runs once the device is closed, or at once if the session already is.
    func onTeardown(_ action: @escaping () -> Void) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            action()
            return
        }
        teardownActions.append(action)
        lock.unlock()
    }

    private func runTeardownActions() {
        lock.lock()
        let actions = teardownActions
        teardownActions.removeAll()
        lock.unlock()
        actions.forEach { $0() }
    }
}
#endif

/// How a `retrieveDiveLogs(session:...)` download ended.
public struct DiveDownloadResult {
    public enum Outcome: Equatable {
        /// Every dive arrived and parsed.
        case completed
        case noNewDives
        case cancelled
        /// Only empty records arrived (on Suunto, another app holding the link).
        case emptyRead
        /// The walk finished, but this many dives couldn't be parsed; the fingerprint stays put so they are offered again.
        case unreadableDives(Int)
        /// Some dives arrived, then the walk failed with this status.
        case interrupted(dc_status_t)
        case failed(dc_status_t)
    }

    public let outcome: Outcome
    /// `dc_device_foreach`'s status.
    public let status: dc_status_t
    public let divesDownloaded: Int
    public let parseFailureCount: Int
    /// Present only when every dive arrived and parsed. Nothing is saved until the host acknowledges it.
    public let fingerprintCommit: FingerprintCommit?
    /// The computer DEVINFO reported; nil when the download ended before it.
    public let identity: DiveComputerIdentity?

    public var succeeded: Bool { outcome == .completed || outcome == .noNewDives }

    public init(outcome: Outcome, status: dc_status_t = DC_STATUS_SUCCESS, divesDownloaded: Int = 0,
                parseFailureCount: Int = 0, fingerprintCommit: FingerprintCommit? = nil, identity: DiveComputerIdentity? = nil) {
        self.outcome = outcome
        self.status = status
        self.divesDownloaded = divesDownloaded
        self.parseFailureCount = parseFailureCount
        self.fingerprintCommit = fingerprintCommit
        self.identity = identity
    }
}

/// The newest dive's fingerprint, saved only on `acknowledge()`, so dives the host never stored are offered again.
public final class FingerprintCommit {
    public let fingerprint: Data
    public let deviceType: String
    public let serial: String
    /// The computer the fingerprint is saved for; nil on a commit built from a device type and serial.
    public let identity: DiveComputerIdentity?
    private let save: () -> Void
    private let lock = NSLock()
    private var acknowledged = false

    /// `save` runs once, on the main thread, after the first `acknowledge()`; a host's tests can build results with it.
    public init(fingerprint: Data, deviceType: String, serial: String, save: @escaping () -> Void) {
        self.fingerprint = fingerprint
        self.deviceType = deviceType
        self.serial = serial
        identity = nil
        self.save = save
    }

    /// `deviceType` is the identity's canonical name and `serial` its DEVINFO `%08x`.
    public init(fingerprint: Data, identity: DiveComputerIdentity, save: @escaping () -> Void) {
        self.fingerprint = fingerprint
        deviceType = identity.canonicalName
        serial = identity.devinfoSerial
        self.identity = identity
        self.save = save
    }

    convenience init(fingerprint: Data, identity: DiveComputerIdentity, standIn: String?, viewModel: DiveDataViewModel) {
        self.init(fingerprint: fingerprint, identity: identity) {
            viewModel.saveFingerprint(fingerprint, for: identity, standIn: standIn)
        }
    }

    convenience init(fingerprint: Data, deviceType: String, serial: String, viewModel: DiveDataViewModel) {
        self.init(fingerprint: fingerprint, deviceType: deviceType, serial: serial) {
            viewModel.saveFingerprint(fingerprint, deviceType: deviceType, serial: serial)
        }
    }

    public var isAcknowledged: Bool {
        lock.lock(); defer { lock.unlock() }
        return acknowledged
    }

    /// Saves the fingerprint once: right away on the main thread, else on its next turn (the view model publishes the save).
    public func acknowledge() {
        lock.lock()
        let first = !acknowledged
        acknowledged = true
        lock.unlock()
        guard first else { return }
        if Thread.isMainThread {
            save()
        } else {
            DispatchQueue.main.async(execute: save)
        }
    }
}
