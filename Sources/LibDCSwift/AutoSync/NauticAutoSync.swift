import Foundation
import Clibdivecomputer
import LibDCBridge

public protocol NauticAutoSyncDelegate: AnyObject {
    /// Called on the main queue.
    func autoSync(_ autoSync: NauticAutoSync, didEmit event: NauticAutoSync.Event)
}

/// Hands-off dive download for a Suunto Nautic/Ocean, modelled on the
/// official Suunto app:
///
/// - waits for the watch, connects, lists `/Logbook/Entries` and downloads
///   only dives whose logbook id isn't synced yet, oldest first;
/// - while connected, subscribes to `/Logbook/UnsynchronisedLogs` (a count
///   the watch pushes when it changes) and `/Sync/BusyState`, and syncs when
///   the count goes up, deferring while the watch reports busy; an hourly
///   refresh covers firmware without those resources;
/// - when the link drops or a dive comes back incomplete, reconnects under
///   `ReconnectPolicy` and resumes with the dives still missing, retrying a
///   dive up to `retriesPerDive` times before moving on.
///
/// Never writes to the watch: dives stay unsynchronised for the Suunto app.
public final class NauticAutoSync {
    public struct Configuration {
        public var reconnect: ReconnectPolicy = .suuntoApp
        public var retriesPerDive = 3
        public var listRetries = 3
        /// Stay connected after a sync and listen for triggers, as the Suunto app does.
        public var keepConnected = true
        /// While connected, re-list this often even without a trigger; nil disables.
        public var refreshInterval: TimeInterval? = 60 * 60
        /// When not keeping the connection, wait this long before looking for the watch again.
        public var revisitInterval: TimeInterval = 15 * 60
        public var subscribeToTriggers = true
        /// Lets a burst of trigger notifications settle before syncing.
        public var triggerDebounce: TimeInterval = 3
        public var notificationPollMs: UInt32 = 1000
        /// How long to look for the watch after a failed connect before waiting passively.
        public var presenceTimeout: TimeInterval = 15

        public init() {}
    }

    public enum State: Equatable {
        case stopped
        case waitingForDevice
        case connecting(attempt: Int)
        case listing
        case downloading(index: Int, total: Int, id: UInt32)
        case watching
        case watchBusy
        case reconnecting(attempt: Int, delay: TimeInterval)
        case coolingDown(until: Date)
    }

    public struct DownloadedDive: Equatable {
        public let id: UInt32
        /// Decompressed SBEM0103 profile with the /Summary appended, as `SuuntoNauticExplorer.download` returns it.
        public let data: Data
        /// False when the bytes still don't match the listed size after every retry.
        public let isComplete: Bool
        public let attempts: Int
    }

    public struct SyncSummary: Equatable {
        public let downloaded: [UInt32]
        public let failed: [UInt32]
        public let listed: Int
    }

    public enum Event: Equatable {
        case state(State)
        case log(String)
        case dive(DownloadedDive)
        case diveFailed(id: UInt32, reason: String)
        case syncCompleted(SyncSummary)
    }

    public struct Environment {
        public var now: () -> Date
        public var sleep: (TimeInterval) async throws -> Void

        public init(now: @escaping () -> Date, sleep: @escaping (TimeInterval) async throws -> Void) {
            self.now = now
            self.sleep = sleep
        }

        public static let live = Environment(now: Date.init) { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    public static let unsynchronisedLogsPath = "/Logbook/UnsynchronisedLogs"
    public static let busyStatePath = "/Sync/BusyState"

    public let deviceKey: String
    public let configuration: Configuration
    public let events: AsyncStream<Event>
    public weak var delegate: NauticAutoSyncDelegate?
    /// Called off the main thread for each dive before it is marked synced; throw to keep it pending.
    public var onDive: ((DownloadedDive) throws -> Void)?

    private let connector: NauticSyncConnector
    private let store: AutoSyncStore
    private let environment: Environment
    private let continuation: AsyncStream<Event>.Continuation
    private let linkQueue = DispatchQueue(label: "com.libdcswift.nautic-autosync.link")
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var currentState: State = .stopped
    private var stopRequested = false
    private var syncNowRequested = false
    private var markExistingRequested = false
    private var resetRequested = false

    // Touched only by the run task.
    private var baseline: UInt32?
    private var runDownloaded: [UInt32] = []

    public init(
        deviceKey: String,
        connector: NauticSyncConnector,
        store: AutoSyncStore = UserDefaultsAutoSyncStore(),
        baseline: UInt32? = nil,
        configuration: Configuration = Configuration(),
        environment: Environment = .live
    ) {
        self.deviceKey = deviceKey
        self.connector = connector
        self.store = store
        self.baseline = baseline
        self.configuration = configuration
        self.environment = environment
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        task?.cancel()
        continuation.finish()
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != nil
    }

    public func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        stopRequested = false
        task = Task.detached { [weak self] in await self?.run() }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopRequested = true
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    /// Sync as soon as connected (immediately when idle on a connection).
    public func syncNow() {
        lock.lock(); syncNowRequested = true; lock.unlock()
    }

    /// Marks every dive currently on the watch as synced without downloading it.
    public func markExistingAsSynced() {
        lock.lock(); markExistingRequested = true; lock.unlock()
    }

    /// Forgets which dives were synced, so the next sync downloads everything on the watch.
    public func resetSynced() {
        lock.lock(); resetRequested = true; lock.unlock()
    }

    public func simulateDrop() {
        emit(.log("Simulating a link drop"))
        connector.simulateDrop()
    }

    // MARK: - Run loop

    private enum SessionOutcome {
        case linkLost(String)
        case refresh(String)
        case idleDone
        case stopped
    }

    private enum SyncOutcome {
        case done
        case refresh(String)
        case stopped
    }

    private enum FailureKind {
        case linkLost
        case incomplete(Data)
        case failed(String)
        case cancelled
    }

    private struct Triggers {
        var unsynced: SuuntoNauticExplorer.Subscription?
        var busy: SuuntoNauticExplorer.Subscription?
        var unsyncedCount: Int?
        var isBusy = false
        var unsupported = false
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested || Task.isCancelled
    }

    private func consume(_ flag: ReferenceWritableKeyPath<NauticAutoSync, Bool>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = self[keyPath: flag]
        self[keyPath: flag] = false
        return value
    }

    private func makePlan() -> DiveSyncPlan {
        DiveSyncPlan(synced: store.syncedIDs(device: deviceKey), baseline: baseline, retriesPerDive: configuration.retriesPerDive)
    }

    private func run() async {
        var tracker = ReconnectTracker(policy: configuration.reconnect)
        var plan = makePlan()
        var reconnecting = false

        loop: while !isStopping {
            do {
                if !reconnecting {
                    set(.waitingForDevice)
                    guard try await connector.waitUntilPresent(timeout: nil) else { continue }
                }
                reconnecting = false

                guard let link = try await connect(&tracker) else { continue }
                let outcome = await session(link, &plan)
                await runOnLinkQueue { link.close() }

                switch outcome {
                case .stopped:
                    break loop
                case .idleDone:
                    set(.waitingForDevice)
                    try await environment.sleep(configuration.revisitInterval)
                case .linkLost(let reason), .refresh(let reason):
                    emit(.log(reason))
                    switch tracker.disconnected(at: environment.now()) {
                    case .retry(let delay, let attempt):
                        set(.reconnecting(attempt: attempt, delay: delay))
                        try await environment.sleep(delay)
                        reconnecting = true
                    case .coolDown(let duration):
                        emit(.log("Too many disconnects in a short time; pausing reconnects"))
                        try await coolDown(duration, &tracker)
                    }
                }
            } catch {
                break loop
            }
        }
        set(.stopped)
    }

    private func connect(_ tracker: inout ReconnectTracker) async throws -> NauticSyncLink? {
        while !isStopping {
            set(.connecting(attempt: tracker.nextAttempt))
            do {
                let link = try await onLinkQueue { try self.connector.connect() }
                tracker.connected()
                emit(.log("Connected"))
                return link
            } catch {
                emit(.log("Connect failed: \(Self.describe(error))"))
                guard try await connector.waitUntilPresent(timeout: configuration.presenceTimeout) else {
                    emit(.log("Watch no longer in range; waiting for it"))
                    return nil
                }
                switch tracker.connectionFailed(linkLost: false) {
                case .retry(let delay, let attempt):
                    set(.reconnecting(attempt: attempt, delay: delay))
                    try await environment.sleep(delay)
                case .coolDown(let duration):
                    emit(.log("Connect keeps failing; pausing reconnects"))
                    try await coolDown(duration, &tracker)
                    return nil
                }
            }
        }
        return nil
    }

    private func coolDown(_ duration: TimeInterval, _ tracker: inout ReconnectTracker) async throws {
        set(.coolingDown(until: environment.now().addingTimeInterval(duration)))
        try await environment.sleep(duration)
        tracker.cooledDown()
    }

    private func session(_ link: NauticSyncLink, _ plan: inout DiveSyncPlan) async -> SessionOutcome {
        var triggers = Triggers()
        var needsSync = true
        var lastSync: Date?
        let pollSeconds = TimeInterval(configuration.notificationPollMs) / 1000

        do {
            try await subscribeTriggers(link, &triggers)
            while !isStopping {
                if consume(\.resetRequested) {
                    store.reset(device: deviceKey)
                    baseline = nil
                    plan = makePlan()
                    emit(.log("Forgot synced dives"))
                    needsSync = true
                }
                if consume(\.markExistingRequested) {
                    try await unsubscribeTriggers(link, &triggers)
                    let ids = try await list(link)
                    store.markSynced(ids, device: deviceKey)
                    ids.forEach { plan.markSynced($0) }
                    emit(.log("Marked \(ids.count) dive(s) on the watch as synced"))
                    try await subscribeTriggers(link, &triggers)
                }
                if consume(\.syncNowRequested) {
                    needsSync = true
                }

                if needsSync && !triggers.isBusy {
                    try await unsubscribeTriggers(link, &triggers)
                    switch try await sync(link, &plan) {
                    case .done: break
                    case .refresh(let reason): return .refresh(reason)
                    case .stopped: return .stopped
                    }
                    needsSync = false
                    lastSync = environment.now()
                    if !configuration.keepConnected { return .idleDone }
                    let before = triggers.unsyncedCount
                    try await subscribeTriggers(link, &triggers)
                    if let before, let after = triggers.unsyncedCount, after > before {
                        emit(.log("Unsynchronised count went up during the sync (\(before) -> \(after))"))
                        needsSync = true
                    }
                    continue
                }

                set(triggers.isBusy ? .watchBusy : .watching)
                let started = environment.now()
                let notification = try await onLinkQueue { try link.waitForNotification(timeoutMs: self.configuration.notificationPollMs) }
                if let notification {
                    if handle(notification, &triggers) {
                        needsSync = true
                        try await environment.sleep(configuration.triggerDebounce)
                    }
                } else if environment.now().timeIntervalSince(started) < pollSeconds / 2 {
                    try await environment.sleep(pollSeconds)
                }
                if let interval = configuration.refreshInterval, let lastSync,
                   environment.now().timeIntervalSince(lastSync) >= interval, !needsSync {
                    emit(.log("Periodic refresh"))
                    needsSync = true
                }
            }
            return .stopped
        } catch {
            if isStopping || error is CancellationError { return .stopped }
            return .linkLost("Link lost: \(Self.describe(error))")
        }
    }

    // MARK: - Sync

    private func sync(_ link: NauticSyncLink, _ plan: inout DiveSyncPlan) async throws -> SyncOutcome {
        set(.listing)
        let listed = try await list(link)
        let pending = plan.pending(listed: listed)
        emit(.log("\(listed.count) dive(s) on the watch, \(pending.count) to download"))

        var index = 0
        while index < pending.count {
            if isStopping { return .stopped }
            let id = pending[index]
            set(.downloading(index: index + 1, total: pending.count, id: id))
            let attempt = plan.recordAttempt(id)
            do {
                let data = try await onLinkQueue { try link.download(id) }
                deliver(id, data: data, complete: true, attempts: attempt, &plan)
                index += 1
            } catch {
                switch Self.classify(error) {
                case .linkLost:
                    throw error
                case .cancelled:
                    return .stopped
                case .incomplete(let data):
                    if plan.canRetry(id) {
                        return .refresh("Dive \(id) came back incomplete (attempt \(attempt)); reconnecting to retry")
                    }
                    emit(.log("Dive \(id) still incomplete after \(attempt) attempts; keeping what arrived"))
                    deliver(id, data: data, complete: false, attempts: attempt, &plan)
                    index += 1
                case .failed(let reason):
                    if plan.canRetry(id) {
                        emit(.log("Dive \(id) failed (\(reason)); retrying"))
                        continue
                    }
                    plan.giveUp(id)
                    emit(.diveFailed(id: id, reason: reason))
                    index += 1
                }
            }
        }

        emit(.syncCompleted(SyncSummary(downloaded: runDownloaded, failed: plan.givenUp.sorted(), listed: listed.count)))
        runDownloaded.removeAll()
        plan.finishRun()
        return .done
    }

    private func list(_ link: NauticSyncLink) async throws -> [UInt32] {
        var attempt = 0
        while true {
            do {
                return try await onLinkQueue { try link.listDives() }
            } catch {
                guard case .failed(let reason) = Self.classify(error), attempt < configuration.listRetries else { throw error }
                attempt += 1
                emit(.log("Listing failed (\(reason)); retrying"))
                try await environment.sleep(1)
            }
        }
    }

    private func deliver(_ id: UInt32, data: Data, complete: Bool, attempts: Int, _ plan: inout DiveSyncPlan) {
        let dive = DownloadedDive(id: id, data: data, isComplete: complete, attempts: attempts)
        do {
            try onDive?(dive)
        } catch {
            plan.giveUp(id)
            emit(.diveFailed(id: id, reason: "rejected by the app: \(error)"))
            return
        }
        store.markSynced([id], device: deviceKey)
        plan.markSynced(id)
        runDownloaded.append(id)
        emit(.dive(dive))
    }

    // MARK: - Triggers

    private func subscribeTriggers(_ link: NauticSyncLink, _ triggers: inout Triggers) async throws {
        guard configuration.subscribeToTriggers, !triggers.unsupported, triggers.unsynced == nil else { return }
        do {
            let unsynced = try await onLinkQueue { try link.subscribe(Self.unsynchronisedLogsPath) }
            triggers.unsynced = unsynced
            triggers.unsyncedCount = unsynced.initialValue?.integerValue
            let busy = try await onLinkQueue { try link.subscribe(Self.busyStatePath) }
            triggers.busy = busy
            triggers.isBusy = (busy.initialValue?.integerValue ?? 0) != 0
            emit(.log("Listening for sync triggers (unsynchronised: \(triggers.unsyncedCount.map(String.init) ?? "?"), busy: \(triggers.isBusy))"))
        } catch {
            if case .linkLost = Self.classify(error), !Self.isTimeout(error) { throw error }
            triggers.unsupported = true
            emit(.log("No sync trigger on this watch (\(Self.describe(error))); using periodic refresh"))
        }
    }

    /// The subscriptions' notifications share the 0x01 opcode with /Data chunks, so they must be off during a download.
    private func unsubscribeTriggers(_ link: NauticSyncLink, _ triggers: inout Triggers) async throws {
        for subscription in [triggers.unsynced, triggers.busy].compactMap({ $0 }) {
            do {
                try await onLinkQueue { try link.unsubscribe(subscription) }
            } catch {
                if case .linkLost = Self.classify(error), !Self.isTimeout(error) { throw error }
            }
        }
        triggers.unsynced = nil
        triggers.busy = nil
    }

    /// True when the notification should start a sync.
    private func handle(_ notification: SuuntoNauticExplorer.Notification, _ triggers: inout Triggers) -> Bool {
        let value = notification.value?.integerValue
        if let unsynced = triggers.unsynced, unsynced.matches(notification.handle) {
            let previous = triggers.unsyncedCount
            triggers.unsyncedCount = value
            emit(.log("Watch reports \(value.map(String.init) ?? "?") unsynchronised log(s)"))
            guard let value else { return true }
            return value > (previous ?? 0)
        }
        if let busy = triggers.busy, busy.matches(notification.handle) {
            triggers.isBusy = (value ?? 0) != 0
            emit(.log(triggers.isBusy ? "Watch is busy" : "Watch is no longer busy"))
            return false
        }
        return false
    }

    // MARK: - Helpers

    private func onLinkQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            linkQueue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func runOnLinkQueue(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            linkQueue.async { body(); continuation.resume() }
        }
    }

    private func set(_ state: State) {
        lock.lock()
        let changed = currentState != state
        currentState = state
        lock.unlock()
        if changed { emit(.state(state)) }
    }

    private func emit(_ event: Event) {
        if case .log(let message) = event { logInfo("[NauticAutoSync] \(message)") }
        continuation.yield(event)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.autoSync(self, didEmit: event)
        }
    }

    private static func classify(_ error: Error) -> FailureKind {
        switch error {
        case SuuntoNauticExplorer.ExplorerError.incompleteDownload(let data):
            return .incomplete(data)
        case SuuntoNauticExplorer.ExplorerError.requestFailed(let status):
            switch status {
            case DC_STATUS_IO, DC_STATUS_TIMEOUT, DC_STATUS_NODEVICE: return .linkLost
            case DC_STATUS_CANCELLED: return .cancelled
            default: return .failed(statusName(status))
            }
        case is CancellationError:
            return .cancelled
        default:
            return .linkLost
        }
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if case SuuntoNauticExplorer.ExplorerError.requestFailed(let status) = error { return status == DC_STATUS_TIMEOUT }
        return false
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SuuntoNauticExplorer.ExplorerError.requestFailed(let status): return statusName(status)
        case SuuntoNauticExplorer.ExplorerError.incompleteDownload(let data): return "incomplete download (\(data.count) bytes)"
        case SuuntoNauticExplorer.ExplorerError.notConnected: return "not connected"
        case NauticAutoSyncError.connectFailed(let reason): return reason
        case NauticAutoSyncError.deviceNotFound: return "watch not found"
        default: return "\(error)"
        }
    }

    private static func statusName(_ status: dc_status_t) -> String {
        DiveLogRetriever.statusName(status)
    }
}
