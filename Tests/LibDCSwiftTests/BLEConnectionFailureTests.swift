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
        let failure = BLEConnectionFailure(NSError(domain: CBErrorDomain, code: 9999))
        switch failure {
        case .bluetooth(let code):
            XCTAssertEqual(code.rawValue, 9999)
        case .other(let domain, let code):
            XCTAssertEqual(domain, CBErrorDomain)
            XCTAssertEqual(code, 9999)
        case .pairingRemoved:
            XCTFail("an unknown code is not pairing removed")
        }
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
        XCTAssertNil(attempt.failure)

        XCTAssertTrue(attempt.fail(CBError(.peerRemovedPairingInformation), from: watch, current: watch))
        XCTAssertEqual(attempt.failure, .pairingRemoved)

        XCTAssertTrue(attempt.fail(CBError(.connectionTimeout), from: watch, current: watch),
                      "a later drop of the same link replaces it")
        XCTAssertEqual(attempt.failure, .bluetooth(.connectionTimeout))
    }

    func testNewConnectClearsTheLastFailure() {
        var attempt = BLEConnectAttempt()
        attempt.fail(CBError(.peerRemovedPairingInformation), from: watch, current: watch)

        attempt.start()
        XCTAssertNil(attempt.failure, "a new attempt isn't explained by the last one")

        attempt.fail(CBError(.connectionTimeout), from: watch, current: watch)
        XCTAssertEqual(attempt.failure, .bluetooth(.connectionTimeout))
    }

    func testFailureFromAnEarlierLinkIsIgnored() {
        var attempt = BLEConnectAttempt()
        attempt.start()

        XCTAssertFalse(attempt.fail(CBError(.connectionTimeout), from: otherWatch, current: watch),
                       "a late drop of the previous watch doesn't explain this one")
        XCTAssertNil(attempt.failure)

        XCTAssertFalse(attempt.fail(CBError(.peerRemovedPairingInformation), from: watch, current: nil),
                       "with the link closed, a late error belongs to it")
        XCTAssertNil(attempt.failure)
    }
}
