import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// Characterization (golden) tests: parse a real raw dive blob through the
/// exact `GenericParser.parseDiveData` pipeline `DiveLogRetriever` uses, and
/// compare a canonical summary against a recorded JSON golden. Unlike the
/// hand-picked field assertions elsewhere, this catches ANY unintended change
/// to the parsed output -- new/renamed/reordered profile fields, a changed
/// event, tank or gas count, etc. -- not just the fields a prior bug fix
/// happened to assert on.
///
/// One family has a raw-blob fixture today (Suunto Nautic/Ocean). Add a
/// `<family>.golden.json` alongside a new fixture as one arrives (e.g. from
/// `BLEPacketTraceRecorder`), following `goldenSummary(for:)` below.
final class GoldenParserTests: XCTestCase {

    /// A deterministic, JSON-codable digest of `DiveData`. Encoded with
    /// `.sortedKeys` so re-running never reorders the diff; every field here
    /// is part of the characterization, so adding one changes the golden.
    private struct GoldenDive: Codable, Equatable {
        struct ProfilePoint: Codable, Equatable {
            let time: Double
            let depth: Double
            let eventTypes: [String]
            let decoKind: String?
        }
        struct Tank: Codable, Equatable {
            let gasMix: Int
            let volume: Double
            let beginPressure: Double
            let endPressure: Double
        }
        struct Gas: Codable, Equatable {
            let oxygen: Double
            let helium: Double
        }
        struct VendorCounts: Codable, Equatable {
            let kind: Int
            let count: Int
        }

        let maxDepth: Double
        let avgDepth: Double
        let divetime: Double
        let minTemperature: Double?
        let maxTemperature: Double?
        let salinity: Double?
        let gfLow: UInt32?
        let gfHigh: UInt32?
        let profileCount: Int
        let firstProfilePoint: ProfilePoint?
        let lastProfilePoint: ProfilePoint?
        let totalEventCount: Int
        let tanks: [Tank]
        let gasMixes: [Gas]
        let vendorSampleCounts: [VendorCounts]
    }

    private func goldenSummary(for dive: DiveData) -> GoldenDive {
        func point(_ p: DiveProfilePoint) -> GoldenDive.ProfilePoint {
            .init(time: p.time, depth: p.depth,
                  eventTypes: p.rawEvents.map { String(describing: $0.type) }.sorted(),
                  decoKind: p.decoKind.map { String(describing: $0) })
        }
        let vendorCounts = Dictionary(grouping: dive.vendorSamples, by: { $0.data.first ?? 0 })
            .map { GoldenDive.VendorCounts(kind: Int($0.key), count: $0.value.count) }
            .sorted { $0.kind < $1.kind }

        return GoldenDive(
            maxDepth: (dive.maxDepth * 1000).rounded() / 1000,
            avgDepth: (dive.avgDepth * 1000).rounded() / 1000,
            divetime: dive.divetime,
            minTemperature: dive.minTemperature,
            maxTemperature: dive.maxTemperature,
            salinity: dive.salinity,
            gfLow: dive.decoModel?.gfLow,
            gfHigh: dive.decoModel?.gfHigh,
            profileCount: dive.profile.count,
            firstProfilePoint: dive.profile.first.map(point),
            lastProfilePoint: dive.profile.last.map(point),
            totalEventCount: dive.profile.reduce(0) { $0 + $1.rawEvents.count },
            tanks: (dive.tanks ?? []).map { .init(gasMix: $0.gasMix, volume: $0.volume, beginPressure: $0.beginPressure, endPressure: $0.endPressure) },
            gasMixes: (dive.gasMixes ?? []).map { .init(oxygen: $0.oxygen, helium: $0.helium) },
            vendorSampleCounts: vendorCounts
        )
    }

    private func encode(_ golden: GoldenDive) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(golden)
        return String(decoding: data, as: UTF8.self)
    }

    private func assertMatchesGolden(_ dive: DiveData, goldenResource: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try encode(goldenSummary(for: dive))
        guard let url = Bundle.module.url(forResource: goldenResource, withExtension: "json") else {
            XCTFail("missing golden fixture \(goldenResource).json -- record it once, then commit it", file: file, line: line)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(actual, expected, "parsed output no longer matches the recorded golden (\(goldenResource).json)", file: file, line: line)
    }

    // MARK: - Suunto Nautic / Ocean

    private func parseSuuntoNauticFixture() throws -> DiveData {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_1787752091", withExtension: "sbem"))
        let data = try Data(contentsOf: url)
        return try data.withUnsafeBytes { raw in
            try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 0, diveNumber: 1,
                diveData: raw.bindMemory(to: UInt8.self).baseAddress!, dataSize: data.count,
                fingerprint: withUnsafeBytes(of: UInt32(1787752091).littleEndian) { Data($0) },
                fallbackDate: Date(timeIntervalSince1970: 1787752091))
        }
    }

    func testSuuntoNauticGoldenMatchesRecordedSummary() throws {
        try assertMatchesGolden(parseSuuntoNauticFixture(), goldenResource: "suunto_nautic_1787752091.golden")
    }

    // Re-record after a deliberate parser change, or for a new family's
    // fixture: `swift test -Xswiftc -DRECORD_GOLDENS --filter recordGoldens`,
    // copy the printed JSON (between the markers, no trailing newline) to
    // Fixtures/<name>.golden.json, and add it to Package.swift's resources.
    #if RECORD_GOLDENS
    func testRecordGoldens() throws {
        print("GOLDEN_START suunto_nautic_1787752091")
        print(try encode(goldenSummary(for: parseSuuntoNauticFixture())))
        print("GOLDEN_END")
    }
    #endif
}
