import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// The stored fingerprint only advances when the whole enumeration succeeded.
final class DownloadOutcomeTests: XCTestCase {

    private func outcome(_ status: dc_status_t, family: dc_family_t = DC_FAMILY_SUUNTO_NAUTIC,
                         matched: Bool = false, newDives: Bool, stored: Bool = true, empty: Int = 0)
        -> DiveLogRetriever.DownloadOutcome {
        DiveLogRetriever.outcome(status: status, family: family, fingerprintMatched: matched,
                                 hasNewDives: newDives, hadStoredFingerprint: stored, emptyReadCount: empty)
    }

    func testCompleteDownloadAdvancesTheFingerprint() {
        let o = outcome(DC_STATUS_SUCCESS, newDives: true)
        XCTAssertTrue(o.succeeded)
        XCTAssertTrue(o.saveFingerprint)
        XCTAssertFalse(o.interrupted)
    }

    func testNoNewDivesLeavesTheFingerprint() {
        let o = outcome(DC_STATUS_SUCCESS, newDives: false)
        XCTAssertTrue(o.succeeded)
        XCTAssertFalse(o.saveFingerprint)
    }

    func testErrorAfterSomeDivesKeepsTheFingerprintAndIsReported() {
        for status in [DC_STATUS_IO, DC_STATUS_TIMEOUT, DC_STATUS_DATAFORMAT, DC_STATUS_PROTOCOL, DC_STATUS_CANCELLED] {
            for family in [DC_FAMILY_SUUNTO_NAUTIC, DC_FAMILY_SHEARWATER_PETREL] {
                let o = outcome(status, family: family, newDives: true)
                XCTAssertFalse(o.succeeded, "\(status)")
                XCTAssertFalse(o.saveFingerprint, "\(status)")
                XCTAssertTrue(o.interrupted, "\(status)")
            }
        }
    }

    func testErrorBeforeAnyDiveIsAPlainFailure() {
        let o = outcome(DC_STATUS_IO, newDives: false)
        XCTAssertFalse(o.succeeded)
        XCTAssertFalse(o.saveFingerprint)
        XCTAssertFalse(o.interrupted)
    }

    func testNauticProtocolErrorIsNeverReadAsNoNewDives() {
        let o = outcome(DC_STATUS_PROTOCOL, family: DC_FAMILY_SUUNTO_NAUTIC, newDives: false, stored: true)
        XCTAssertFalse(o.succeeded)
        XCTAssertFalse(o.saveFingerprint)
    }

    func testLegacyProtocolLeniencyForOtherFamilies() {
        let o = outcome(DC_STATUS_PROTOCOL, family: DC_FAMILY_SHEARWATER_PETREL, newDives: false, stored: true)
        XCTAssertTrue(o.succeeded)
        XCTAssertFalse(o.saveFingerprint)
        XCTAssertTrue(outcome(DC_STATUS_PROTOCOL, matched: true, newDives: false).succeeded)
    }

    func testEmptyReadsNeverAdvanceTheFingerprint() {
        let mixed = outcome(DC_STATUS_SUCCESS, newDives: true, empty: 1)
        XCTAssertTrue(mixed.succeeded)
        XCTAssertFalse(mixed.saveFingerprint)

        let only = outcome(DC_STATUS_SUCCESS, newDives: false, empty: 2)
        XCTAssertFalse(only.succeeded)
        XCTAssertTrue(only.emptyReadOnly)
        XCTAssertFalse(only.interrupted)
    }
}
