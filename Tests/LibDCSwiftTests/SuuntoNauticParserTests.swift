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
}
