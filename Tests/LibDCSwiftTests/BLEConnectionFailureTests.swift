import XCTest
import CoreBluetooth
@testable import LibDCSwift

/// A failed connect or a dropped link says why, from CoreBluetooth's error code, so an app can
/// tell "forget the device in Bluetooth settings" apart from "try again".
final class BLEConnectionFailureTests: XCTestCase {

    private enum Unrelated: Error { case failed }

    private let watch = UUID()
    private let otherWatch = UUID()

    // MARK: - Mapping

    func testPeerRemovedPairingInformationIsPairingRemoved() {
        XCTAssertEqual(BLEConnectionFailure(CBError(.peerRemovedPairingInformation)), .pairingRemoved)
        XCTAssertEqual(BLEConnectionFailure(NSError(domain: CBErrorDomain, code: 14)), .pairingRemoved)
    }

    func testMappingReadsTheCodeNotTheLocalizedText() {
        let localized = NSError(domain: CBErrorDomain, code: 14,
                                userInfo: [NSLocalizedDescriptionKey: "Le pair a supprimé les informations de jumelage."])
        XCTAssertEqual(BLEConnectionFailure(localized), .pairingRemoved)

        let misleading = NSError(domain: CBErrorDomain, code: CBError.Code.connectionTimeout.rawValue,
                                 userInfo: [NSLocalizedDescriptionKey: "Peer removed pairing information"])
        XCTAssertEqual(BLEConnectionFailure(misleading), .bluetooth(.connectionTimeout))
    }

    func testOtherCoreBluetoothErrorsKeepTheirCode() {
        XCTAssertEqual(BLEConnectionFailure(CBError(.connectionTimeout)), .bluetooth(.connectionTimeout))
        XCTAssertEqual(BLEConnectionFailure(CBError(.encryptionTimedOut)), .bluetooth(.encryptionTimedOut))
        XCTAssertEqual(BLEConnectionFailure(CBError(.peripheralDisconnected)), .bluetooth(.peripheralDisconnected))
    }

    func testUnknownCoreBluetoothCodeIsKept() {
        XCTAssertEqual(BLEConnectionFailure(NSError(domain: CBErrorDomain, code: 9999)),
                       .bluetooth(CBError.Code(rawValue: 9999)!))
    }

    func testErrorsOutsideCoreBluetoothAreOther() {
        // CBATTError 14 is unlikelyError, not pairing removed: the domain decides.
        XCTAssertEqual(BLEConnectionFailure(NSError(domain: CBATTErrorDomain, code: 14)),
                       .other(domain: CBATTErrorDomain, code: 14))
        XCTAssertEqual(BLEConnectionFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))),
                       .other(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)))

        guard case .other = BLEConnectionFailure(Unrelated.failed) else {
            return XCTFail("a Swift error is not a CoreBluetooth failure")
        }
    }

    // MARK: - Which attempt a failure belongs to

    func testFailureOfTheCurrentLinkIsRecorded() {
        var attempt = BLEConnectAttempt()
        attempt.start()
        attempt.connecting(to: watch)
        XCTAssertNil(attempt.failure)

        XCTAssertTrue(attempt.fail(CBError(.peerRemovedPairingInformation), from: watch))
        XCTAssertEqual(attempt.failure, .pairingRemoved)

        XCTAssertTrue(attempt.fail(CBError(.connectionTimeout), from: watch),
                      "a later drop of the same link replaces it")
        XCTAssertEqual(attempt.failure, .bluetooth(.connectionTimeout))
    }

    func testNewOpenClearsTheLastFailure() {
        var attempt = BLEConnectAttempt()
        attempt.start()
        attempt.connecting(to: watch)
        attempt.fail(CBError(.peerRemovedPairingInformation), from: watch)

        attempt.start()
        XCTAssertNil(attempt.failure, "a new attempt isn't explained by the last one")

        attempt.connecting(to: watch)
        attempt.fail(CBError(.connectionTimeout), from: watch)
        XCTAssertEqual(attempt.failure, .bluetooth(.connectionTimeout))
    }

    func testOpenThatFailsBeforeConnectingHasNoFailure() {
        var attempt = BLEConnectAttempt()
        attempt.start()
        attempt.connecting(to: otherWatch)
        attempt.fail(CBError(.peerRemovedPairingInformation), from: otherWatch)

        attempt.start()
        XCTAssertNil(attempt.failure, "an open that never reached connect doesn't show the last one's reason")
        XCTAssertFalse(attempt.fail(CBError(.peerRemovedPairingInformation), from: otherWatch),
                       "nor does a late error from the last open's link")
        XCTAssertNil(attempt.failure)
    }

    func testFailureFromAnEarlierLinkIsIgnored() {
        var attempt = BLEConnectAttempt()
        attempt.start()
        attempt.connecting(to: watch)

        XCTAssertFalse(attempt.fail(CBError(.connectionTimeout), from: otherWatch),
                       "a late drop of the previous watch doesn't explain this one")
        XCTAssertNil(attempt.failure)
    }

    func testLateDropAfterCloseIsIgnored() {
        var attempt = BLEConnectAttempt()
        attempt.start()
        attempt.connecting(to: watch)
        attempt.close()

        XCTAssertFalse(attempt.fail(CBError(.peripheralDisconnected), from: watch),
                       "a drop after the device was closed isn't a failure")
        XCTAssertNil(attempt.failure)
    }

    func testCloseKeepsTheRecordedFailure() {
        var attempt = BLEConnectAttempt()
        attempt.start()
        attempt.connecting(to: watch)
        attempt.fail(CBError(.peerRemovedPairingInformation), from: watch)

        attempt.close()
        XCTAssertEqual(attempt.failure, .pairingRemoved, "closing a failed open leaves its reason readable")
        XCTAssertFalse(attempt.fail(CBError(.connectionTimeout), from: watch))
        XCTAssertEqual(attempt.failure, .pairingRemoved)
    }
}
