import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// Regression test for the Suunto Nautic/Ocean SBEM parser.
///
/// The fixture `suunto_nautic_1787752091.sbem` is a real, already-decompressed
/// dive downloaded from a Suunto Ocean (logbook id 1787752091, captured for
/// issue #29). The expected values below are cross-checked against the official
/// Suunto app's JSON export of the same dive:
///   DiveTimeMax = 1922 s, MaxDepthAverage = 33.12 m, DepthAverage = 21.51 m.
/// The event count (24) is the number of Alarm/Warning/Notify/State/GasSwitch
/// edges the app logged for this dive.
final class SuuntoNauticParserTests: XCTestCase {

    private func loadFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "suunto_nautic_1787752091", withExtension: "sbem"),
            "fixture missing from test bundle")
        return try Data(contentsOf: url)
    }

    func testDecodeProfileFields() throws {
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())

        // Dive time = the longest Diving span (spurious startup blips excluded).
        XCTAssertEqual(profile.divetime, 1922, accuracy: 1)
        // Depth, in metres.
        XCTAssertEqual(profile.maxDepth, 33.11, accuracy: 0.05)
        XCTAssertEqual(profile.avgDepth, 21.24, accuracy: 0.1)
        // Sampled profile is present.
        XCTAssertFalse(profile.depthProfile.isEmpty)
        XCTAssertGreaterThan(profile.temperatureProfile.count, 0)
    }

    func testStartDateDerivedFromStream() throws {
        // No logbook ID passed: the parser must still recover the dive start
        // from the GPS UTC anchor in the stream. 1787752091 = 2026-08-26T13:48:11Z
        // (== 15:48:11+02:00 in the app export).
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())
        let start = try XCTUnwrap(profile.startDate)
        XCTAssertEqual(start.timeIntervalSince1970, 1787752091, accuracy: 1.0)
    }

    func testDecodeEvents() throws {
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())

        // 8 Alarm + 3 Warning + 6 Notify + 6 State + 1 GasSwitch = 24 edges.
        XCTAssertEqual(profile.events.count, 24)
        // Every event is stamped within the dive's elapsed time.
        for event in profile.events {
            XCTAssertGreaterThanOrEqual(event.time, 0)
        }
        // Exactly one gas switch was logged on this dive.
        let gasSwitches = profile.events.filter { $0.type == SAMPLE_EVENT_GASCHANGE.rawValue }
        XCTAssertEqual(gasSwitches.count, 1)
    }

    func testEventLabelsUseNativeSuuntoNames() throws {
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())
        let labels = profile.events.map(\.label)
        // The event at ~69 s is "Safety Stop Ahead" (a look-ahead prediction),
        // NOT an actual safety stop — the native label must be preserved rather
        // than flattened to "Safety stop".
        XCTAssertTrue(labels.contains { $0.hasPrefix("Safety stop ahead") },
            "expected a 'Safety stop ahead' event; got \(labels)")
        // And a real "At safety stop" appears later in the dive.
        XCTAssertTrue(labels.contains { $0.hasPrefix("At safety stop") },
            "expected an 'At safety stop' event; got \(labels)")
    }

    func testDiveEntryPairingReturnsOneDive() {
        // Real /Logbook/Entries buffer for a single dive (start immediately
        // followed by its end timestamp). Both land in the dive-ID window, so a
        // naive scan lists two dives; the pairing must return only the start.
        let entries: [UInt8] = [
            0x26, 0x24, 0xe1, 0x02, 0x01, 0x00, 0x4d, 0x00, 0x0c, 0x00, 0x00, 0x00,
            0x01, 0x00, 0xff, 0xff, 0x9b, 0xee, 0x8e, 0x6a, 0x6a, 0xf7, 0x8e, 0x6a,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x95, 0x51, 0x0a, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        let ids = SuuntoNauticExplorer.parseDiveEntries(Data(entries))
        XCTAssertEqual(ids, [1787752091]) // start only; 1787754346 (end) dropped
    }
}
