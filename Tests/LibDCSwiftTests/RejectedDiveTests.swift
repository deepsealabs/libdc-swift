import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// A dive the parser rejects was downloaded but never delivered. Drivers walk
/// newest-first and `dc_device_foreach` still succeeds, so storing a newer
/// dive's fingerprint would make every later sync stop before the rejected
/// dive. It must keep the stored fingerprint and fail the download, while the
/// other dives are still delivered. The same dive rejected on a later sync is
/// unreadable, and then no longer holds the fingerprint.
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

    // MARK: - A dive rejected again is unreadable

    private let serial = "test-\(UUID().uuidString)"
    /// The key `settle` stores rejections under here: no stored device, so the context's device name.
    private let deviceType = "Suunto Ocean 260410000713"

    override func tearDown() {
        DeviceFingerprintStorage.shared.setRejectedDives([], forDeviceType: deviceType, serial: serial)
        super.tearDown()
    }

    private struct Sync {
        let context: DiveLogRetriever.CallbackContext
        let outcome: DiveLogRetriever.DownloadOutcome
        let unreadable: [Data]
        /// The dives the walk downloaded, before it stopped at the stored fingerprint.
        let downloaded: [UInt32]
    }

    /// One sync of a watch holding `dives`, newest first: walks them until the callback stops at the stored
    /// fingerprint, as the drivers do, settles, and stores the fingerprint when the outcome says to.
    private func sync(_ dives: [(data: Data, id: UInt32)], stored: inout Data?, serial: String? = nil) -> Sync {
        let ctx = DiveLogRetriever.CallbackContext(
            viewModel: DiveDataViewModel(), deviceName: deviceType, deviceUUID: UUID().uuidString,
            storedFingerprint: stored, bluetoothManager: holder)
        ctx.deviceSerial = serial ?? self.serial
        var downloaded: [UInt32] = []
        for dive in dives {
            guard deliver(dive.data, id: dive.id, to: ctx) == 1 else { break }
            downloaded.append(dive.id)
        }
        let (outcome, unreadable) = DiveLogRetriever.settle(status: DC_STATUS_SUCCESS, family: DC_FAMILY_SUUNTO_NAUTIC,
                                                            context: ctx)
        if outcome.saveFingerprint { stored = ctx.lastFingerprint }
        return Sync(context: ctx, outcome: outcome, unreadable: unreadable, downloaded: downloaded)
    }

    func testDiveRejectedOnTwoSyncsIsSkippedAndTheFingerprintMovesPastIt() throws {
        let dive = try fixture()
        let watch = [(dive, ids[0]), (badMagic(dive), ids[1]), (dive, ids[2])]
        let synced = fingerprint(1_787_000_000)
        var stored: Data? = synced

        let first = sync(watch, stored: &stored)
        XCTAssertTrue(first.outcome.parseRejected)
        XCTAssertFalse(first.outcome.succeeded)
        XCTAssertEqual(first.unreadable, [])
        XCTAssertEqual(stored, synced, "a first rejection holds the fingerprint, so the next sync tries the dive again")

        let second = sync(watch, stored: &stored)
        XCTAssertEqual(second.downloaded, ids, "the next sync re-walks from the stored fingerprint")
        XCTAssertTrue(second.outcome.succeeded, "the same dive rejected again is unreadable, not missing")
        XCTAssertFalse(second.outcome.parseRejected)
        XCTAssertFalse(second.outcome.interrupted)
        XCTAssertEqual(second.unreadable, [fingerprint(ids[1])])
        XCTAssertEqual(stored, fingerprint(ids[0]), "the fingerprint moves to the newest dive")

        let third = sync(watch, stored: &stored)
        XCTAssertEqual(third.downloaded, [], "the sync after stops at the newest dive and doesn't ask for the unreadable one")
        XCTAssertTrue(third.context.fingerprintMatched)
        XCTAssertTrue(third.outcome.succeeded)
        XCTAssertEqual(third.unreadable, [])
    }

    func testUnreadableNewestDiveIsTheFingerprintStored() throws {
        let dive = try fixture()
        let watch = [(badMagic(dive), ids[0]), (dive, ids[1]), (dive, ids[2])]
        var stored: Data? = fingerprint(ids[2])

        XCTAssertTrue(sync(watch, stored: &stored).outcome.parseRejected)
        let second = sync(watch, stored: &stored)
        XCTAssertTrue(second.outcome.saveFingerprint)
        XCTAssertEqual(stored, fingerprint(ids[0]), "the newest dive's, though it's the one rejected, not the newest parsed")

        XCTAssertEqual(sync(watch, stored: &stored).downloaded, [])
    }

    func testOnlyAnUnreadableDiveStillMovesTheFingerprint() {
        let o = DiveLogRetriever.outcome(status: DC_STATUS_SUCCESS, family: DC_FAMILY_SUUNTO_NAUTIC,
                                         fingerprintMatched: true, hasNewDives: false,
                                         hadStoredFingerprint: true, emptyReadCount: 0, unreadableCount: 1)
        XCTAssertTrue(o.succeeded)
        XCTAssertTrue(o.saveFingerprint, "else every sync downloads the unreadable dive again until a newer one comes")
        XCTAssertFalse(o.parseRejected)
    }

    func testRejectedDiveThatParsesOnTheNextSyncIsDeliveredAndForgotten() throws {
        let dive = try fixture()
        var stored: Data? = fingerprint(1_787_000_000)

        _ = sync([(dive, ids[0]), (badMagic(dive), ids[1])], stored: &stored)
        XCTAssertEqual(DeviceFingerprintStorage.shared.rejectedDives(forDeviceType: deviceType, serial: serial),
                       [fingerprint(ids[1])])

        let second = sync([(dive, ids[0]), (dive, ids[1])], stored: &stored)
        drainMain()
        XCTAssertEqual(second.context.viewModel.dives.count, 2)
        XCTAssertEqual(second.unreadable, [])
        XCTAssertEqual(stored, fingerprint(ids[0]))
        XCTAssertTrue(DeviceFingerprintStorage.shared.rejectedDives(forDeviceType: deviceType, serial: serial).isEmpty)
    }

    func testFirstRejectionAlongsideAnUnreadableDiveStillHolds() throws {
        let dive = try fixture()
        let synced = fingerprint(1_787_000_000)
        var stored: Data? = synced
        _ = sync([(dive, ids[0]), (badMagic(dive), ids[1])], stored: &stored)

        let newer: UInt32 = 1_788_000_000
        let second = sync([(badMagic(dive), newer), (dive, ids[0]), (badMagic(dive), ids[1])], stored: &stored)
        XCTAssertTrue(second.outcome.parseRejected, "the newer dive is rejected for the first time")
        XCTAssertFalse(second.outcome.saveFingerprint)
        XCTAssertEqual(second.unreadable, [fingerprint(ids[1])])
        XCTAssertEqual(stored, synced)

        let third = sync([(badMagic(dive), newer), (dive, ids[0]), (badMagic(dive), ids[1])], stored: &stored)
        XCTAssertTrue(third.outcome.succeeded)
        XCTAssertEqual(third.unreadable, [fingerprint(newer), fingerprint(ids[1])])
        XCTAssertEqual(stored, fingerprint(newer))
    }

    func testUnreadableDiveDoesNotHoldADownloadThatIgnoresTheFingerprint() throws {
        let dive = try fixture()
        var stored: Data? = fingerprint(1_787_000_000)
        let watch = [(dive, ids[0]), (badMagic(dive), ids[1])]
        _ = sync(watch, stored: &stored)
        _ = sync(watch, stored: &stored)

        var none: Data?
        let all = sync(watch, stored: &none)
        XCTAssertTrue(all.outcome.succeeded, "a dive given up stays known as unreadable")
        XCTAssertEqual(all.unreadable, [fingerprint(ids[1])])
    }

    func testWithoutASerialEveryRejectionHolds() throws {
        let dive = try fixture()
        let synced = fingerprint(1_787_000_000)
        var stored: Data? = synced
        let watch = [(dive, ids[0]), (badMagic(dive), ids[1])]
        for _ in 0..<2 {
            let ctx = DiveLogRetriever.CallbackContext(
                viewModel: DiveDataViewModel(), deviceName: deviceType, deviceUUID: UUID().uuidString,
                storedFingerprint: stored, bluetoothManager: holder)
            for (data, id) in watch { deliver(data, id: id, to: ctx) }
            let (o, unreadable) = DiveLogRetriever.settle(status: DC_STATUS_SUCCESS, family: DC_FAMILY_SUUNTO_NAUTIC, context: ctx)
            XCTAssertTrue(o.parseRejected, "with no key the dive can't be recognised again")
            XCTAssertEqual(unreadable, [])
            if o.saveFingerprint { stored = ctx.lastFingerprint }
        }
        XCTAssertEqual(stored, synced)
    }

    func testRejectionWithoutAFingerprintAlwaysHolds() {
        let split = DiveLogRetriever.splitRejections([Data(), fingerprint(ids[1])], previouslyRejected: [Data(), fingerprint(ids[1])])
        XCTAssertEqual(split.retry, [Data()])
        XCTAssertEqual(split.unreadable, [fingerprint(ids[1])])
        XCTAssertEqual(DiveLogRetriever.rememberedRejections(previous: [], rejected: [Data()], delivered: []), [])
    }

    func testForgettingTheDeviceForgetsItsRejections() {
        let storage = DeviceFingerprintStorage.shared
        let type = "Test Device \(UUID().uuidString)"
        let other = "test-other-\(UUID().uuidString)"
        defer {
            storage.setRejectedDives([], forDeviceType: type, serial: serial)
            storage.setRejectedDives([], forDeviceType: type, serial: other)
        }
        storage.setRejectedDives([fingerprint(ids[1])], forDeviceType: type, serial: serial)
        storage.setRejectedDives([fingerprint(ids[2])], forDeviceType: type, serial: other)

        storage.clearFingerprint(forDeviceType: type, serial: serial)
        XCTAssertTrue(storage.rejectedDives(forDeviceType: type, serial: serial).isEmpty)
        XCTAssertEqual(storage.rejectedDives(forDeviceType: type, serial: other), [fingerprint(ids[2])])

        storage.clearFingerprintsForDeviceType(type.uppercased())
        XCTAssertTrue(storage.rejectedDives(forDeviceType: type, serial: other).isEmpty)
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
