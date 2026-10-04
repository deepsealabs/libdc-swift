import Foundation
import Clibdivecomputer
import LibDCBridge

/// One open session with a Suunto Nautic/Ocean. Every call blocks on the
/// link and must be made from a single queue at a time.
public protocol NauticSyncLink: AnyObject {
    /// Logbook ids, newest first.
    func listDives() throws -> [UInt32]
    func download(_ id: UInt32) throws -> Data
    func subscribe(_ path: String) throws -> SuuntoNauticExplorer.Subscription
    func unsubscribe(_ subscription: SuuntoNauticExplorer.Subscription) throws
    func waitForNotification(timeoutMs: UInt32) throws -> SuuntoNauticExplorer.Notification?
    func close()
}

/// Finds and opens the watch.
public protocol NauticSyncConnector: AnyObject {
    /// Returns true once the watch is seen, false after `timeout` (nil waits indefinitely).
    func waitUntilPresent(timeout: TimeInterval?) async throws -> Bool
    /// Opens a session. Blocking; called off the main thread.
    func connect() throws -> NauticSyncLink
    /// Breaks the current link the way a real drop would.
    func simulateDrop()
    /// Abandons a `connect()` still in progress, which then returns or throws soon after.
    func cancelConnect()
}

public extension NauticSyncConnector {
    func cancelConnect() {}
}

public enum NauticAutoSyncError: Error, Equatable {
    case connectFailed(String)
    case deviceNotFound
    case connectTimedOut
}

/// `NauticSyncLink` over an open `dc_device_t`, through the Nautic driver.
public final class DCDeviceNauticLink: NauticSyncLink {
    private var device: OpaquePointer?
    private let onClose: (OpaquePointer) -> Void

    public init(device: OpaquePointer, onClose: @escaping (OpaquePointer) -> Void) {
        self.device = device
        self.onClose = onClose
    }

    private func dcDevice() throws -> OpaquePointer {
        guard let device else { throw SuuntoNauticExplorer.ExplorerError.notConnected }
        return device
    }

    public func listDives() throws -> [UInt32] {
        try SuuntoNauticExplorer.listDives(dcDevice: dcDevice())
    }

    public func download(_ id: UInt32) throws -> Data {
        try SuuntoNauticExplorer.download(dcDevice: dcDevice(), logbookID: String(id))
    }

    public func subscribe(_ path: String) throws -> SuuntoNauticExplorer.Subscription {
        try SuuntoNauticExplorer.subscribe(dcDevice: dcDevice(), path: path)
    }

    public func unsubscribe(_ subscription: SuuntoNauticExplorer.Subscription) throws {
        try SuuntoNauticExplorer.unsubscribe(dcDevice: dcDevice(), subscription)
    }

    public func waitForNotification(timeoutMs: UInt32) throws -> SuuntoNauticExplorer.Notification? {
        try SuuntoNauticExplorer.waitForNotification(dcDevice: dcDevice(), timeoutMs: timeoutMs)
    }

    public func close() {
        guard let device else { return }
        self.device = nil
        onClose(device)
    }
}
