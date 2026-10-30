import XCTest
import CoreBluetooth
@testable import LibDCSwift
import LibDCBridge
import Clibdivecomputer

/// A link that drops stays dead until the next connect, and a cancel scheduled for a closed
/// link never lands on the one a connect made since (trustthegoose's run E on #29: after a
/// supervision timeout DC Tester kept sending on the old link, then lost its fresh one to the
/// close's delayed cancel while the watch answered its Hello on the air).
final class BLELinkStateTests: XCTestCase {

    func testDropFailsLinkIOFastUntilTheNextConnect() {
        let link = BLELinkState()
        link.start()
        XCTAssertEqual(ble_link_status(false, link.isLost), DC_STATUS_SUCCESS)

        XCTAssertTrue(link.drop(peripheralState: .disconnected))
        XCTAssertTrue(link.isLost)
        XCTAssertEqual(ble_link_status(false, link.isLost), DC_STATUS_NODEVICE,
                       "a read or write on the dropped link answers NODEVICE without touching it")
        XCTAssertFalse(link.needsShutdownSettle(peripheralState: .disconnected),
                       "a dropped link is cancelled at once, before a connect can follow")

        link.start()
        XCTAssertFalse(link.isLost, "the next connect's link is usable")
        XCTAssertEqual(ble_link_status(false, link.isLost), DC_STATUS_SUCCESS)
    }

    func testCloseDuringDownloadStillAnswersCancelledOnADroppedLink() {
        XCTAssertEqual(ble_link_status(true, true), DC_STATUS_CANCELLED, "a close waiting for the download wins")
        XCTAssertEqual(ble_link_status(true, false), DC_STATUS_CANCELLED)
    }

    func testDelayedCancelFromACloseSkipsTheLinkAConnectMadeSince() {
        let link = BLELinkState()
        link.start()
        XCTAssertTrue(link.needsShutdownSettle(peripheralState: .connected), "a live link lets the shutdown flush first")

        // close(): the shutdown settles, and the cancel is scheduled for this link.
        let scheduledIn = link.generation
        XCTAssertTrue(link.shouldCancel(scheduledIn: scheduledIn), "with no connect since, the cancel goes ahead")

        // Connect within the delay: iOS still holds the watch's link, so it's the same CBPeripheral.
        link.start()
        XCTAssertFalse(link.shouldCancel(scheduledIn: scheduledIn), "the new session must survive the old close")
    }

    func testDisconnectFromAnEarlierLinkDoesNotKillTheReconnectingOne() {
        let link = BLELinkState()
        link.start()
        for state in [CBPeripheralState.connecting, .connected] {
            XCTAssertFalse(link.drop(peripheralState: state), "\(state.rawValue): the callback belongs to the link before")
            XCTAssertFalse(link.isLost)
        }
        XCTAssertTrue(link.drop(peripheralState: .disconnecting), "a link tearing down is lost")
    }
}
