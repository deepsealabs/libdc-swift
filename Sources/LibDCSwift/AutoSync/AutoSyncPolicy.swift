import Foundation

/// Reconnect limits. Defaults mirror the official Suunto app's connection
/// state machine (com.stt.android.suunto 6.7.12): a fixed 4 s delay between
/// attempts, at most 20 counted / 96 total attempts, a 120 min cool-down once
/// those are used up, and a cool-down when more than 10 disconnects land
/// within 5 minutes.
public struct ReconnectPolicy: Equatable {
    public var retryDelay: TimeInterval
    /// Failed attempts that count toward the cool-down; a failure caused by a lost link does not.
    public var maxCountedAttempts: Int
    public var maxTotalAttempts: Int
    public var coolDown: TimeInterval
    public var loopDisconnects: Int
    public var loopWindow: TimeInterval

    public init(
        retryDelay: TimeInterval = 4,
        maxCountedAttempts: Int = 20,
        maxTotalAttempts: Int = 96,
        coolDown: TimeInterval = 120 * 60,
        loopDisconnects: Int = 10,
        loopWindow: TimeInterval = 5 * 60
    ) {
        self.retryDelay = retryDelay
        self.maxCountedAttempts = maxCountedAttempts
        self.maxTotalAttempts = maxTotalAttempts
        self.coolDown = coolDown
        self.loopDisconnects = loopDisconnects
        self.loopWindow = loopWindow
    }

    public static let suuntoApp = ReconnectPolicy()
}

/// Bookkeeping for `ReconnectPolicy`: decides, after each failure or drop,
/// whether to retry (and when) or to cool down.
public struct ReconnectTracker: Equatable {
    public enum Decision: Equatable {
        case retry(after: TimeInterval, attempt: Int)
        case coolDown(TimeInterval)
    }

    public let policy: ReconnectPolicy
    public private(set) var countedAttempts = 0
    public private(set) var totalAttempts = 0
    public private(set) var disconnects: [Date] = []

    public init(policy: ReconnectPolicy = .suuntoApp) {
        self.policy = policy
    }

    /// The next attempt number, 1-based.
    public var nextAttempt: Int { totalAttempts + 1 }

    public mutating func connectionFailed(linkLost: Bool) -> Decision {
        totalAttempts += 1
        if !linkLost { countedAttempts += 1 }
        if countedAttempts >= policy.maxCountedAttempts || totalAttempts >= policy.maxTotalAttempts {
            countedAttempts = 0
            totalAttempts = 0
            return .coolDown(policy.coolDown)
        }
        return .retry(after: policy.retryDelay, attempt: nextAttempt)
    }

    public mutating func connected() {
        countedAttempts = 0
        totalAttempts = 0
    }

    public mutating func disconnected(at now: Date) -> Decision {
        disconnects.append(now)
        if disconnects.count > policy.loopDisconnects {
            disconnects.removeFirst()
            if now.timeIntervalSince(disconnects[0]) < policy.loopWindow {
                disconnects.removeAll()
                return .coolDown(policy.coolDown)
            }
        }
        return .retry(after: policy.retryDelay, attempt: nextAttempt)
    }

    public mutating func cooledDown() {
        countedAttempts = 0
        totalAttempts = 0
        disconnects.removeAll()
    }
}

/// Which listed dives still need downloading, across reconnects. Dedup is by
/// logbook id (the dive's UNIX start time), like the Suunto app: anything in
/// `synced` is never downloaded again.
public struct DiveSyncPlan: Equatable {
    /// Retries per dive after the first attempt; the Suunto app's logbook sync uses 3.
    public let retriesPerDive: Int
    public private(set) var synced: Set<UInt32>
    /// Ids at or below this are treated as synced (e.g. an existing fingerprint).
    public let baseline: UInt32?
    public private(set) var attempts: [UInt32: Int] = [:]
    public private(set) var givenUp: Set<UInt32> = []

    public init(synced: Set<UInt32>, baseline: UInt32? = nil, retriesPerDive: Int = 3) {
        self.synced = synced
        self.baseline = baseline
        self.retriesPerDive = retriesPerDive
    }

    public func isSynced(_ id: UInt32) -> Bool {
        synced.contains(id) || (baseline.map { id <= $0 } ?? false)
    }

    /// Dives still to fetch in this run, oldest first.
    public func pending(listed: [UInt32]) -> [UInt32] {
        Array(Set(listed)).filter { !isSynced($0) && !givenUp.contains($0) }.sorted()
    }

    @discardableResult
    public mutating func recordAttempt(_ id: UInt32) -> Int {
        let n = (attempts[id] ?? 0) + 1
        attempts[id] = n
        return n
    }

    public func canRetry(_ id: UInt32) -> Bool {
        (attempts[id] ?? 0) <= retriesPerDive
    }

    public mutating func markSynced(_ id: UInt32) {
        synced.insert(id)
        attempts[id] = nil
    }

    public mutating func giveUp(_ id: UInt32) {
        givenUp.insert(id)
        attempts[id] = nil
    }

    /// A finished run forgets its attempt counts, so a dive given up on is tried again next time.
    public mutating func finishRun() {
        attempts.removeAll()
        givenUp.removeAll()
    }
}

/// Persistence for the synced-id set.
public protocol AutoSyncStore: AnyObject {
    func syncedIDs(device: String) -> Set<UInt32>
    func markSynced(_ ids: [UInt32], device: String)
    func reset(device: String)
}

public final class UserDefaultsAutoSyncStore: AutoSyncStore {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ device: String) -> String { "com.libdc.autoSync.synced.\(device)" }

    public func syncedIDs(device: String) -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        let raw = defaults.array(forKey: key(device)) as? [NSNumber] ?? []
        return Set(raw.map { $0.uint32Value })
    }

    public func markSynced(_ ids: [UInt32], device: String) {
        lock.lock(); defer { lock.unlock() }
        var set = Set((defaults.array(forKey: key(device)) as? [NSNumber] ?? []).map { $0.uint32Value })
        set.formUnion(ids)
        defaults.set(set.sorted().map { NSNumber(value: $0) }, forKey: key(device))
    }

    public func reset(device: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key(device))
    }
}

public final class InMemoryAutoSyncStore: AutoSyncStore {
    private var ids: [String: Set<UInt32>] = [:]
    private let lock = NSLock()

    public init() {}

    public func syncedIDs(device: String) -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        return ids[device] ?? []
    }

    public func markSynced(_ new: [UInt32], device: String) {
        lock.lock(); defer { lock.unlock() }
        ids[device, default: []].formUnion(new)
    }

    public func reset(device: String) {
        lock.lock(); defer { lock.unlock() }
        ids[device] = nil
    }
}
