import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// The Ocean is also a sports watch, and its logbook lists its runs and other sports with the dives (#29). The parser
/// reports an activity that isn't a dive as UNSUPPORTED, and the retriever skips it without counting a failure.
///
/// `suunto_ocean_nondive_synthetic.bin` is SYNTHETIC, not a download of a run. It was made from Ocean dive 1787699873
/// (fw 2.51.28): its /Summary keeps the three Windows records and the Header, without the dive header and the dive
/// footer, with the sport set to 3 (running) and the depths unset; its profile keeps the first 160 records that aren't
/// dive records (no dive status, dive state, gas switch, IMU or GPS), with the activity record's sport set to 3.
final class NonDiveActivityTests: XCTestCase {

    // MARK: - Fixtures

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin")))
    }

    private func syntheticRun() throws -> Data { try fixture("suunto_ocean_nondive_synthetic") }
    private func dive() throws -> Data { try fixture("suunto_nautic_1787752091") }

    /// Where the activity record (0x08) of a blob's profile is: the offset of the record and of its data.
    private static func activityRecord(_ blob: [UInt8]) -> (record: Int, data: Int, length: Int)? {
        let summary = Int(UInt32(blob[0]) | UInt32(blob[1]) << 8 | UInt32(blob[2]) << 16 | UInt32(blob[3]) << 24)
        var offset = 4 + summary + 8
        while offset + 2 <= blob.count {
            var id = Int(blob[offset]), header = 1
            if id == 0xFF { id = Int(blob[offset + 1]) | Int(blob[offset + 2]) << 8; header += 2 }
            var length = Int(blob[offset + header]); header += 1
            if length == 0xFF {
                length = (0..<4).reduce(0) { $0 | Int(blob[offset + header + $1]) << (8 * $1) }
                header += 4
            }
            if id == 0x08 { return (offset, offset + header, length) }
            offset += header + length
        }
        return nil
    }

    private static func withSport(_ data: Data, _ sport: UInt8) throws -> Data {
        var blob = [UInt8](data)
        let activity = try XCTUnwrap(activityRecord(blob))
        blob[activity.data + 2] = sport
        return Data(blob)
    }

    private static func withoutActivity(_ data: Data) throws -> Data {
        var blob = [UInt8](data)
        let activity = try XCTUnwrap(activityRecord(blob))
        blob.removeSubrange(activity.record..<(activity.data + activity.length))
        return Data(blob)
    }

    /// The records of the SBEM container at `start..<end` of `blob`: where each one starts, its id, and where its data is.
    private static func records(_ blob: [UInt8], _ start: Int, _ end: Int) -> [(record: Int, id: Int, data: Int, length: Int)] {
        var out: [(record: Int, id: Int, data: Int, length: Int)] = []
        var offset = start + 8
        while offset + 2 <= end {
            var id = Int(blob[offset]), header = 1
            if id == 0xFF { id = Int(blob[offset + 1]) | Int(blob[offset + 2]) << 8; header += 2 }
            var length = Int(blob[offset + header]); header += 1
            if length == 0xFF {
                length = (0..<4).reduce(0) { $0 | Int(blob[offset + header + $1]) << (8 * $1) }
                header += 4
            }
            out.append((offset, id, offset + header, length))
            offset += header + length
        }
        return out
    }

    private static func summarySize(_ blob: [UInt8]) -> Int {
        Int(UInt32(blob[0]) | UInt32(blob[1]) << 8 | UInt32(blob[2]) << 16 | UInt32(blob[3]) << 24)
    }

    /// The blob without the profile's records with this id.
    private static func withoutProfileRecords(_ data: Data, id: Int) -> Data {
        var blob = [UInt8](data)
        for r in records(blob, 4 + summarySize(blob), blob.count).reversed() where r.id == id {
            blob.removeSubrange(r.record..<(r.data + r.length))
        }
        return Data(blob)
    }

    /// The blob with its first /Summary record renumbered, as other descriptors could (a one-byte id).
    private static func withFirstSummaryRecordID(_ data: Data, _ id: UInt8) throws -> Data {
        var blob = [UInt8](data)
        let first = try XCTUnwrap(records(blob, 4, 4 + summarySize(blob)).first)
        XCTAssertLessThan(first.id, 0xFF)
        blob[first.record] = id
        return Data(blob)
    }

    private static let logbookID: UInt32 = 1_787_699_873

    private func parse(_ data: Data) throws -> DiveData {
        try data.withUnsafeBytes { raw in
            try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 1, diveNumber: 1,
                diveData: raw.bindMemory(to: UInt8.self).baseAddress!, dataSize: data.count,
                fingerprint: withUnsafeBytes(of: Self.logbookID.littleEndian) { Data($0) },
                fallbackDate: Date(timeIntervalSince1970: TimeInterval(Self.logbookID)))
        }
    }

    private func parseError(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> Error? {
        do {
            _ = try parse(data)
            XCTFail("parsed", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The C parser's own answers, without GenericParser's fallbacks.
    private func cStatuses(_ data: Data) -> (datetime: dc_status_t, samples: dc_status_t) {
        data.withUnsafeBytes { raw in
            var parser: OpaquePointer?
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            XCTAssertEqual(create_parser_for_device(&parser, nil, DC_FAMILY_SUUNTO_NAUTIC, 1, base, data.count), DC_STATUS_SUCCESS)
            defer { dc_parser_destroy(parser) }
            var datetime = dc_datetime_t()
            return (dc_parser_get_datetime(parser, &datetime), dc_parser_samples_foreach(parser, nil, nil))
        }
    }

    // MARK: - Parser

    func testARunIsUnsupported() throws {
        let run = try syntheticRun()
        let statuses = cStatuses(run)
        XCTAssertEqual(statuses.datetime, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(statuses.samples, DC_STATUS_UNSUPPORTED)

        let error = try XCTUnwrap(parseError(run))
        guard case GenericParser.ParserError.sampleProcessingFailed(DC_STATUS_UNSUPPORTED) = error else {
            return XCTFail("\(error)")
        }
        XCTAssertTrue(DiveLogRetriever.isNonDiveActivity(error, family: DC_FAMILY_SUUNTO_NAUTIC))
    }

    func testEveryOtherSportWithoutDiveStatusRecordsIsUnsupported() throws {
        for sport: UInt8 in [0, 3, 4, 100, 255] {
            XCTAssertEqual(cStatuses(try Self.withSport(try syntheticRun(), sport)).samples, DC_STATUS_UNSUPPORTED, "sport \(sport)")
        }
    }

    func testADivingSportIsNeverSkipped() throws {
        // On the run's records, a diving sport is a dive with a damaged /Summary: a failure, not a skip.
        for sport: UInt8 in [51, 61, 62] {
            let run = try Self.withSport(try syntheticRun(), sport)
            XCTAssertEqual(cStatuses(run).samples, DC_STATUS_DATAFORMAT, "sport \(sport)")
            let error = try XCTUnwrap(parseError(run))
            XCTAssertFalse(DiveLogRetriever.isNonDiveActivity(error, family: DC_FAMILY_SUUNTO_NAUTIC), "sport \(sport)")
        }
    }

    func testAnActivityWithoutASportIsNotSkipped() throws {
        let run = try Self.withoutActivity(try syntheticRun())
        XCTAssertNil(Self.activityRecord([UInt8](run)))
        XCTAssertEqual(cStatuses(run).samples, DC_STATUS_DATAFORMAT, "no sport: a dive the parser can't read, not a skip")
    }

    func testADiveIsParsedWhateverItsSport() throws {
        let original = try parse(try dive())
        XCTAssertEqual(original.diveMode, .openCircuit)
        let cases: [(sport: UInt8?, mode: DiveData.DiveMode)] = [
            (51, .openCircuit), (61, .freedive), (62, .freedive),
            (3, .openCircuit), (99, .openCircuit), (255, .openCircuit), // unknown or not a diving sport
            (nil, .openCircuit),                                        // no activity record
        ]
        for (sport, mode) in cases {
            let blob = try sport.map { try Self.withSport(try dive(), $0) } ?? Self.withoutActivity(try dive())
            let parsed = try parse(blob)
            XCTAssertEqual(parsed.diveMode, mode, "sport \(String(describing: sport))")
            XCTAssertEqual(parsed.maxDepth, original.maxDepth, "sport \(String(describing: sport))")
            XCTAssertEqual(parsed.divetime, original.divetime, "sport \(String(describing: sport))")
            XCTAssertEqual(parsed.profile.count, original.profile.count, "sport \(String(describing: sport))")
        }
    }

    func testADiveHeaderIsDiveDataWhateverTheSport() throws {
        // A dive in a sport the table doesn't list, that never logged a dive status record, still has its dive header.
        let dive = Self.withoutProfileRecords(try Self.withSport(try dive(), 3), id: 0x16)
        XCTAssertFalse(Self.records([UInt8](dive), 4 + Self.summarySize([UInt8](dive)), dive.count).contains { $0.id == 0x16 })
        XCTAssertEqual(cStatuses(dive).samples, DC_STATUS_SUCCESS)
        let parsed = try parse(dive)
        XCTAssertEqual(parsed.diveMode, .openCircuit)
    }

    func testARunWhoseFirstRecordGetsADiveHeaderIdIsStillUnsupported() throws {
        // A Windows record (239 bytes) numbered 0x20 or 0x21 is too small for either dive header.
        for id: UInt8 in [0x20, 0x21] {
            let run = try Self.withFirstSummaryRecordID(try syntheticRun(), id)
            XCTAssertEqual(cStatuses(run).samples, DC_STATUS_UNSUPPORTED, String(format: "%02x", id))
        }
    }

    // MARK: - Retriever

    private func isNonDive(_ error: Error, _ family: dc_family_t) -> Bool {
        DiveLogRetriever.isNonDiveActivity(error, family: family)
    }

    func testOnlyTheNauticParsersUnsupportedSamplesAreANonDive() {
        typealias E = GenericParser.ParserError
        XCTAssertTrue(isNonDive(E.sampleProcessingFailed(DC_STATUS_UNSUPPORTED), DC_FAMILY_SUUNTO_NAUTIC))
        XCTAssertFalse(isNonDive(E.sampleProcessingFailed(DC_STATUS_UNSUPPORTED), DC_FAMILY_SHEARWATER_PETREL),
                       "another family's UNSUPPORTED is still a rejection")
        XCTAssertFalse(isNonDive(E.sampleProcessingFailed(DC_STATUS_UNSUPPORTED), DC_FAMILY_SUUNTO_EONSTEEL))
        XCTAssertFalse(isNonDive(E.parserCreationFailed(DC_STATUS_UNSUPPORTED), DC_FAMILY_SUUNTO_NAUTIC),
                       "no parser for the model is a configuration fault")
        XCTAssertFalse(isNonDive(E.datetimeRetrievalFailed(DC_STATUS_UNSUPPORTED), DC_FAMILY_SUUNTO_NAUTIC))
        XCTAssertFalse(isNonDive(E.fieldRetrievalFailed(DC_STATUS_UNSUPPORTED), DC_FAMILY_SUUNTO_NAUTIC))
        XCTAssertFalse(isNonDive(E.sampleProcessingFailed(DC_STATUS_DATAFORMAT), DC_FAMILY_SUUNTO_NAUTIC))
        XCTAssertFalse(isNonDive(E.invalidParameters, DC_FAMILY_SUUNTO_NAUTIC))
        XCTAssertFalse(isNonDive(CocoaError(.fileNoSuchFile), DC_FAMILY_SUUNTO_NAUTIC))
    }

    private final class Holder: RetrievalFlagHolder {
        var isRetrievingLogs = true
    }

    private let holder = Holder()
    private let serial = "nondive-\(UUID().uuidString)"
    private let deviceType = "Suunto Ocean 253810000400"

    override func tearDown() {
        DeviceFingerprintStorage.shared.setRejectedDives([], forDeviceType: deviceType, serial: serial)
        super.tearDown()
    }

    private func fingerprint(_ id: UInt32) -> Data { withUnsafeBytes(of: id.littleEndian) { Data($0) } }

    private struct Sync {
        let context: DiveLogRetriever.CallbackContext
        let outcome: DiveLogRetriever.DownloadOutcome
        let unreadable: [Data]
    }

    /// One sync of `entries`, newest first, through the retriever's own dive callback, as `dc_device_foreach`
    /// delivers them when the driver couldn't tell a run from a dive; stores the fingerprint when the outcome says to.
    private func sync(_ entries: [(data: Data, id: UInt32)], stored: inout Data?) -> Sync {
        let context = DiveLogRetriever.CallbackContext(
            viewModel: DiveDataViewModel(), deviceName: deviceType, deviceUUID: UUID().uuidString,
            storedFingerprint: stored, isCancelled: { [holder] in holder.isRetrievingLogs == false })
        context.deviceSerial = serial
        let userdata = Unmanaged.passUnretained(context).toOpaque()
        for entry in entries {
            let fp = fingerprint(entry.id)
            let more = entry.data.withUnsafeBytes { data in
                fp.withUnsafeBytes { fpBytes in
                    DiveLogRetriever.diveCallbackClosure(
                        data.bindMemory(to: UInt8.self).baseAddress, UInt32(entry.data.count),
                        fpBytes.bindMemory(to: UInt8.self).baseAddress, UInt32(fp.count), userdata)
                }
            }
            if more == 0 { break }
        }
        let (outcome, unreadable) = DiveLogRetriever.settle(status: DC_STATUS_SUCCESS, family: DC_FAMILY_SUUNTO_NAUTIC,
                                                            context: context)
        if outcome.saveFingerprint { stored = context.lastFingerprint }
        return Sync(context: context, outcome: outcome, unreadable: unreadable)
    }

    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
    }

    func testARunBetweenDivesIsSkippedWithoutAFailureAndTheFingerprintIsTheNewestDives() throws {
        let ids: [UInt32] = [1_788_300_000, 1_788_200_000, 1_788_100_000]
        var stored: Data? = fingerprint(1_788_000_000)

        let first = sync([(try dive(), ids[0]), (try syntheticRun(), ids[1]), (try dive(), ids[2])], stored: &stored)
        XCTAssertTrue(first.outcome.succeeded)
        XCTAssertTrue(first.outcome.saveFingerprint)
        XCTAssertFalse(first.outcome.parseRejected)
        XCTAssertFalse(first.outcome.interrupted)
        XCTAssertEqual(first.context.rejectedCount, 0, "a run is never held")
        XCTAssertEqual(first.context.nonDiveCount, 1)
        XCTAssertEqual(first.context.deliveredFingerprints, [fingerprint(ids[0]), fingerprint(ids[2])])
        XCTAssertEqual(first.context.logCount, 3, "two dives numbered")
        XCTAssertEqual(stored, fingerprint(ids[0]))
        XCTAssertEqual(DeviceFingerprintStorage.shared.rejectedDives(forDeviceType: deviceType, serial: serial), [],
                       "nothing for the two-strike rule to remember")
        drainMain()
        XCTAssertEqual(first.context.viewModel.dives.count, 2)
    }

    func testANewestRunNeverBecomesTheFingerprint() throws {
        let run: UInt32 = 1_788_300_000, newestDive: UInt32 = 1_788_200_000
        var stored: Data? = fingerprint(1_788_000_000)

        let first = sync([(try syntheticRun(), run), (try dive(), newestDive)], stored: &stored)
        XCTAssertTrue(first.outcome.saveFingerprint)
        XCTAssertEqual(first.context.lastFingerprint, fingerprint(newestDive))
        XCTAssertEqual(stored, fingerprint(newestDive))

        // The next sync meets the run again, skips it, and stops at the newest dive: no dive downloads again.
        let second = sync([(try syntheticRun(), run), (try dive(), newestDive), (try dive(), 1_788_100_000)], stored: &stored)
        XCTAssertTrue(second.context.fingerprintMatched)
        XCTAssertFalse(second.context.hasNewDives)
        XCTAssertEqual(second.context.nonDiveCount, 1)
        XCTAssertTrue(second.outcome.succeeded)
        XCTAssertFalse(second.outcome.saveFingerprint)
        XCTAssertEqual(stored, fingerprint(newestDive))
    }

    func testOnlyRunsSinceTheLastSyncIsNoNewDives() throws {
        var stored: Data? = fingerprint(1_788_000_000)
        let only = sync([(try syntheticRun(), 1_788_300_000), (try syntheticRun(), 1_788_200_000)], stored: &stored)
        XCTAssertTrue(only.outcome.succeeded, "not a failure")
        XCTAssertFalse(only.outcome.saveFingerprint, "a run never becomes the fingerprint")
        XCTAssertFalse(only.outcome.emptyReadOnly)
        XCTAssertEqual(only.context.nonDiveCount, 2)
        XCTAssertEqual(stored, fingerprint(1_788_000_000))
    }

    func testARunOnTwoSyncsIsStillNotUnreadable() throws {
        var stored: Data? = fingerprint(1_788_000_000)
        let entries = [(try dive(), UInt32(1_788_300_000)), (try syntheticRun(), UInt32(1_788_200_000))]
        _ = sync(entries, stored: &stored)
        stored = fingerprint(1_788_000_000)
        let second = sync(entries, stored: &stored)
        XCTAssertEqual(second.unreadable, [], "the two-strike rule never sees a run")
        XCTAssertTrue(second.outcome.succeeded)
        XCTAssertEqual(stored, fingerprint(1_788_300_000))
    }

    func testAnotherFamilysUnsupportedSamplesStillHold() throws {
        // A rejection from the session parse hook that isn't the Nautic's: the parse target here is a Shearwater.
        let context = DiveLogRetriever.CallbackContext(
            viewModel: DiveDataViewModel(), deviceName: "Shearwater Petrel 3", deviceUUID: UUID().uuidString,
            storedFingerprint: nil, isCancelled: { false }, policy: .session)
        context.detectedFamily = DC_FAMILY_SHEARWATER_PETREL
        context.detectedModel = 3
        context.parseHook = { _, _ in throw GenericParser.ParserError.sampleProcessingFailed(DC_STATUS_UNSUPPORTED) }
        let data = try dive(), fp = fingerprint(1_788_300_000)
        _ = data.withUnsafeBytes { raw in
            fp.withUnsafeBytes { fpBytes in
                DiveLogRetriever.diveCallbackClosure(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count),
                                                     fpBytes.bindMemory(to: UInt8.self).baseAddress, 4,
                                                     Unmanaged.passUnretained(context).toOpaque())
            }
        }
        XCTAssertEqual(context.nonDiveCount, 0)
        XCTAssertEqual(context.rejectedFingerprints, [fp], "held, as before")
    }
}
