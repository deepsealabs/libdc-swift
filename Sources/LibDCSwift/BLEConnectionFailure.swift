import Foundation
import CoreBluetooth

/// Why CoreBluetooth couldn't connect to a dive computer, or why its link dropped.
///
/// Mapped from the error's domain and code, never its text, which the system localizes.
/// `CoreBluetoothManager.lastConnectionFailure` holds the latest one.
public enum BLEConnectionFailure: Equatable, Sendable {
    /// The dive computer no longer has this device's pairing keys (`CBError.peerRemovedPairingInformation`,
    /// "Peer removed pairing information"), e.g. after it was reset or paired with another phone. Retrying
    /// won't help: the user has to forget it in the system's Bluetooth settings, then connect to pair again.
    case pairingRemoved
    /// Any other CoreBluetooth error, such as `.connectionTimeout`. Can be a code this SDK has no case for.
    case bluetooth(CBError.Code)
    /// An error from outside `CBErrorDomain`.
    case other(domain: String, code: Int)

    public init(_ error: Error) {
        let error = error as NSError
        guard error.domain == CBErrorDomain, let code = CBError.Code(rawValue: error.code) else {
            self = .other(domain: error.domain, code: error.code)
            return
        }
        self = code == .peerRemovedPairingInformation ? .pairingRemoved : .bluetooth(code)
    }
}

/// The failure `CoreBluetoothManager` publishes as `lastConnectionFailure`. Main thread.
struct BLEConnectAttempt {
    private(set) var failure: BLEConnectionFailure?

    /// A connect is starting: an earlier attempt's failure doesn't explain this one.
    mutating func start() {
        failure = nil
    }

    /// CoreBluetooth reported `error` for `peripheral` while the manager's link is to `current`.
    /// An error for any other peripheral, or with no link, belongs to an earlier one and is ignored.
    @discardableResult
    mutating func fail(_ error: Error, from peripheral: UUID, current: UUID?) -> Bool {
        guard peripheral == current else { return false }
        failure = BLEConnectionFailure(error)
        return true
    }
}
