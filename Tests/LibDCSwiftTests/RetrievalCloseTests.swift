import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Closing the device while a download is still inside `dc_device_foreach`
/// on it must cancel the download and close once it has stopped, never free
/// the device under it.
final class RetrievalCloseTests: XCTestCase {

    private let device = UnsafeMutableRawPointer(bitPattern: 0x1000)!
    private let otherDevice = UnsafeMutableRawPointer(bitPattern: 0x2000)!

    private final class Counter {
        var value = 0
    }

    func testCloseWithNoDownloadClosesNow() {
        let coordinator = RetrievalCloseCoordinator()
        let closes = Counter()

        XCTAssertEqual(coordinator.requestClose(device) { closes.value += 1 }, .closeNow)
        XCTAssertFalse(coordinator.isCancelRequested)
        XCTAssertFalse(coordinator.isCloseDeferred(device))
        XCTAssertNil(coordinator.end(device), "a close that ran now is not held back")
        XCTAssertEqual(closes.value, 0, "the caller runs a close-now itself")
    }

    func testCloseDuringDownloadIsDeferredAndRunsOnceWhenItEnds() {
        let coordinator = RetrievalCloseCoordinator()
        let closes = Counter()
        coordinator.begin(device)

        XCTAssertEqual(coordinator.requestClose(device) { closes.value += 1 }, .deferred)
        XCTAssertTrue(coordinator.isCancelRequested, "the download is told to stop")
        XCTAssertTrue(coordinator.isCloseDeferred(device))
        XCTAssertEqual(closes.value, 0, "nothing is closed while the download still uses the device")

        let deferred = coordinator.end(device)
        XCTAssertFalse(coordinator.isCancelRequested, "the deferred close runs with I/O no longer cancelled")
        deferred?()
        XCTAssertEqual(closes.value, 1)

        XCTAssertNil(coordinator.end(device))
        XCTAssertEqual(closes.value, 1, "the deferred close runs exactly once")
    }

    func testSecondCloseWhileDeferredDoesNotCloseTwice() {
        let coordinator = RetrievalCloseCoordinator()
        let first = Counter(), second = Counter()
        coordinator.begin(device)

        XCTAssertEqual(coordinator.requestClose(device) { first.value += 1 }, .deferred)
        XCTAssertEqual(coordinator.requestClose(device) { second.value += 1 }, .alreadyDeferred)
        XCTAssertTrue(coordinator.isCancelRequested)

        coordinator.end(device)?()
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 0)
        XCTAssertNil(coordinator.end(device))
    }

    func testNewDownloadAfterADeferredCloseStartsClean() {
        let coordinator = RetrievalCloseCoordinator()
        let first = Counter(), second = Counter()
        coordinator.begin(device)
        XCTAssertEqual(coordinator.requestClose(device) { first.value += 1 }, .deferred)
        coordinator.end(device)?()

        // The next open may well reuse the freed allocation's address.
        coordinator.begin(device)
        XCTAssertFalse(coordinator.isCancelRequested, "the next download's I/O is not cancelled")
        XCTAssertFalse(coordinator.isCloseDeferred(device))

        XCTAssertEqual(coordinator.requestClose(device) { second.value += 1 }, .deferred)
        coordinator.end(device)?()
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1)
        XCTAssertEqual(coordinator.requestClose(device) {}, .closeNow, "and a close after it closes now")
    }

    func testCloseAfterTheDownloadEndedClosesNow() {
        let coordinator = RetrievalCloseCoordinator()
        coordinator.begin(device)
        XCTAssertNil(coordinator.end(device))
        XCTAssertEqual(coordinator.requestClose(device) {}, .closeNow)
        XCTAssertFalse(coordinator.isCancelRequested)
    }

    func testOverlappingDownloadsHoldTheCloseUntilTheLastEnds() {
        let coordinator = RetrievalCloseCoordinator()
        let closes = Counter()
        coordinator.begin(device)
        coordinator.begin(device)
        XCTAssertEqual(coordinator.requestClose(device) { closes.value += 1 }, .deferred)

        XCTAssertNil(coordinator.end(device))
        XCTAssertTrue(coordinator.isCancelRequested)
        coordinator.end(device)?()
        XCTAssertEqual(closes.value, 1)
    }

    func testClosingAnotherDeviceIsNotHeldBack() {
        let coordinator = RetrievalCloseCoordinator()
        coordinator.begin(device)
        XCTAssertEqual(coordinator.requestClose(otherDevice) {}, .closeNow)
        XCTAssertFalse(coordinator.isCancelRequested)
        XCTAssertNil(coordinator.end(device))
    }

    func testCloseFromAnotherThreadIsHeldUntilTheDownloadEnds() {
        let coordinator = RetrievalCloseCoordinator()
        let closes = Counter()
        coordinator.begin(device)

        let requested = expectation(description: "close requested")
        DispatchQueue.global().async {
            XCTAssertEqual(coordinator.requestClose(self.device) { closes.value += 1 }, .deferred)
            requested.fulfill()
        }
        wait(for: [requested], timeout: 2)

        coordinator.end(device)?()
        XCTAssertEqual(closes.value, 1)
    }

    // MARK: - The BLE iostream answers CANCELLED

    func testCancelledReadAnswersCancelled() {
        XCTAssertEqual(ble_read_status(true, 0, true), DC_STATUS_CANCELLED, "a read woken by the close")
        XCTAssertEqual(ble_read_status(true, 0, false), DC_STATUS_CANCELLED)
        XCTAssertEqual(ble_read_status(true, 20, true), DC_STATUS_CANCELLED, "a packet that raced the close is not handed on")
    }

    func testReadStatusIsUnchangedWhenNotCancelled() {
        XCTAssertEqual(ble_read_status(false, 20, true), DC_STATUS_SUCCESS)
        XCTAssertEqual(ble_read_status(false, 0, true), DC_STATUS_TIMEOUT)
        XCTAssertEqual(ble_read_status(false, 0, false), DC_STATUS_IO)
    }

    func testCancelledWriteAnswersCancelled() {
        for result in [0, 1, 2] {
            XCTAssertEqual(ble_write_status(true, result), DC_STATUS_CANCELLED, "\(result)")
        }
        XCTAssertEqual(ble_write_status(false, 0), DC_STATUS_SUCCESS)
        XCTAssertEqual(ble_write_status(false, 1), DC_STATUS_TIMEOUT)
        XCTAssertEqual(ble_write_status(false, 2), DC_STATUS_IO)
    }

    func testCancelledDownloadKeepsTheFingerprint() {
        for newDives in [false, true] {
            let o = DiveLogRetriever.outcome(status: DC_STATUS_CANCELLED, family: DC_FAMILY_SUUNTO_NAUTIC,
                                             fingerprintMatched: false, hasNewDives: newDives,
                                             hadStoredFingerprint: true, emptyReadCount: 0)
            XCTAssertFalse(o.succeeded)
            XCTAssertFalse(o.saveFingerprint)
            XCTAssertEqual(o.interrupted, newDives)
        }
    }
}
