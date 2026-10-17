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
    /// Whoever frees the device waits on this while a download runs: the session itself when it owns the device, else the BLE manager.
    let closeCoordinator: RetrievalCloseCoordinator

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
    private let closeWaiters = CloseWaiters()
#if os(macOS)
    private var unplugged = false
    /// A cable session's close reached on the main thread runs on `cableQueue`: the driver's close sleeps and reads.
    private var closesOffMain = false
    private var closingActions: [() -> Void] = []
    private var teardownActions: [() -> Void] = []
    /// The family the device opened as, read while the descriptor is valid; `CableError(download:)` reads it after a close too.
    let openedFamily: DeviceConfiguration.DeviceFamily?
#endif

    private init(devicePtr: UnsafeMutablePointer<device_data_t>, displayName: String, storageKey: String,
                 transport: dc_transport_t, locator: DiveComputerLocator?, deviceStorage: DeviceStorage, ownsDevice: Bool,
                 lease: DiveComputerSessionLease, closeCoordinator: RetrievalCloseCoordinator) {
        self.devicePtr = devicePtr
        self.displayName = displayName
        self.storageKey = storageKey
        self.transport = transport
        self.locator = locator
        self.deviceStorage = deviceStorage
        self.closeCoordinator = closeCoordinator
        self.ownsDevice = ownsDevice
        self.lease = lease
#if os(macOS)
        openedFamily = devicePtr.pointee.descriptor.flatMap { DeviceConfiguration.DeviceFamily(dcFamily: dc_descriptor_get_type($0)) }
#endif
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
                                          locator: locator, deviceStorage: deviceStorage, ownsDevice: true, lease: lease,
                                          closeCoordinator: RetrievalCloseCoordinator())
        session.installCancelIfCable()
        return session
    }

    /// Wraps a device someone else opened (a BLE `openBLEDevice` connection, say); close the session before they close the device.
    /// Pass the `bluetoothManager` that opened it so its `close` waits for a session download, as it does for its own.
    public static func adopt(
        devicePtr: UnsafeMutablePointer<device_data_t>,
        displayName: String,
        storageKey: String,
        locator: DiveComputerLocator? = nil,
        deviceStorage: DeviceStorage = .shared,
        lease: DiveComputerSessionLease = .shared,
        bluetoothManager: CoreBluetoothManager? = nil
    ) throws -> DiveComputerSession {
        if bluetoothManager == nil, (devicePtr.pointee.iostream.map { dc_iostream_get_transport($0) } ?? DC_TRANSPORT_BLE) == DC_TRANSPORT_BLE {
            logWarning("Adopted BLE device without its CoreBluetoothManager: the manager's close won't wait for a session download")
        }
        return try adopt(devicePtr: devicePtr, displayName: displayName, storageKey: storageKey, locator: locator,
                         deviceStorage: deviceStorage, lease: lease,
                         closeCoordinator: bluetoothManager?.retrievalClose ?? RetrievalCloseCoordinator())
    }

    static func adopt(
        devicePtr: UnsafeMutablePointer<device_data_t>,
        displayName: String,
        storageKey: String,
        locator: DiveComputerLocator? = nil,
        deviceStorage: DeviceStorage = .shared,
        lease: DiveComputerSessionLease = .shared,
        closeCoordinator: RetrievalCloseCoordinator
    ) throws -> DiveComputerSession {
        guard devicePtr.pointee.device != nil else { throw DiveComputerSessionError.noDevice }
        guard lease.tryAcquire() else { throw DiveComputerSessionError.busy }
        let transport = devicePtr.pointee.iostream.map { dc_iostream_get_transport($0) } ?? DC_TRANSPORT_BLE
        let session = DiveComputerSession(devicePtr: devicePtr, displayName: displayName, storageKey: storageKey, transport: transport,
                                          locator: locator, deviceStorage: deviceStorage, ownsDevice: false, lease: lease,
                                          closeCoordinator: closeCoordinator)
        session.installCancelIfCable()
        return session
    }

    /// `adopt` keyed the way the `CBPeripheral` download is: the advertised name and the peripheral UUID.
    public static func adoptBLE(
        devicePtr: UnsafeMutablePointer<device_data_t>,
        peripheral: CBPeripheral,
        lease: DiveComputerSessionLease = .shared,
        bluetoothManager: CoreBluetoothManager = .sharedManager
    ) throws -> DiveComputerSession {
        try adopt(devicePtr: devicePtr, displayName: peripheral.name ?? "Unknown Device",
                  storageKey: peripheral.identifier.uuidString, locator: .ble(uuid: peripheral.identifier.uuidString), lease: lease,
                  closeCoordinator: bluetoothManager.retrievalClose)
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
    /// On macOS an owned cable session's close runs the driver's quit with its sleeps, each read capped at
    /// `TapStream.closingReadLimitMilliseconds`, and a write to a stalled link (classic Bluetooth out of range) can block;
    /// reached on the main thread (this call, the end of a download, or the last release) it runs on a background queue,
    /// so `isClosed` is true at once but the lease stays held until the port is closed.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if downloading {
            let first = !closeRequested
            cancelled = true
            closeRequested = true
            lock.unlock()
            // Owned devices close through the coordinator, so the download sees the close and ends cancelled.
            if first && ownsDevice {
                _ = closeCoordinator.requestClose(UnsafeMutableRawPointer(devicePtr)) { [weak self] in self?.closeAfterDownload() }
            }
            return
        }
        closed = true
        lock.unlock()
        teardown()
    }

    /// `close()`, then `completion` on the main queue once the device is closed and the lease is free.
    public func close(completion: @escaping () -> Void) {
        closeWaiters.add(completion)
        close()
    }

    /// False when closed or already downloading.
    func beginDownload() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !closeRequested, !downloading else { return false }
        downloading = true
        return true
    }

    /// Runs a close the coordinator didn't hold, one that came before the download took the device or after it let go.
    func endDownload() {
        lock.lock()
        downloading = false
        let closeNow = closeRequested && !closed
        lock.unlock()
        if closeNow { closeAfterDownload() }
    }

    private func closeAfterDownload() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        teardown()
    }

    /// The owner's close held back by a download is about to free an adopted device: let go of it while it is still valid.
    func ownerWillCloseDevice() {
        guard !ownsDevice else { return }
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        teardown()
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

    // The device's close captures no self, so a close from deinit can still leave the main thread.
    private func teardown() {
        if cancelInstalled {
            libdc_set_cancel(devicePtr, nil, nil)
            cancelInstalled = false
        }
        releaseLookupContext()
        let devicePtr = devicePtr, ownsDevice = ownsDevice, lease = lease, waiters = closeWaiters
#if os(macOS)
        let beforeClose = takeActions(\.closingActions), afterClose = takeActions(\.teardownActions)
#endif
        let closeDevice = {
            if ownsDevice {
#if os(macOS)
                beforeClose.forEach { $0() }
#endif
                libdc_close_device_data(devicePtr)
                devicePtr.deinitialize(count: 1)
                devicePtr.deallocate()
            }
#if os(macOS)
            afterClose.forEach { $0() }
#endif
            lease.release()
            waiters.finish()
        }
#if os(macOS)
        if closesOffMain, Thread.isMainThread {
            Self.cableQueue.async(execute: closeDevice)
            return
        }
#endif
        closeDevice()
    }
}

/// Run on the main queue once a session's device is closed and its lease is free.
private final class CloseWaiters {
    private let lock = NSLock()
    private var done = false
    private var waiting: [() -> Void] = []

    func add(_ completion: @escaping () -> Void) {
        lock.lock()
        guard !done else {
            lock.unlock()
            DispatchQueue.main.async(execute: completion)
            return
        }
        waiting.append(completion)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        done = true
        let all = waiting
        waiting = []
        lock.unlock()
        all.forEach { DispatchQueue.main.async(execute: $0) }
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
                                          ownsDevice: true, lease: lease, closeCoordinator: RetrievalCloseCoordinator())
        session.installCancelIfCable()
        session.closesOffMain = true
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

    /// Runs just before an owned device's close, while its iostream is still open (a tap switching to its closing limits).
    func onClosing(_ action: @escaping () -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closingActions.append(action)
        lock.unlock()
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

    private func takeActions(_ list: ReferenceWritableKeyPath<DiveComputerSession, [() -> Void]>) -> [() -> Void] {
        lock.lock(); defer { lock.unlock() }
        let actions = self[keyPath: list]
        self[keyPath: list] = []
        return actions
    }
}
#endif

/// How a `retrieveDiveLogs(session:...)` download ended.
public struct DiveDownloadResult {
    public enum Outcome: Equatable {
        /// Every dive arrived and parsed, or was skipped as unreadable (see `unreadableDives`).
        case completed
        case noNewDives
        /// The host cancelled, or closed the device mid-download.
        case cancelled
        /// Only empty records arrived (on Suunto, another app holding the link).
        case emptyRead
        /// The walk finished, but the parser rejected this many dives for the first time, the first with `status`.
        /// The fingerprint stays before them, so the next download tries them once more and skips any rejected again.
        case parseRejected(count: Int, status: dc_status_t)
        /// Some dives arrived, then the walk failed with this status.
        case interrupted(dc_status_t)
        case failed(dc_status_t)
    }

    public let outcome: Outcome
    /// `dc_device_foreach`'s status, `DC_STATUS_CANCELLED` after a host stop or a close.
    public let status: dc_status_t
    public let divesDownloaded: Int
    /// Dives the parser rejected on this download, held or skipped.
    public let parseFailureCount: Int
    /// Fingerprints of the dives skipped because an earlier download's parser rejected them too; only on a success.
    public let unreadableDives: [Data]
    /// Present only when the walk finished with every dive parsed or skipped as unreadable. Nothing is saved until the host acknowledges it.
    public let fingerprintCommit: FingerprintCommit?
    /// The computer DEVINFO reported; nil when the download ended before it.
    public let identity: DiveComputerIdentity?

    public var succeeded: Bool { outcome == .completed || outcome == .noNewDives }

    public init(outcome: Outcome, status: dc_status_t = DC_STATUS_SUCCESS, divesDownloaded: Int = 0,
                parseFailureCount: Int = 0, unreadableDives: [Data] = [], fingerprintCommit: FingerprintCommit? = nil,
                identity: DiveComputerIdentity? = nil) {
        self.outcome = outcome
        self.status = status
        self.divesDownloaded = divesDownloaded
        self.parseFailureCount = parseFailureCount
        self.unreadableDives = unreadableDives
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
