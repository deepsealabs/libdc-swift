#if os(macOS)
import Foundation

/// Lists the cables a host can download over and follows them as they come and go.
public protocol CableDiscovering: AnyObject {
    /// The endpoints right now.
    var endpoints: [CableEndpoint] { get }
    /// The endpoints now, then each change; streams end when the discovery is released.
    func updates() -> AsyncStream<[CableEndpoint]>
    func start()
    func stop()
    /// Cancels `session` and marks it unplugged once the endpoint goes away, or at once if it already has; a stopped discovery ignores it.
    func cancelOnRemoval(of endpointID: CableEndpoint.ID, session: DiveComputerSession)
}

/// A discovery whose endpoints the caller sets, for tests and previews; removing one cancels the sessions on it as an unplug would.
public final class StaticCableDiscovery: CableDiscovering {
    private let feed = CableEndpointFeed()

    public init(endpoints: [CableEndpoint] = []) {
        feed.replace(endpoints)
    }

    public var endpoints: [CableEndpoint] { feed.endpoints }

    public func updates() -> AsyncStream<[CableEndpoint]> { feed.updates() }

    public func start() {}

    public func stop() {}

    /// Replaces the endpoints; sessions on any that are gone are cancelled as unplugged.
    public func setEndpoints(_ endpoints: [CableEndpoint]) {
        feed.replace(endpoints)
    }

    public func remove(id: CableEndpoint.ID) {
        feed.replace(feed.baseEndpoints.filter { $0.id != id })
    }

    public func cancelOnRemoval(of endpointID: CableEndpoint.ID, session: DiveComputerSession) {
        feed.watch(endpointID, session: session)
    }
}

/// A discovery's published endpoints: ports this process has open overlaid as `.busy`, and the sessions to cancel when their endpoint goes.
final class CableEndpointFeed {
    private final class WeakSession {
        weak var session: DiveComputerSession?
        init(_ session: DiveComputerSession) { self.session = session }
    }

    private let lock = NSLock()
    private var base: [CableEndpoint] = []
    private var published: [CableEndpoint] = []
    private var continuations: [UUID: AsyncStream<[CableEndpoint]>.Continuation] = [:]
    private var watchers: [CableEndpoint.ID: [WeakSession]] = [:]
    private let claims: SerialPortClaims

    init(claims: SerialPortClaims = .shared) {
        self.claims = claims
        claims.observe(self)
    }

    deinit {
        lock.lock()
        let ending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        ending.forEach { $0.finish() }
    }

    var endpoints: [CableEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// What the last `replace` set, before the busy overlay.
    var baseEndpoints: [CableEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return base
    }

    func updates() -> AsyncStream<[CableEndpoint]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            // Yielded under the lock, as republish yields, so a newer list is never overtaken by this one.
            lock.lock()
            continuations[id] = continuation
            continuation.yield(published)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func replace(_ endpoints: [CableEndpoint]) {
        let ids = Set(endpoints.map(\.id))
        lock.lock()
        base = endpoints
        var gone: [DiveComputerSession] = []
        for (id, sessions) in watchers where !ids.contains(id) {
            gone += sessions.compactMap(\.session)
            watchers[id] = nil
        }
        lock.unlock()
        gone.forEach { $0.markUnplugged() }
        republish()
    }

    /// Reads the claims and yields under the feed's lock, so concurrent republishes land in order; claims never call a feed while holding their own lock.
    func republish() {
        lock.lock()
        defer { lock.unlock() }
        let claimed = claims.claimedPaths
        let next = base.map { endpoint -> CableEndpoint in
            guard endpoint.status == .ready, let path = endpoint.calloutPath, claimed.contains(path) else { return endpoint }
            var busy = endpoint
            busy.status = .busy
            return busy
        }
        guard next != published else { return }
        published = next
        continuations.values.forEach { $0.yield(next) }
    }

    func watch(_ endpointID: CableEndpoint.ID, session: DiveComputerSession) {
        lock.lock()
        let present = base.contains { $0.id == endpointID }
        if present {
            var sessions = watchers[endpointID, default: []].filter { $0.session != nil }
            sessions.append(WeakSession(session))
            watchers[endpointID] = sessions
        }
        lock.unlock()
        if !present { session.markUnplugged() }
    }
}

/// The serial ports this process's sessions have open, so every discovery shows them `.busy`.
final class SerialPortClaims {
    static let shared = SerialPortClaims()

    private final class WeakFeed {
        weak var feed: CableEndpointFeed?
        init(_ feed: CableEndpointFeed) { self.feed = feed }
    }

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var feeds: [WeakFeed] = []

    var claimedPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(counts.keys)
    }

    func claim(_ path: String) {
        lock.lock()
        counts[path, default: 0] += 1
        lock.unlock()
        notify()
    }

    func release(_ path: String) {
        lock.lock()
        if let count = counts[path] {
            counts[path] = count > 1 ? count - 1 : nil
        }
        lock.unlock()
        notify()
    }

    func observe(_ feed: CableEndpointFeed) {
        lock.lock(); defer { lock.unlock() }
        feeds = feeds.filter { $0.feed != nil } + [WeakFeed(feed)]
    }

    private func notify() {
        lock.lock()
        let live = feeds.compactMap(\.feed)
        lock.unlock()
        live.forEach { $0.republish() }
    }
}
#endif
