import XCTest
import CryptoKit
import Clibdivecomputer
@testable import LibDCSwift

/// Characterization (golden) tests: parse a real raw dive blob through the
/// exact `GenericParser.parseDiveData` pipeline `DiveLogRetriever` uses, and
/// compare a canonical digest against a recorded JSON golden.
///
/// Coverage: a strided subset of profile points (every `strideStep`-th) with
/// every `DiveProfilePoint` field; min/max/non-nil-count/sum aggregates for
/// every optional per-sample field over the FULL stream; the full event list;
/// every point where deco data changes; and a SHA-256 over a fixed-point
/// (not text) encoding of every field of every point in the full stream, so a
/// change anywhere -- not just in the strided subset -- fails the test. The
/// comparison decodes the golden JSON into `GoldenDive` and compares typed
/// values (with tolerance on doubles), not the raw JSON text, so Foundation's
/// `Double`-to-string formatting can't produce a false failure.
///
/// One family has a raw-blob fixture today (Suunto Nautic/Ocean). Add a
/// `<family>.golden.json` alongside a new fixture as one arrives (e.g. from
/// `BLEPacketTraceRecorder`), following `goldenSummary(for:)` below.
final class GoldenParserTests: XCTestCase {

    private static let strideStep = 500
    private static let doubleAccuracy = 0.0005

    private struct GoldenDive: Codable {
        struct FullPoint: Codable, Equatable {
            let index: Int
            let time: Double
            let depth: Double
            let temperature: Double?
            let pressure: Double?
            let tankPressures: [Int: Double]
            let po2: Double?
            let pn2: Double?
            let phe: Double?
            let eventTypes: [String]
            let decoKind: String?
            let ndl: UInt32?
            let decoStop: Double?
            let decoTime: UInt32?
            let tts: UInt32?
            let currentGas: Int?
            let cns: Double?
            let rbt: UInt32?
            let heartbeat: UInt32?
            let bearing: UInt32?
            let setpoint: Double?
        }
        struct FieldStats: Codable, Equatable {
            let nonNilCount: Int
            let min: Double
            let max: Double
            let roundedSum: Double
        }
        struct EventRecord: Codable, Equatable {
            let pointIndex: Int
            let time: Double
            let type: String
            let flags: UInt32
            let value: UInt32
        }
        struct DecoChangePoint: Codable, Equatable {
            let pointIndex: Int
            let time: Double
            let decoKind: String?
            let ndl: UInt32?
            let decoStop: Double?
            let decoTime: UInt32?
            let tts: UInt32?
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
        let strideStep: Int
        let stridedPoints: [FullPoint]
        let fieldStats: [String: FieldStats]
        let events: [EventRecord]
        let decoChangePoints: [DecoChangePoint]
        let tanks: [Tank]
        let gasMixes: [Gas]
        let vendorSampleCounts: [VendorCounts]
        let streamSHA256: String
    }

    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    private func fullPoint(_ index: Int, _ p: DiveProfilePoint) -> GoldenDive.FullPoint {
        .init(index: index, time: round3(p.time), depth: round3(p.depth),
              temperature: p.temperature.map(round3), pressure: p.pressure.map(round3),
              tankPressures: p.tankPressures.mapValues(round3),
              po2: p.po2.map(round3), pn2: p.pn2.map(round3), phe: p.phe.map(round3),
              eventTypes: p.rawEvents.map { String(describing: $0.type) }.sorted(),
              decoKind: p.decoKind.map { String(describing: $0) },
              ndl: p.ndl, decoStop: p.decoStop.map(round3), decoTime: p.decoTime, tts: p.tts,
              currentGas: p.currentGas, cns: p.cns.map(round3),
              rbt: p.rbt, heartbeat: p.heartbeat, bearing: p.bearing, setpoint: p.setpoint.map(round3))
    }

    private func stats(_ values: [Double?]) -> GoldenDive.FieldStats? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return .init(nonNilCount: present.count, min: round3(present.min()!),
                     max: round3(present.max()!), roundedSum: round3(present.reduce(0, +)))
    }

    private func fieldStats(_ profile: [DiveProfilePoint]) -> [String: GoldenDive.FieldStats] {
        var out: [String: GoldenDive.FieldStats] = [:]
        func add(_ name: String, _ values: [Double?]) {
            if let s = stats(values) { out[name] = s }
        }
        add("temperature", profile.map(\.temperature))
        add("pressure", profile.map(\.pressure))
        add("po2", profile.map(\.po2))
        add("pn2", profile.map(\.pn2))
        add("phe", profile.map(\.phe))
        add("ndl", profile.map { $0.ndl.map(Double.init) })
        add("decoStop", profile.map(\.decoStop))
        add("decoTime", profile.map { $0.decoTime.map(Double.init) })
        add("tts", profile.map { $0.tts.map(Double.init) })
        add("currentGas", profile.map { $0.currentGas.map(Double.init) })
        add("cns", profile.map(\.cns))
        add("rbt", profile.map { $0.rbt.map(Double.init) })
        add("heartbeat", profile.map { $0.heartbeat.map(Double.init) })
        add("bearing", profile.map { $0.bearing.map(Double.init) })
        add("setpoint", profile.map(\.setpoint))
        add("tankPressure", profile.flatMap { $0.tankPressures.values }.map { Optional($0) })
        return out
    }

    private func events(_ profile: [DiveProfilePoint]) -> [GoldenDive.EventRecord] {
        profile.enumerated().flatMap { index, p in
            p.rawEvents.map {
                .init(pointIndex: index, time: round3(p.time), type: String(describing: $0.type),
                      flags: $0.flags, value: $0.value)
            }
        }
    }

    private struct DecoKey: Equatable {
        let decoKind: String?
        let ndl: UInt32?
        let decoStop: Double?
        let decoTime: UInt32?
        let tts: UInt32?
    }

    private func decoChangePoints(_ profile: [DiveProfilePoint]) -> [GoldenDive.DecoChangePoint] {
        var out: [GoldenDive.DecoChangePoint] = []
        var last: DecoKey?
        for (index, p) in profile.enumerated() {
            let key = DecoKey(decoKind: p.decoKind.map { String(describing: $0) }, ndl: p.ndl,
                               decoStop: p.decoStop.map(round3), decoTime: p.decoTime, tts: p.tts)
            if last != Optional(key) {
                out.append(.init(pointIndex: index, time: round3(p.time), decoKind: key.decoKind,
                                  ndl: key.ndl, decoStop: key.decoStop, decoTime: key.decoTime, tts: key.tts))
                last = key
            }
        }
        return out
    }

    /// Fixed-point (never text) encoding of every field of every point in the
    /// full stream, so the hash can't drift with `Double`'s string formatting
    /// and a change anywhere in the stream -- not just the strided subset --
    /// changes it.
    private func streamSHA256(_ profile: [DiveProfilePoint]) -> String {
        var hasher = SHA256()
        func feed(_ v: Int64) {
            withUnsafeBytes(of: v.littleEndian) { hasher.update(data: Data($0)) }
        }
        func feedDouble(_ v: Double?) {
            feed(v.map { Int64(($0 * 1000).rounded()) } ?? Int64.min)
        }
        func feedUInt(_ v: UInt32?) {
            feed(v.map { Int64($0) } ?? Int64.min)
        }
        func decoCode(_ k: DecoKind?) -> Int64 {
            guard let k else { return 0 }
            switch k {
            case .ndl: return 1
            case .safetyStop: return 2
            case .decoStop: return 3
            case .deepStop: return 4
            }
        }
        for p in profile {
            feedDouble(p.time)
            feedDouble(p.depth)
            feedDouble(p.temperature)
            feedDouble(p.pressure)
            for key in p.tankPressures.keys.sorted() {
                feed(Int64(key))
                feedDouble(p.tankPressures[key])
            }
            feedDouble(p.po2)
            feedDouble(p.pn2)
            feedDouble(p.phe)
            feed(decoCode(p.decoKind))
            feedUInt(p.ndl)
            feedDouble(p.decoStop)
            feedUInt(p.decoTime)
            feedUInt(p.tts)
            feed(Int64(p.currentGas ?? Int(Int32.min)))
            feedDouble(p.cns)
            feedUInt(p.rbt)
            feedUInt(p.heartbeat)
            feedUInt(p.bearing)
            feedDouble(p.setpoint)
            let sortedEvents = p.rawEvents.sorted {
                $0.rawType != $1.rawType ? $0.rawType < $1.rawType :
                $0.value != $1.value ? $0.value < $1.value : $0.flags < $1.flags
            }
            for e in sortedEvents {
                feed(Int64(e.rawType))
                feed(Int64(e.value))
                feed(Int64(e.flags))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func goldenSummary(for dive: DiveData) -> GoldenDive {
        let profile = dive.profile
        let strided = stride(from: 0, to: profile.count, by: Self.strideStep).map { fullPoint($0, profile[$0]) }
        return GoldenDive(
            maxDepth: round3(dive.maxDepth),
            avgDepth: round3(dive.avgDepth),
            divetime: dive.divetime,
            minTemperature: dive.minTemperature.map(round3),
            maxTemperature: dive.maxTemperature.map(round3),
            salinity: dive.salinity.map(round3),
            gfLow: dive.decoModel?.gfLow,
            gfHigh: dive.decoModel?.gfHigh,
            profileCount: profile.count,
            strideStep: Self.strideStep,
            stridedPoints: strided,
            fieldStats: fieldStats(profile),
            events: events(profile),
            decoChangePoints: decoChangePoints(profile),
            tanks: (dive.tanks ?? []).map { .init(gasMix: $0.gasMix, volume: $0.volume, beginPressure: $0.beginPressure, endPressure: $0.endPressure) },
            gasMixes: (dive.gasMixes ?? []).map { .init(oxygen: $0.oxygen, helium: $0.helium) },
            vendorSampleCounts: Dictionary(grouping: dive.vendorSamples, by: { $0.data.first ?? 0 })
                .map { GoldenDive.VendorCounts(kind: Int($0.key), count: $0.value.count) }
                .sorted { $0.kind < $1.kind },
            streamSHA256: streamSHA256(profile)
        )
    }

    private func encode(_ golden: GoldenDive) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(golden)
        return String(decoding: data, as: UTF8.self)
    }

    private func assertClose(_ actual: Double?, _ expected: Double?, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (nil, nil):
            return
        case let (a?, e?):
            XCTAssertEqual(a, e, accuracy: Self.doubleAccuracy, label, file: file, line: line)
        default:
            XCTFail("\(label): expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
        }
    }

    private func assertMatchesGolden(_ dive: DiveData, goldenResource: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = goldenSummary(for: dive)
        guard let url = Bundle.module.url(forResource: goldenResource, withExtension: "json") else {
            XCTFail("missing golden fixture \(goldenResource).json -- record it once, then commit it", file: file, line: line)
            return
        }
        let expected = try JSONDecoder().decode(GoldenDive.self, from: Data(contentsOf: url))

        assertClose(actual.maxDepth, expected.maxDepth, "maxDepth", file: file, line: line)
        assertClose(actual.avgDepth, expected.avgDepth, "avgDepth", file: file, line: line)
        assertClose(actual.divetime, expected.divetime, "divetime", file: file, line: line)
        assertClose(actual.minTemperature, expected.minTemperature, "minTemperature", file: file, line: line)
        assertClose(actual.maxTemperature, expected.maxTemperature, "maxTemperature", file: file, line: line)
        assertClose(actual.salinity, expected.salinity, "salinity", file: file, line: line)
        XCTAssertEqual(actual.gfLow, expected.gfLow, "gfLow", file: file, line: line)
        XCTAssertEqual(actual.gfHigh, expected.gfHigh, "gfHigh", file: file, line: line)
        XCTAssertEqual(actual.profileCount, expected.profileCount, "profileCount", file: file, line: line)
        XCTAssertEqual(actual.strideStep, expected.strideStep, "strideStep", file: file, line: line)
        XCTAssertEqual(actual.stridedPoints, expected.stridedPoints, "stridedPoints", file: file, line: line)
        XCTAssertEqual(actual.fieldStats, expected.fieldStats, "fieldStats", file: file, line: line)
        XCTAssertEqual(actual.events, expected.events, "events", file: file, line: line)
        XCTAssertEqual(actual.decoChangePoints, expected.decoChangePoints, "decoChangePoints", file: file, line: line)
        XCTAssertEqual(actual.tanks, expected.tanks, "tanks", file: file, line: line)
        XCTAssertEqual(actual.gasMixes, expected.gasMixes, "gasMixes", file: file, line: line)
        XCTAssertEqual(actual.vendorSampleCounts, expected.vendorSampleCounts, "vendorSampleCounts", file: file, line: line)
        XCTAssertEqual(actual.streamSHA256, expected.streamSHA256,
            "full-stream hash changed -- a field changed somewhere outside the strided subset above", file: file, line: line)
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
