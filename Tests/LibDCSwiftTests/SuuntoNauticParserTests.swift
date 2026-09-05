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
///
/// The Nautic driver has no family-specific decode layer any more: dives flow
/// through the standard `GenericParser.parseDiveData` pipeline, and the
/// non-standard series (battery/IMU/GPS-accuracy/dive-route/gradient-factors)
/// come through the generic `DC_SAMPLE_VENDOR` channel, decoded here by their
/// leading kind byte. A couple of things the generic `DiveData` doesn't surface
/// (the native Suunto event `value`, per-sample deco records, and the
/// `DC_FIELD_DIVETIME` field) are read straight off the C parser below.
final class SuuntoNauticParserTests: XCTestCase {

    // MARK: - Fixtures

    private func loadFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "suunto_nautic_1787752091", withExtension: "sbem"),
            "fixture missing from test bundle")
        return try Data(contentsOf: url)
    }

    // MARK: - Generic pipeline helpers

    /// Parse through the SAME `GenericParser` path `DiveLogRetriever` uses.
    private func parse(_ data: Data, logbookID: UInt32? = nil) throws -> DiveData {
        try data.withUnsafeBytes { raw in
            try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 0, diveNumber: 1,
                diveData: raw.bindMemory(to: UInt8.self).baseAddress!, dataSize: data.count,
                fingerprint: logbookID.map { withUnsafeBytes(of: $0.littleEndian) { Data($0) } },
                fallbackDate: logbookID.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    // MARK: - Vendor-channel decoders (leading byte = kind; payload little-endian)

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(UInt16(b[o]) | (UInt16(b[o + 1]) << 8)) }
    private static func i16(_ b: [UInt8], _ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))) }

    private struct Battery { let time: TimeInterval; let voltage: Double; let charge: Double }
    private struct GPSAcc { let time: TimeInterval; let ehpe: Double; let evpe: Double }
    private struct IMU { let ax: Int; let ay: Int; let az: Int
        static let accelScaleG = 1.0 / 4096.0
        var accelMagnitudeG: Double {
            let x = Double(ax) * IMU.accelScaleG, y = Double(ay) * IMU.accelScaleG, z = Double(az) * IMU.accelScaleG
            return (x * x + y * y + z * z).squareRoot()
        }
    }
    private struct GF { let gf99: Int; let gfSurface: Int; let gfLeading: Int }

    private func vendor(_ dive: DiveData, kind: UInt8, minSize: Int) -> [(time: TimeInterval, bytes: [UInt8])] {
        dive.vendorSamples.compactMap { s in
            guard s.type == UInt32(SAMPLE_VENDOR_SUUNTO_NAUTIC.rawValue) else { return nil }
            let b = [UInt8](s.data)
            guard b.count >= minSize, b.first == kind else { return nil }
            return (s.time, b)
        }
    }

    private func batteries(_ dive: DiveData) -> [Battery] {
        vendor(dive, kind: 1, minSize: 5).map { Battery(time: $0.time, voltage: Double(Self.u16($0.bytes, 1)) / 1000.0, charge: Double(Self.u16($0.bytes, 3)) / 1000.0) }
    }
    private func gpsAccuracy(_ dive: DiveData) -> [GPSAcc] {
        vendor(dive, kind: 2, minSize: 5).map { GPSAcc(time: $0.time, ehpe: Double(Self.u16($0.bytes, 1)), evpe: Double(Self.u16($0.bytes, 3))) }
    }
    private func imu(_ dive: DiveData) -> [IMU] {
        vendor(dive, kind: 3, minSize: 19).map { IMU(ax: Self.i16($0.bytes, 1), ay: Self.i16($0.bytes, 3), az: Self.i16($0.bytes, 5)) }
    }
    private func diveRouteFeatures(_ dive: DiveData) -> [[Int]] {
        vendor(dive, kind: 4, minSize: 11).map { b in (0..<5).map { Self.u16(b.bytes, 1 + $0 * 2) } }
    }
    private func gradientFactors(_ dive: DiveData) -> [GF] {
        vendor(dive, kind: 5, minSize: 7).map { GF(gf99: Self.i16($0.bytes, 1), gfSurface: Self.i16($0.bytes, 3), gfLeading: Self.i16($0.bytes, 5)) }
    }

    // MARK: - Raw C-parser access (for what DiveData doesn't carry)

    private struct EventRecord { let type: UInt32; let value: UInt32; let isBegin: Bool; let time: TimeInterval }
    private struct DecoRecord { let isDecoStop: Bool; let ceiling: Double; let tts: TimeInterval; let time: TimeInterval }

    private final class RawCollector {
        var time: TimeInterval = 0
        var events: [EventRecord] = []
        var deco: [DecoRecord] = []
    }

    /// The native Suunto event `value` (subgroup << 8 | type) and per-sample deco
    /// records aren't surfaced by the generic `DiveData`, so read them straight
    /// off the C parser via `dc_parser_samples_foreach`.
    private func rawSamples(_ data: Data) throws -> RawCollector {
        var parser: OpaquePointer?
        let status = data.withUnsafeBytes { raw -> dc_status_t in
            create_parser_for_device(&parser, nil, DC_FAMILY_SUUNTO_NAUTIC, 0,
                                     raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard status == DC_STATUS_SUCCESS, let parser else { throw XCTSkip("parser creation failed: \(status)") }
        defer { dc_parser_destroy(parser) }

        let collector = RawCollector()
        let ptr = Unmanaged.passRetained(collector).toOpaque()
        defer { Unmanaged<RawCollector>.fromOpaque(ptr).release() }

        let cb: dc_sample_callback_t = { type, valuePtr, userData in
            guard let userData, let value = valuePtr?.pointee else { return }
            let c = Unmanaged<RawCollector>.fromOpaque(userData).takeUnretainedValue()
            switch type {
            case DC_SAMPLE_TIME:
                c.time = TimeInterval(value.time) / 1000.0
            case DC_SAMPLE_EVENT:
                let isBegin = (value.event.flags & UInt32(SAMPLE_FLAGS_BEGIN.rawValue)) != 0
                c.events.append(EventRecord(type: value.event.type, value: value.event.value, isBegin: isBegin, time: c.time))
            case DC_SAMPLE_DECO:
                c.deco.append(DecoRecord(isDecoStop: value.deco.type == DC_DECO_DECOSTOP.rawValue,
                                         ceiling: value.deco.depth, tts: TimeInterval(value.deco.tts), time: c.time))
            default:
                break
            }
        }
        dc_parser_samples_foreach(parser, cb, ptr)
        return collector
    }

    /// Read a single scalar `DC_FIELD_*` off the C parser (the generic pipeline
    /// derives divetime/avgdepth from samples instead of the field, so tests
    /// that guard the field value read it directly).
    private func field<T>(_ data: Data, _ field: dc_field_type_t, flags: UInt32 = 0, into value: inout T) -> Bool {
        var parser: OpaquePointer?
        let status = data.withUnsafeBytes { raw -> dc_status_t in
            create_parser_for_device(&parser, nil, DC_FAMILY_SUUNTO_NAUTIC, 0,
                                     raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard status == DC_STATUS_SUCCESS, let parser else { return false }
        defer { dc_parser_destroy(parser) }
        return dc_parser_get_field(parser, field, flags, &value) == DC_STATUS_SUCCESS
    }

    private func diveTimeField(_ data: Data) -> UInt32 {
        var v: UInt32 = 0; _ = field(data, DC_FIELD_DIVETIME, into: &v); return v
    }

    // MARK: - Tests

    func testDecodeProfileFields() throws {
        let data = try loadFixture()
        let dive = try parse(data)
        // Dive time = total time in the Diving state (single-span here = 1922 s).
        XCTAssertEqual(diveTimeField(data), 1922, accuracy: 1)
        // Depth, in metres.
        XCTAssertEqual(dive.maxDepth, 33.11, accuracy: 0.05)
        // Sampled profile is present, with temperature.
        XCTAssertFalse(dive.profile.isEmpty)
        XCTAssertTrue(dive.profile.contains { ($0.temperature ?? 0) > 0 })
    }

    func testStartDateDerivedFromStream() throws {
        // No logbook ID passed: the parser must still recover the dive start
        // from the GPS UTC anchor in the stream. 1787752091 = 2026-08-26T13:48:11Z
        // (== 15:48:11+02:00 in the app export).
        let dive = try parse(loadFixture())
        XCTAssertEqual(dive.datetime.timeIntervalSince1970, 1787752091, accuracy: 1.0)
    }

    func testDecodeEvents() throws {
        let raw = try rawSamples(loadFixture())
        // 8 Alarm + 3 Warning + 6 Notify + 6 State + 1 GasSwitch = 24 edges.
        XCTAssertEqual(raw.events.count, 24)
        // Every event is stamped within the dive's elapsed time.
        XCTAssertTrue(raw.events.allSatisfy { $0.time >= 0 })
        // Exactly one gas switch was logged on this dive.
        let gasSwitches = raw.events.filter { $0.type == SAMPLE_EVENT_GASCHANGE.rawValue }
        XCTAssertEqual(gasSwitches.count, 1)
    }

    func testEventNativeCodesPreserved() throws {
        // The parser passes the native Suunto (subgroup, type) through the event
        // `value` as (subgroup << 8 | type), so the exact Suunto label can be
        // recovered downstream rather than the lossy libdivecomputer mapping.
        // Subgroup 0x1B = State: type 40 = "Safety stop ahead" (a look-ahead
        // prediction, NOT an actual safety stop), type 37 = "At safety stop".
        let raw = try rawSamples(loadFixture())
        let values = Set(raw.events.map(\.value))
        XCTAssertTrue(values.contains(UInt32(0x1B << 8 | 40)), "expected State/40 'Safety stop ahead'")
        XCTAssertTrue(values.contains(UInt32(0x1B << 8 | 37)), "expected State/37 'At safety stop'")
    }

    func testBatteryTelemetryDecodes() throws {
        let dive = try parse(loadFixture())
        let battery = batteries(dive)
        XCTAssertFalse(battery.isEmpty, "expected battery samples")
        // This dive ran at ~4.4 V and ~98% charge throughout.
        let first = try XCTUnwrap(battery.first)
        XCTAssertEqual(first.voltage, 4.417, accuracy: 0.05)
        XCTAssertEqual(first.charge, 0.98, accuracy: 0.03)
        XCTAssertTrue(battery.allSatisfy { $0.time >= 0 })
    }

    func testVendorSeriesDecode() throws {
        let dive = try parse(loadFixture())
        // GPS accuracy (0x0E), only in the surface section, first fix EHPE≈14 EVPE≈23.
        let gps = gpsAccuracy(dive)
        XCTAssertFalse(gps.isEmpty)
        let firstGps = try XCTUnwrap(gps.first)
        XCTAssertEqual(firstGps.ehpe, 14, accuracy: 1)
        XCTAssertEqual(firstGps.evpe, 23, accuracy: 1)
        // IMU (0x23) dominates the stream (~10 Hz over a ~37 min dive).
        let imuSamples = imu(dive)
        XCTAssertGreaterThan(imuSamples.count, 20000)
        // Accel scale sanity: over the whole dive the median accel magnitude
        // should be ~1g (gravity) with the validated 1/4096 factor.
        let mags = imuSamples.map(\.accelMagnitudeG).sorted()
        XCTAssertEqual(mags[mags.count / 2], 1.0, accuracy: 0.1, "median accel magnitude should be ~1g")
        // DiveRouteFeatures (5x uint16; app schema name). Algo inputs, not the track.
        let routes = diveRouteFeatures(dive)
        XCTAssertFalse(routes.isEmpty)
        XCTAssertEqual(routes.first?.count, 5)
    }

    func testDecoAndGradientFactorsDecode() throws {
        let data = try loadFixture()
        let raw = try rawSamples(data)
        let gf = gradientFactors(try parse(data))
        // One deco sample and one GF sample per 0x16 chunk (244 on this dive).
        XCTAssertEqual(raw.deco.count, 244)
        XCTAssertEqual(gf.count, 244)
        // The dive goes into deco: at least one decoStop with a positive ceiling.
        XCTAssertTrue(raw.deco.contains { $0.isDecoStop && $0.ceiling > 0 })
        // TTS peaks in the hundreds of seconds.
        XCTAssertGreaterThan(raw.deco.map(\.tts).max() ?? 0, 300)
        // gfSurface climbs meaningfully by the end of the dive.
        XCTAssertGreaterThan(gf.map(\.gfSurface).max() ?? 0, 50)
    }

    func testGenericPipelineDecodesNauticWithVendorChannel() throws {
        let dive = try parse(loadFixture(), logbookID: 1787752091)
        // Standard fields flow through.
        XCTAssertEqual(dive.maxDepth, 33.11, accuracy: 0.05)
        XCTAssertFalse(dive.profile.isEmpty)
        // Datetime must be the correct absolute UTC instant, not the GPS UTC
        // components reinterpreted in the test machine's local calendar.
        XCTAssertEqual(dive.datetime.timeIntervalSince1970, 1787752091, accuracy: 1.0)
        // The vendor channel carried the non-standard series generically.
        XCTAssertFalse(dive.vendorSamples.isEmpty)
        XCTAssertTrue(dive.vendorSamples.allSatisfy {
            $0.type == UInt32(SAMPLE_VENDOR_SUUNTO_NAUTIC.rawValue)
        })
        // Battery (1), GPS accuracy (2), IMU (3), dive-route (4), GF (5) present.
        let kinds = Set(dive.vendorSamples.compactMap { $0.data.first })
        XCTAssertTrue(kinds.isSuperset(of: [1, 2, 3, 4, 5]), "kinds seen: \(kinds)")
    }

    /// Thin wrapper over the C entry parser (the single source of truth), so
    /// the Swift listing and C `device_foreach` both exercise this logic.
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
        // 85 high. Guards against the offsets being swapped again.
        var buf: [UInt8] = Array("SBEM0103".utf8)     // profile section (empty)
        var summary = Array("SBEM0103".utf8) + [UInt8](repeating: 0, count: 0x40)
        summary[0x33] = 85                             // GF high byte (offset in the Summary section)
        summary[0x35] = 40                             // GF low byte
        buf += summary
        let dive = try parse(Data(buf), logbookID: 1787000000)
        XCTAssertEqual(dive.decoModel?.gfLow, 40)       // was 85 before the fix
        XCTAssertEqual(dive.decoModel?.gfHigh, 85)      // was 40 before the fix
    }

    func testExtendedStatusVariableLength() throws {
        // The 0x16 extended-status chunk is VARIABLE length: 195 bytes on the
        // Ocean/Nautic but 141 on the Nautic S (and other firmware). It must not
        // be in the ghost-chunk fixed-length table -- hardcoding 195 rejected
        // every Nautic S chunk, zeroing depth and underflowing divetime. Build a
        // minimal SBEM profile whose only 0x16 chunk is 141 bytes with
        // depth = 10.0 m and assert the parser reads it.
        var buf: [UInt8] = Array("SBEM0103".utf8)
        buf += [0x16, 141]                       // id, length (not 195)
        buf += [0x00, 0x00]                      // timeline delta = 0
        buf += [0x00, 0x00, 0x20, 0x41]          // depth float32 LE = 10.0
        buf += [UInt8](repeating: 0, count: 141 - 6)
        let dive = try parse(Data(buf), logbookID: 1787000000)
        XCTAssertEqual(dive.maxDepth, 10.0, accuracy: 0.01) // 0 before the fix
    }

    func testNauticSTankPressureShortChunk() throws {
        // Tank 0 pressure is at extended-status offset 44 on BOTH the 195 B
        // Ocean/Nautic chunk and the 141 B Nautic S chunk. The parser used to
        // require the full 8-slot array (>=186 B) and so dropped ALL tank
        // pressure on the Nautic S. Build a 141 B 0x16 chunk with tank 0 at
        // offset 42 (idx byte 0, pressure 150 bar at offset 44) and confirm the
        // tank decodes (validated against a Nautic S pod dive's app JSON).
        var payload = [UInt8](repeating: 0, count: 141)
        // offset 2..6 = depth float 5.0 m
        payload[2] = 0x00; payload[3] = 0x00; payload[4] = 0xA0; payload[5] = 0x40
        // offset 42 = tank 0 index byte (0); offset 44 = pressure uint32 LE Pa = 15_000_000 (150 bar)
        let pa: UInt32 = 15_000_000
        payload[44] = UInt8(pa & 0xff); payload[45] = UInt8((pa >> 8) & 0xff)
        payload[46] = UInt8((pa >> 16) & 0xff); payload[47] = UInt8((pa >> 24) & 0xff)
        let buf: [UInt8] = Array("SBEM0103".utf8) + [0x16, 141] + payload
        let dive = try parse(Data(buf), logbookID: 1787000000)
        XCTAssertEqual(dive.tanks?.count, 1)                       // was 0 before the fix
        XCTAssertEqual(dive.tanks?.first?.beginPressure ?? 0, 150, accuracy: 0.5)
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
        let dive = try parse(Data(buf), logbookID: 1787000000)
        let tanks = try XCTUnwrap(dive.tanks)
        XCTAssertEqual(tanks.count, 2)
        XCTAssertEqual(tanks[0].beginPressure, 150, accuracy: 0.5)
        XCTAssertEqual(tanks[1].beginPressure, 100, accuracy: 0.5)
    }

    func testMultiGasSummaryDecodesGasesVolumesAndTankLinkage() throws {
        // Multi-gas (issue #33): the /Summary carries one 45-byte record per
        // configured gas starting at 0xC7 (O2% @+1, He% @+2, cylinder water
        // capacity float32 m^3 @+9). The record index == cylinder slot ==
        // GasNumber, so tank i breathes gas i. Reproduces nandodiver's real
        // dual-transmitter dive (Air 12 L + NX26 5.7 L, issue #29): two
        // cylinders in the profile, two gas records in the Summary.
        func f32le(_ v: Float) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }

        // Profile: a 141 B extended-status chunk with slot 0 (150 bar) and
        // slot 1 (100 bar) -> tank 0 (gas 0) and tank 1 (gas 1).
        var payload = [UInt8](repeating: 0, count: 141)
        func putTank(_ i: Int, _ pa: UInt32) {
            let base = 42 + i * 18
            payload[base] = UInt8(i)
            payload[base + 2] = UInt8(pa & 0xff); payload[base + 3] = UInt8((pa >> 8) & 0xff)
            payload[base + 4] = UInt8((pa >> 16) & 0xff); payload[base + 5] = UInt8((pa >> 24) & 0xff)
        }
        putTank(0, 15_000_000)                 // 150 bar
        putTank(1, 10_000_000)                 // 100 bar
        payload[42 + 2 * 18] = 2               // slot 2 idx byte, zero pressure (skipped)

        // Summary: gas 0 = Air (21%, 12.0 L), gas 1 = NX26 (26%, 5.7 L).
        var summary = Array("SBEM0103".utf8) + [UInt8](repeating: 0, count: 0x140)
        let base = 0xC7, stride = 45
        summary[base + 0 * stride + 1] = 21    // gas 0 O2%
        summary[base + 1 * stride + 1] = 26    // gas 1 O2%
        for (i, litres) in [Float(0.012), Float(0.0057)].enumerated() {
            let off = base + i * stride + 9
            summary.replaceSubrange(off..<off + 4, with: f32le(litres))
        }

        let buf = Array("SBEM0103".utf8) + [0x16, 141] + payload + summary
        let dive = try parse(Data(buf), logbookID: 1787000000)

        let gases = try XCTUnwrap(dive.gasMixes)
        XCTAssertEqual(gases.count, 2, "both gas records must decode (stride 45)")
        XCTAssertEqual(gases[0].oxygen, 0.21, accuracy: 0.001)
        XCTAssertEqual(gases[1].oxygen, 0.26, accuracy: 0.001)

        let tanks = try XCTUnwrap(dive.tanks)
        XCTAssertEqual(tanks.count, 2)
        // Tank i is linked to gas i and carries that gas's cylinder size.
        XCTAssertEqual(tanks[0].gasMix, 0)
        XCTAssertEqual(tanks[0].volume, 12.0, accuracy: 0.05)
        XCTAssertEqual(tanks[1].gasMix, 1)
        XCTAssertEqual(tanks[1].volume, 5.7, accuracy: 0.05)
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
            let dive = try parse(data, logbookID: id)
            let divetime = Double(diveTimeField(data))

            // Sanity: catches the depth=0 and divetime-underflow class of bugs.
            XCTAssert(dive.maxDepth > 0.5 && dive.maxDepth < 150, "\(logid): implausible maxDepth \(dive.maxDepth)")
            XCTAssert(divetime > 30 && divetime < 30000, "\(logid): implausible divetime \(divetime)")
            if let lo = dive.decoModel?.gfLow, let hi = dive.decoModel?.gfHigh {
                XCTAssertLessThanOrEqual(lo, hi, "\(logid): GF low \(lo) > high \(hi) (inverted)")
            }

            // Cross-check against the app JSON when present.
            let jsonURL = dir.appendingPathComponent("\(logid).json")
            guard let jdata = try? Data(contentsOf: jsonURL),
                  let root = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any],
                  let header = (root["DeviceLog"] as? [String: Any])?["Header"] as? [String: Any]
            else { continue }

            // The high-rate IMU chunk id is firmware-dependent: 0x23 on the
            // 195 B watches (Vaasa/Nautic), 0x22 on the 141 B ones (Ylivieska/
            // Nautic S, Porvoo/Ocean). Those watches always log IMU, so assert it
            // decodes; 195 B dives can legitimately have none (some are recorded
            // with motion logging off), so they are not asserted here.
            if let dev = (header["Device"] as? [String: Any])?["Name"] as? String,
               dev == "Ylivieska" || dev == "Porvoo" {
                XCTAssert(imu(dive).count > 500,
                    "\(logid): 141 B watch (\(dev)) decoded no IMU (\(imu(dive).count)) -- chunk-id regression")
            }

            if let dtm = header["DiveTimeMax"] as? Double, dtm > 0 {
                // Dive time = total time in the Suunto "Diving" DiveState (0x1C),
                // which matches the app's DiveTimeMax exactly on every COMPLETE
                // dive in the corpus. Two captures don't match exactly:
                //  - an INCOMPLETE capture (profile ends well before the app's
                //    dive time) undercounts because part of the dive isn't in the
                //    .bin -- detected below and exempted, not a bug;
                //  - one dive (1788090406) is a ~5% outlier where the app counts
                //    mid-dive Recovering spans its own way. Left as a known limit.
                XCTAssertLessThanOrEqual(divetime, dtm + 3, "\(logid): divetime \(divetime) OVER app \(dtm)")
                let lastSample = dive.profile.last?.time ?? 0
                let incompleteCapture = lastSample < dtm - 60   // profile doesn't reach the app's dive time
                if incompleteCapture {
                    if abs(divetime - dtm) > 3 {
                        print("  \(logid): divetime \(divetime) vs app \(dtm) -- INCOMPLETE capture (profile ends at \(Int(lastSample))s)")
                    }
                } else {
                    // Complete captures must be within 6% of the app (11/13 are exact).
                    XCTAssertGreaterThan(divetime, dtm * 0.94, "\(logid): divetime \(divetime) under app \(dtm) on a complete capture")
                    if abs(divetime - dtm) > 3 { print("  \(logid): divetime \(divetime) vs app \(dtm) (outlier)") }
                }
            }
            if let mda = header["MaxDepthAverage"] as? Double, mda > 0 {
                XCTAssertEqual(dive.maxDepth, mda, accuracy: 2.0, "\(logid): maxDepth \(dive.maxDepth) vs app \(mda)")
            }

            // Dual-transmitter / multi-gas cross-check (issues #33/#34): the app
            // logs a per-sample Cylinders[] array of {GasNumber, Pressure(Pa),
            // Pressure2(Pa)}. Each populated (GasNumber, field) is one
            // transmitter's pressure curve (a sidemount pair is two curves on the
            // same GasNumber). A field that reports in only ONE sample is a lone
            // spurious blip (e.g. 1786263907 has a single 211.4 bar Pressure2 at
            // sample 7 and never again), not a real transmitter -- the parser
            // gates those out, so require >=2 readings before counting a curve.
            if let samples = (root["DeviceLog"] as? [String: Any])?["Samples"] as? [[String: Any]] {
                var raw: [String: (gas: Int, begin: Double, end: Double, count: Int)] = [:]
                for s in samples {
                    for c in (s["Cylinders"] as? [[String: Any]]) ?? [] {
                        guard let gn = c["GasNumber"] as? Int else { continue }
                        for f in ["Pressure", "Pressure2"] {
                            guard let pa = c[f] as? Double, pa > 0 else { continue }
                            let bar = pa / 100_000.0
                            let key = "\(gn)|\(f)"
                            if var cur = raw[key] { cur.end = bar; cur.count += 1; raw[key] = cur }
                            else { raw[key] = (gn, bar, bar, 1) }
                        }
                    }
                }
                let curves = raw.values.filter { $0.count >= 2 }
                    .map { (gas: $0.gas, begin: $0.begin, end: $0.end) }
                let gasNumbers = Set(curves.map { $0.gas })
                // Two captures are the verified #33/#34 acceptance dives (nandodiver:
                // Air 12 L + NX26 5.7 L, two transmitters) -- assert hard on those.
                // For the rest of the corpus a tank/curve mismatch is advisory: some
                // captures are incomplete or have a transmitter the parser doesn't yet
                // recover (tracked in #34), which shouldn't fail the whole suite.
                let verifiedMultiTx: Set<String> = ["1788596617", "1788596613"]
                if !curves.isEmpty, let tanks = dive.tanks {
                    let hard = verifiedMultiTx.contains(logid)
                    func check(_ cond: Bool, _ msg: String) {
                        if hard { XCTAssert(cond, msg) } else if !cond { print("  \(msg) [advisory]") }
                    }
                    check(tanks.count == curves.count,
                        "\(logid): parsed \(tanks.count) tanks, app has \(curves.count) transmitter curves")
                    // Greedily match each parsed tank to an app curve by pressure.
                    var remaining = curves
                    for t in tanks {
                        if let mi = remaining.firstIndex(where: {
                            abs($0.begin - t.beginPressure) < 1.5 && abs($0.end - t.endPressure) < 1.5 }) {
                            remaining.remove(at: mi)
                        } else {
                            check(false, "\(logid): tank (begin \(t.beginPressure), end \(t.endPressure)) matches no app cylinder curve")
                        }
                    }
                    // Gas linkage (issue #33): when gas mixes were decoded, the set of
                    // gas indices the tanks link to must equal the app's distinct
                    // GasNumbers. (Skipped when the capture has no /Summary and the gas
                    // is legitimately unknown.)
                    if tanks.count == curves.count, let gases = dive.gasMixes, !gases.isEmpty {
                        check(Set(tanks.map { $0.gasMix }) == gasNumbers,
                            "\(logid): tank->gas links \(Set(tanks.map { $0.gasMix })) vs app gases \(gasNumbers)")
                    }
                }
            }
        }
        print("corpus: checked \(bins.count) captures")
    }

    func testOoamDiveEndReasonDecodes() throws {
        // 0x1D Ooam is a one-shot dive-end reason: [timeDelta:2][Type:1] (no
        // Active byte, unlike the 0x18-0x1B events). No corpus dive carries one
        // (they all ended normally), so exercise it synthetically. A depth chunk
        // makes it a valid dive; the 0x1D chunk carries type 2 = Ceiling broken.
        var buf = Array("SBEM0103".utf8)
        buf += [0x16, 141, 0x00, 0x00, 0x00, 0x00, 0x20, 0x41] + [UInt8](repeating: 0, count: 141 - 6) // depth 10 m
        buf += [0x1D, 3, 0x00, 0x00, 0x02]                                                             // Ooam type 2
        let raw = try rawSamples(Data(buf))
        // Subgroup 0x1D (Ooam), type 2 = "Ceiling broken".
        XCTAssertTrue(raw.events.contains { $0.value == UInt32(0x1D << 8 | 2) },
            "expected an Ooam Ceiling-broken event; got values \(raw.events.map(\.value))")
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
        var dive = try parse(Data(buf), logbookID: 1787000000)
        XCTAssertEqual(dive.tanks?.count, 2, "sidemount pair should give two tanks")
        let tanks = try XCTUnwrap(dive.tanks)
        XCTAssertEqual(tanks[0].beginPressure, 150, accuracy: 0.5)
        XCTAssertEqual(tanks[1].beginPressure, 100, accuracy: 0.5)

        // One spurious Pressure2 reading then zero -> only one tank (no phantom).
        buf = Array("SBEM0103".utf8) + chunk(15_000_000, 12_000_000) + chunk(14_000_000, 0)
        dive = try parse(Data(buf), logbookID: 1787000000)
        XCTAssertEqual(dive.tanks?.count, 1, "a lone Pressure2 sample must not become a tank")
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
