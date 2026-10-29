import Foundation

/// Decides whether a device can be closed now or has to wait for a download
/// that is still inside `dc_device_foreach` on it.
final class RetrievalCloseCoordinator {
    enum Decision: Equatable {
        /// No download is using the device.
        case closeNow
        /// The close runs when the download ends.
        case deferred
        /// A close is already waiting for that download; this one is dropped.
        case alreadyDeferred
    }

    private let lock = NSLock()
    private var inFlight: [UnsafeMutableRawPointer: Int] = [:]
    private var deferredCloses: [UnsafeMutableRawPointer: () -> Void] = [:]

    /// True while a close waits for a download; link I/O then answers `DC_STATUS_CANCELLED`.
    var isCancelRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return !deferredCloses.isEmpty
    }

    func begin(_ device: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        inFlight[device, default: 0] += 1
    }

    /// The download no longer touches `device`. Returns the close it held back, at most once.
    func end(_ device: UnsafeMutableRawPointer) -> (() -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard let count = inFlight[device] else { return nil }
        guard count == 1 else {
            inFlight[device] = count - 1
            return nil
        }
        inFlight[device] = nil
        return deferredCloses.removeValue(forKey: device)
    }

    func requestClose(_ device: UnsafeMutableRawPointer, deferredClose: @escaping () -> Void) -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard inFlight[device] != nil else { return .closeNow }
        guard deferredCloses[device] == nil else { return .alreadyDeferred }
        deferredCloses[device] = deferredClose
        return .deferred
    }

    func isCloseDeferred(_ device: UnsafeMutableRawPointer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deferredCloses[device] != nil
    }

    /// Begins on the caller's turn; on main afterwards, runs a held-back close, then `completion` (closed: one was waiting).
    func hold<T>(_ device: UnsafeMutableRawPointer, on queue: DispatchQueue,
                 _ work: @escaping () -> T, completion: @escaping (_ result: T, _ closed: Bool) -> Void) {
        begin(device)
        queue.async {
            let result = work()
            DispatchQueue.main.async {
                let closed = self.isCloseDeferred(device)
                self.end(device)?()
                completion(result, closed)
            }
        }
    }
}
