import Foundation
import CoreBluetooth

/// The link the open device talks over, from one connect to the next.
///
/// A dropped link stays dead until the next connect starts: link I/O then answers
/// `DC_STATUS_NODEVICE` at once instead of writing into it or waiting out its timeouts.
/// iOS reconnects a bonded watch by itself within seconds (the Nautic then uses that link
/// for phone notifications), but that link isn't ours until we connect, enable
/// notifications and say Hello on it again.
///
/// Each connect starts a new generation. A cancel scheduled for a closed link carries the
/// generation it was scheduled in, so it can't land on the link a connect made since: for a
/// watch iOS holds the link to, that is the same `CBPeripheral`, and the cancel would end our
/// session on it while the watch kept answering on the air.
final class BLELinkState {
    private let lock = NSLock()
    private var _generation = 0
    private var _lost = false

    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    /// True from a drop of the current link until the next `start()`.
    var isLost: Bool {
        lock.lock(); defer { lock.unlock() }
        return _lost
    }

    /// A connect is starting a new link.
    func start() {
        lock.lock(); defer { lock.unlock() }
        _generation += 1
        _lost = false
    }

    /// The link dropped. A disconnect that lands while the peripheral is already connecting or
    /// connected again belongs to the link before it and is ignored. Returns whether the link is
    /// now lost.
    @discardableResult
    func drop(peripheralState: CBPeripheralState) -> Bool {
        guard peripheralState != .connecting && peripheralState != .connected else { return false }
        lock.lock(); defer { lock.unlock() }
        _lost = true
        return true
    }

    /// Whether a cancel scheduled in `generation` still targets the current link.
    func shouldCancel(scheduledIn generation: Int) -> Bool {
        self.generation == generation
    }

    /// A close lets the device's shutdown command flush before cancelling the link, but a link
    /// that already dropped has nothing to flush: cancel it at once, before a connect can follow.
    func needsShutdownSettle(peripheralState: CBPeripheralState) -> Bool {
        !isLost && peripheralState == .connected
    }
}
