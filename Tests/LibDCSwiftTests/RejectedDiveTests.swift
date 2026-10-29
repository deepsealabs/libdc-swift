import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// A dive the parser rejects was downloaded but never delivered. Drivers walk
/// newest-first and `dc_device_foreach` still succeeds, so storing a newer
/// dive's fingerprint would make every later sync stop before the rejected
/// dive. It must keep the stored fingerprint and fail the download, while the
/// other dives are still delivered.
final class RejectedDiveTests: XCTestCase {

    private final class Holder: RetrievalFlagHolder {
        var isRetrievingLogs = true
    }

    private let holder = Holder()
    private let ids: [UInt32] = [1_787_900_000, 1_787_800_000, 1_787_752_091]

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_1787752091", withExtension: "sbem"))
        return try Data(contentsOf: url)
    }

    /// The dive as the third-round driver delivers a profile without the SBEM0103 magic.
    private func badMagic(_ dive: Data) -> Data {
        Data("SBEM9999".utf8) + dive.dropFirst(8)
    }

    private func context(stored: UInt32? = nil) -> DiveLogRetriever.CallbackContext {
        DiveLogRetriever.CallbackContext(
            viewModel: DiveDataViewModel(), deviceName: "Suunto Ocean 260410000713",
            deviceUUID: UUID().uuidString, storedFingerprint: stored.map(fingerprint),
            bluetoothManager: holder)
    }

    private func fingerprint(_ id: UInt32) -> Data {
        withUnsafeBytes(of: id.littleEndian) { Data($0) }
    }

    /// Runs the retriever's own dive callback, as `dc_device_foreach` would.
    @discardableResult
    private func deliver(_ dive: Data, id: UInt32, to context: DiveLogRetriever.CallbackContext) -> Int32 {
        let fp = fingerprint(id)
        let userdata = Unmanaged.passUnretained(context).toOpaque()
        return dive.withUnsafeBytes { data in
            fp.withUnsafeBytes { fpBytes in
                DiveLogRetriever.diveCallbackClosure(
                    data.bindMemory(to: UInt8.self).baseAddress, UInt32(dive.count),
                    fpBytes.bindMemory(to: UInt8.self).baseAddress, UInt32(fp.count), userdata)
            }
        }
    }

    /// `dc_device_foreach` reports SUCCESS: the driver delivered every dive.
    private func outcome(_ context: DiveLogRetriever.CallbackContext,
                         status: dc_status_t = DC_STATUS_SUCCESS) -> DiveLogRetriever.DownloadOutcome {
        DiveLogRetriever.outcome(status: status, family: DC_FAMILY_SUUNTO_NAUTIC, context: context)
    }

    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
    }

    // MARK: - The retriever's dive callback

    func testRejectedDiveBetweenTwoGoodOnesKeepsTheStoredFingerprint() throws {
        let dive = try fixture()
        let ctx = context(stored: 1_787_000_000)

        XCTAssertEqual(deliver(dive, id: ids[0], to: ctx), 1)
        XCTAssertEqual(deliver(badMagic(dive), id: ids[1], to: ctx), 1, "the older dives are still downloaded")
        XCTAssertEqual(deliver(dive, id: ids[2], to: ctx), 1)
        drainMain()

        XCTAssertEqual(ctx.viewModel.dives.count, 2)
        XCTAssertEqual(ctx.rejectedCount, 1)
        XCTAssertEqual(ctx.rejectionStatus, DC_STATUS_DATAFORMAT)

        let o = outcome(ctx)
        XCTAssertFalse(o.saveFingerprint, "the newest dive's fingerprint would hide the rejected one for good")
        XCTAssertFalse(o.succeeded)
        XCTAssertTrue(o.interrupted, "two dives arrived, one is still to fetch")
        XCTAssertTrue(o.parseRejected)
    }

    func testRejectedNewestDiveKeepsTheStoredFingerprint() throws {
        let dive = try fixture()
        let ctx = context()

        deliver(badMagic(dive), id: ids[0], to: ctx)
        deliver(dive, id: ids[1], to: ctx)

        let o = outcome(ctx)
        XCTAssertFalse(o.saveFingerprint)
        XCTAssertFalse(o.succeeded)
        XCTAssertTrue(o.parseRejected)
    }

    func testEveryDiveRejectedIsAFailureNotNoNewDives() throws {
        let dive = try fixture()
        let ctx = context(stored: 1_787_000_000)

        deliver(badMagic(dive), id: ids[0], to: ctx)
        drainMain()

        XCTAssertTrue(ctx.viewModel.dives.isEmpty)
        let o = outcome(ctx)
        XCTAssertFalse(o.succeeded)
        XCTAssertFalse(o.saveFingerprint)
        XCTAssertFalse(o.interrupted)
        XCTAssertFalse(o.emptyReadOnly)
        XCTAssertTrue(o.parseRejected)
    }

    func testRejectionBeforeTheStoredFingerprintMatchStillFails() throws {
        let dive = try fixture()
        let ctx = context(stored: ids[2])

        deliver(dive, id: ids[0], to: ctx)
        deliver(badMagic(dive), id: ids[1], to: ctx)
        XCTAssertEqual(deliver(dive, id: ids[2], to: ctx), 0, "the walk stops at the stored fingerprint")
        XCTAssertTrue(ctx.fingerprintMatched)

        let o = outcome(ctx)
        XCTAssertFalse(o.succeeded)
        XCTAssertFalse(o.saveFingerprint)
        XCTAssertTrue(o.parseRejected)
    }

    func testCleanDownloadStillAdvancesTheFingerprint() throws {
        let dive = try fixture()
        let ctx = context(stored: 1_787_000_000)

        deliver(dive, id: ids[0], to: ctx)
        deliver(dive, id: ids[1], to: ctx)

        let o = outcome(ctx)
        XCTAssertTrue(o.succeeded)
        XCTAssertTrue(o.saveFingerprint)
        XCTAssertFalse(o.parseRejected)
    }

    // MARK: - The outcome

    func testDriverFailureIsReportedOverARejection() {
        for status in [DC_STATUS_IO, DC_STATUS_TIMEOUT, DC_STATUS_PROTOCOL, DC_STATUS_CANCELLED] {
            let o = DiveLogRetriever.outcome(status: status, family: DC_FAMILY_SUUNTO_NAUTIC,
                                             fingerprintMatched: false, hasNewDives: true,
                                             hadStoredFingerprint: true, emptyReadCount: 0, rejectedCount: 1)
            XCTAssertFalse(o.succeeded, "\(status)")
            XCTAssertFalse(o.saveFingerprint, "\(status)")
            XCTAssertTrue(o.interrupted, "\(status)")
            XCTAssertFalse(o.parseRejected, "\(status): the download itself failed")
        }
    }

    func testLegacyProtocolLeniencyDoesNotHideARejection() {
        let o = DiveLogRetriever.outcome(status: DC_STATUS_PROTOCOL, family: DC_FAMILY_SHEARWATER_PETREL,
                                         fingerprintMatched: false, hasNewDives: false,
                                         hadStoredFingerprint: true, emptyReadCount: 0, rejectedCount: 1)
        XCTAssertFalse(o.succeeded)
        XCTAssertTrue(o.parseRejected)
    }

    func testRejectionAlongsideEmptyReadsIsNotAnEmptyReadOnly() {
        let o = DiveLogRetriever.outcome(status: DC_STATUS_SUCCESS, family: DC_FAMILY_SUUNTO_NAUTIC,
                                         fingerprintMatched: false, hasNewDives: false,
                                         hadStoredFingerprint: true, emptyReadCount: 1, rejectedCount: 1)
        XCTAssertFalse(o.succeeded)
        XCTAssertFalse(o.emptyReadOnly, "not every dive came back empty")
        XCTAssertTrue(o.parseRejected)
    }

    func testParseFailureStatusIsTheParsersOrDataformat() {
        XCTAssertEqual(DiveLogRetriever.parseFailureStatus(GenericParser.ParserError.sampleProcessingFailed(DC_STATUS_DATAFORMAT)),
                       DC_STATUS_DATAFORMAT)
        XCTAssertEqual(DiveLogRetriever.parseFailureStatus(GenericParser.ParserError.parserCreationFailed(DC_STATUS_UNSUPPORTED)),
                       DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(DiveLogRetriever.parseFailureStatus(GenericParser.ParserError.invalidParameters), DC_STATUS_DATAFORMAT)
        XCTAssertEqual(DiveLogRetriever.parseFailureStatus(CocoaError(.fileReadUnknown)), DC_STATUS_DATAFORMAT)
    }
}
