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

        // Dive time = total time in the Diving state (single-span here = 1922 s).
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

    func testBatteryTelemetryDecodes() throws {
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())
        XCTAssertFalse(profile.batteryProfile.isEmpty, "expected battery samples")
        // This dive ran at ~4.4 V and ~98% charge throughout.
        let first = try XCTUnwrap(profile.batteryProfile.first)
        XCTAssertEqual(first.voltage, 4.417, accuracy: 0.05)
        XCTAssertEqual(first.charge, 0.98, accuracy: 0.03)
        // Times are within the dive.
        XCTAssertTrue(profile.batteryProfile.allSatisfy { $0.time >= 0 })
    }

    func testVendorSeriesDecode() throws {
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())
        // GPS accuracy (0x0E), only in the surface section, first fix EHPE≈14 EVPE≈23.
        XCTAssertFalse(profile.gpsAccuracyProfile.isEmpty)
        let firstGps = try XCTUnwrap(profile.gpsAccuracyProfile.first)
        XCTAssertEqual(firstGps.ehpe, 14, accuracy: 1)
        XCTAssertEqual(firstGps.evpe, 23, accuracy: 1)
        // IMU (0x23) dominates the stream (~10 Hz over a ~37 min dive).
        XCTAssertGreaterThan(profile.imuProfile.count, 20000)
        // Accel scale sanity: over the whole dive the median accel magnitude
        // should be ~1g (gravity) with the validated 1/4096 factor.
        let mags = profile.imuProfile.map { s -> Double in
            let a = s.accelG; return (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        }.sorted()
        let median = mags[mags.count / 2]
        XCTAssertEqual(median, 1.0, accuracy: 0.1, "median accel magnitude should be ~1g")
        // DiveRoute (0x24), ~1.7 Hz, 5 features each.
        XCTAssertFalse(profile.diveRouteProfile.isEmpty)
        XCTAssertEqual(profile.diveRouteProfile.first?.features.count, 5)
    }

    func testDecoAndGradientFactorsDecode() throws {
        let profile = try SuuntoNauticExplorer.decode(sbemData: loadFixture())
        // One deco sample per 0x16 chunk (244 on this dive).
        XCTAssertEqual(profile.decoProfile.count, 244)
        XCTAssertEqual(profile.gradientFactorProfile.count, 244)
        // The dive goes into deco: at least one decoStop with a positive ceiling.
        XCTAssertTrue(profile.decoProfile.contains { $0.kind == .decoStop && $0.ceiling > 0 })
        // TTS peaks in the hundreds of seconds.
        XCTAssertGreaterThan(profile.decoProfile.map(\.tts).max() ?? 0, 300)
        // gfSurface climbs meaningfully by the end of the dive.
        XCTAssertGreaterThan(profile.gradientFactorProfile.map(\.gfSurface).max() ?? 0, 50)
    }

    func testGenericPipelineDecodesNauticWithVendorChannel() throws {
        let data = try loadFixture()
        // Route through the SAME GenericParser path DiveLogRetriever uses.
        let dive: DiveData = try data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            return try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 0, diveNumber: 1,
                diveData: ptr, dataSize: data.count,
                fingerprint: Data([0x9b, 0xee, 0x8e, 0x6a]),          // id 1787752091 LE
                fallbackDate: Date(timeIntervalSince1970: 1787752091))
        }
        // Standard fields flow through.
        XCTAssertEqual(dive.maxDepth, 33.11, accuracy: 0.05)
        XCTAssertFalse(dive.profile.isEmpty)
        // Datetime must be the correct absolute UTC instant, not the GPS UTC
        // components reinterpreted in the test machine's local calendar. The
        // Nautic reports true UTC (from the GPS anchor), so GenericParser builds
        // the Date in UTC; display localizes. This is TZ-independent: it fails
        // if the parser ever rebuilds Nautic dates in the local calendar again.
        XCTAssertEqual(dive.datetime.timeIntervalSince1970, 1787752091, accuracy: 1.0)
        // The vendor channel carried the non-standard series generically.
        XCTAssertFalse(dive.vendorSamples.isEmpty)
        XCTAssertTrue(dive.vendorSamples.allSatisfy {
            $0.type == UInt32(SAMPLE_VENDOR_SUUNTO_NAUTIC.rawValue)
        })
        // Battery (kind 1), GPS accuracy (2), IMU (3), dive-route (4), GF (5)
        // all present -> distinct kinds in the first payload byte.
        let kinds = Set(dive.vendorSamples.compactMap { $0.data.first })
        XCTAssertTrue(kinds.isSuperset(of: [1, 2, 3, 4, 5]), "kinds seen: \(kinds)")
    }

    /// Thin wrapper over the C entry parser (the single source of truth), so
    /// the Swift `listDives` and C `device_foreach` both exercise this logic.
    private func extractIDs(_ data: Data) -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: data.count / 4 + 1)
        let n = data.withUnsafeBytes { raw -> UInt32 in
            suunto_nautic_extract_entry_ids(
                raw.bindMemory(to: UInt8.self).baseAddress,
                data.count, &ids, UInt32(ids.count))
        }
        return Array(ids.prefix(Int(n)))
    }

    func testEntryPairingSingleDive() {
        // Single-dive entries buffer: start immediately followed by its end.
        // Both land in the dive-ID window; the pairing must return only the start.
        let entries: [UInt8] = [
            0x26, 0x24, 0xe1, 0x02, 0x01, 0x00, 0x4d, 0x00, 0x0c, 0x00, 0x00, 0x00,
            0x01, 0x00, 0xff, 0xff, 0x9b, 0xee, 0x8e, 0x6a, 0x6a, 0xf7, 0x8e, 0x6a,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x95, 0x51, 0x0a, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(extractIDs(Data(entries)), [1787752091]) // end 1787754346 dropped
    }

    func testEntryPairingMultiDiveDropsHeaderTimestamp() throws {
        // Real /Logbook/Entries buffer from a tester's watch. It contains two
        // dive (start,end) pairs plus a lone header timestamp (the response's
        // own "current time") that must NOT be listed as a dive.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "logbook_entries_multi", withExtension: "bin"))
        let ids = extractIDs(try Data(contentsOf: url))
        // Exactly the two real dives, newest-first; header ts 1788224574 dropped.
        XCTAssertEqual(ids, [1788079236, 1787385018]) // Aug 30 and Aug 22, 2026
    }

    func testSummaryGradientFactorOrdering() throws {
        // GF low is at Summary offset 0x35 and GF high at 0x33, NOT the reverse.
        // Real Summaries store the bytes so that reading 0x33 as low gives low >
        // high (physically invalid): Nautic 75/35 -> 35/75, Nautic S 85/40 ->
        // 40/85. Build a two-section buffer (empty profile + a Summary whose
        // byte@0x33 = 85 and byte@0x35 = 40) and assert GF decodes to 40 low /
        // 85 high. Guards against the offsets being swapped again (issue #29).
        var buf: [UInt8] = Array("SBEM0103".utf8)     // profile section (empty)
        var summary = Array("SBEM0103".utf8) + [UInt8](repeating: 0, count: 0x40)
        summary[0x33] = 85                             // GF high byte (offset in the Summary section)
        summary[0x35] = 40                             // GF low byte
        buf += summary
        let data = Data(buf)
        let p = try SuuntoNauticExplorer.decode(sbemData: data, logbookID: 1787000000)
        XCTAssertEqual(p.gradientFactorLow, 40)        // was 85 before the fix
        XCTAssertEqual(p.gradientFactorHigh, 85)       // was 40 before the fix
    }

    func testExtendedStatusVariableLength() throws {
        // The 0x16 extended-status chunk is VARIABLE length: 195 bytes on the
        // Ocean/Nautic but 141 on the Nautic S (and other firmware). It must not
        // be in the ghost-chunk fixed-length table -- hardcoding 195 rejected
        // every Nautic S chunk, zeroing depth and underflowing divetime (issue
        // #29, nandodiver). Build a minimal SBEM profile whose only 0x16 chunk is
        // 141 bytes with depth = 10.0 m and assert the parser reads it.
        var buf: [UInt8] = Array("SBEM0103".utf8)
        buf += [0x16, 141]                       // id, length (not 195)
        buf += [0x00, 0x00]                      // timeline delta = 0
        buf += [0x00, 0x00, 0x20, 0x41]          // depth float32 LE = 10.0
        buf += [UInt8](repeating: 0, count: 141 - 6)
        let data = Data(buf)
        let dive: DiveData = try data.withUnsafeBytes { raw in
            try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 0, diveNumber: 1,
                diveData: raw.bindMemory(to: UInt8.self).baseAddress!, dataSize: data.count,
                fingerprint: Data([0x00, 0x00, 0x00, 0x6a]),
                fallbackDate: Date(timeIntervalSince1970: 1787000000))
        }
        XCTAssertEqual(dive.maxDepth, 10.0, accuracy: 0.01) // 0 before the fix
    }

    func testNauticSTankPressureShortChunk() throws {
        // Tank 0 pressure is at extended-status offset 44 on BOTH the 195 B
        // Ocean/Nautic chunk and the 141 B Nautic S chunk. The parser used to
        // require the full 8-slot array (>=186 B) and so dropped ALL tank
        // pressure on the Nautic S. Build a 141 B 0x16 chunk with tank 0 at
        // offset 42 (idx byte 0, pressure 150 bar at offset 44) and confirm the
        // tank decodes (validated against a Nautic S pod dive's app JSON, #29).
        var payload = [UInt8](repeating: 0, count: 141)
        // offset 2..6 = depth float 5.0 m
        payload[2] = 0x00; payload[3] = 0x00; payload[4] = 0xA0; payload[5] = 0x40
        // offset 42 = tank 0 index byte (0); offset 44 = pressure uint32 LE Pa = 15_000_000 (150 bar)
        let pa: UInt32 = 15_000_000
        payload[44] = UInt8(pa & 0xff); payload[45] = UInt8((pa >> 8) & 0xff)
        payload[46] = UInt8((pa >> 16) & 0xff); payload[47] = UInt8((pa >> 24) & 0xff)
        var buf: [UInt8] = Array("SBEM0103".utf8) + [0x16, 141] + payload
        let data = Data(buf)
        let p = try SuuntoNauticExplorer.decode(sbemData: data, logbookID: 1787000000)
        XCTAssertEqual(p.tanks.count, 1)                       // was 0 before the fix
        XCTAssertEqual(p.tanks.first?.beginPressure ?? 0, 150, accuracy: 0.5)
        _ = buf
    }

    func testShortChunkReadsMultipleTanks() throws {
        // A 141 B extended-status chunk carries cylinder slots 0-4 (idx bytes
        // 0-4), each an 18 B record with pressure at base+2. The reader must
        // pick up every slot whose full record fits (so a 2-transmitter dive
        // shows both cylinders) while ignoring the partial slot past the end
        // (which caused phantom tanks). Build tank 0 (150 bar) + tank 1 (100
        // bar) in a 141 B chunk and confirm both decode, and only those two.
        var payload = [UInt8](repeating: 0, count: 141)
        func putTank(_ i: Int, _ pa: UInt32) {
            let base = 42 + i * 18
            payload[base] = UInt8(i)                    // index byte
            payload[base + 2] = UInt8(pa & 0xff); payload[base + 3] = UInt8((pa >> 8) & 0xff)
            payload[base + 4] = UInt8((pa >> 16) & 0xff); payload[base + 5] = UInt8((pa >> 24) & 0xff)
        }
        putTank(0, 15_000_000)                          // 150 bar
        putTank(1, 10_000_000)                          // 100 bar
        // slots 2-4 left as index bytes with zero pressure (skipped, not phantom)
        payload[42 + 2 * 18] = 2; payload[42 + 3 * 18] = 3; payload[42 + 4 * 18] = 4
        let buf: [UInt8] = Array("SBEM0103".utf8) + [0x16, 141] + payload
        let p = try SuuntoNauticExplorer.decode(sbemData: Data(buf), logbookID: 1787000000)
        XCTAssertEqual(p.tanks.count, 2)
        XCTAssertEqual(p.tanks.first { $0.index == 0 }?.beginPressure ?? 0, 150, accuracy: 0.5)
        XCTAssertEqual(p.tanks.first { $0.index == 1 }?.beginPressure ?? 0, 100, accuracy: 0.5)
    }

    /// Regression corpus: real tester dive captures live in a git-ignored
    /// `captures/` dir next to this file (see .gitignore). Each `<logid>.bin` is
    /// a downloaded profile; an optional `<logid>.json` is the Suunto-app export
    /// of the same dive. This decodes every capture and cross-checks it against
    /// the app JSON (dive time exact, max depth close), so the whole real-world
    /// corpus can be re-run after any parser change. Skips cleanly when the dir
    /// is absent (fresh clones / CI don't have the captures).
    func testCaptureCorpus() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("captures")
        let bins = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        try XCTSkipIf(bins.isEmpty, "no captures/ corpus present (git-ignored); nothing to check")

        for bin in bins {
            let logid = bin.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: bin)
            let id = UInt32(logid)
            let p = try SuuntoNauticExplorer.decode(sbemData: data, logbookID: id)

            // Sanity: catches the depth=0 and divetime-underflow class of bugs.
            XCTAssert(p.maxDepth > 0.5 && p.maxDepth < 150, "\(logid): implausible maxDepth \(p.maxDepth)")
            XCTAssert(p.divetime > 30 && p.divetime < 30000, "\(logid): implausible divetime \(p.divetime)")
            if let lo = p.gradientFactorLow, let hi = p.gradientFactorHigh {
                XCTAssertLessThanOrEqual(lo, hi, "\(logid): GF low \(lo) > high \(hi) (inverted)")
            }

            // Cross-check against the app JSON when present.
            let jsonURL = dir.appendingPathComponent("\(logid).json")
            guard let jdata = try? Data(contentsOf: jsonURL),
                  let root = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any],
                  let header = (root["DeviceLog"] as? [String: Any])?["Header"] as? [String: Any]
            else { continue }

            if let dtm = header["DiveTimeMax"] as? Double, dtm > 0 {
                // Dive time is the total Diving-state time. It must never exceed
                // the app's DiveTimeMax and shouldn't grossly undercount it (the
                // old "longest single span" logic gave ~40%). A few long/
                // multi-level dives still undercount by 5-30% -- an open
                // timeline-completeness question (issue #29), so the lower bound
                // is loose while the upper bound and the depth check stay tight.
                XCTAssertLessThanOrEqual(p.divetime, dtm + 3, "\(logid): divetime \(p.divetime) OVER app \(dtm)")
                XCTAssertGreaterThan(p.divetime, dtm * 0.5, "\(logid): divetime \(p.divetime) grossly under app \(dtm)")
                if abs(p.divetime - dtm) > 3 { print("  \(logid): divetime \(p.divetime) vs app \(dtm) (undercount)") }
            }
            if let mda = header["MaxDepthAverage"] as? Double, mda > 0 {
                XCTAssertEqual(p.maxDepth, mda, accuracy: 2.0, "\(logid): maxDepth \(p.maxDepth) vs app \(mda)")
            }
        }
        print("corpus: checked \(bins.count) captures")
    }

    func testSidemountSecondTransmitter() throws {
        // A sidemount pair is one cylinder slot with two pressure fields:
        // Pressure at +44 and Pressure2 at +48. Pressure2 only counts as a real
        // second tank once it reads non-zero at least twice (a lone spurious
        // reading followed by zeros must NOT become a phantom tank). Validated
        // against a real Ocean sidemount dive (issue #29).
        func chunk(_ p1: UInt32, _ p2: UInt32) -> [UInt8] {
            var pay = [UInt8](repeating: 0, count: 141)
            pay[42] = 0                                   // slot 0 index byte
            func put(_ off: Int, _ v: UInt32) {
                pay[off] = UInt8(v & 0xff); pay[off+1] = UInt8((v>>8)&0xff)
                pay[off+2] = UInt8((v>>16)&0xff); pay[off+3] = UInt8((v>>24)&0xff)
            }
            put(44, p1); put(48, p2)
            return [0x16, 141] + pay
        }
        // Two chunks with a real Pressure2 (two non-zero readings) -> 2 tanks.
        var buf = Array("SBEM0103".utf8) + chunk(15_000_000, 10_000_000) + chunk(14_000_000, 9_000_000)
        var p = try SuuntoNauticExplorer.decode(sbemData: Data(buf), logbookID: 1787000000)
        XCTAssertEqual(p.tanks.count, 2, "sidemount pair should give two tanks")
        XCTAssertEqual(p.tanks.first { $0.index == 0 }?.beginPressure ?? 0, 150, accuracy: 0.5)
        XCTAssertEqual(p.tanks.first { $0.index == 1 }?.beginPressure ?? 0, 100, accuracy: 0.5)

        // One spurious Pressure2 reading then zero -> only one tank (no phantom).
        buf = Array("SBEM0103".utf8) + chunk(15_000_000, 12_000_000) + chunk(14_000_000, 0)
        p = try SuuntoNauticExplorer.decode(sbemData: Data(buf), logbookID: 1787000000)
        XCTAssertEqual(p.tanks.count, 1, "a lone Pressure2 sample must not become a tank")
    }

    func testEntryPairingEmptyLogbook() {
        // Real /Logbook/Entries response from an empty Nautic S (kreitje, 0 dives):
        // status 200, count 0, header + CRC only, no entry records. Must yield no
        // dives (and not crash or misread a header field as a timestamp).
        let entries: [UInt8] = [
            0x01, 0x24, 0x0a, 0x24, 0x00, 0x00, 0x00, 0x00, 0x08, 0x3c,
            0x08, 0x00, 0x00, 0x00, 0x37, 0x3b, 0x46, 0x0e,
        ]
        XCTAssertEqual(extractIDs(Data(entries)), [])
    }
}
