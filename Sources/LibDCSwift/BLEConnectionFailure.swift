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

/// The failure `CoreBluetoothManager` publishes as `lastConnectionFailure`, and the link it can come from. Main thread.
struct BLEConnectAttempt {
    private(set) var failure: BLEConnectionFailure?
    /// The peripheral this attempt connected to, until its link is closed.
    private(set) var link: UUID?

    /// An open is starting: an earlier attempt's failure doesn't explain this one, even if it fails before connecting.
    mutating func start() {
        failure = nil
        link = nil
    }

    /// The open is connecting to `peripheral`; its errors are this attempt's.
    mutating func connecting(to peripheral: UUID) {
        link = peripheral
    }

    /// The link was closed. A late error from it isn't a failure; the one already recorded stays.
    mutating func close() {
        link = nil
    }

    /// CoreBluetooth reported `error` for `peripheral`. Recorded only while it is this attempt's open link.
    @discardableResult
    mutating func fail(_ error: Error, from peripheral: UUID) -> Bool {
        guard peripheral == link else { return false }
        failure = BLEConnectionFailure(error)
        return true
    }
}
