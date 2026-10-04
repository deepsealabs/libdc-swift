import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// Drives `GenericParser.SampleAccumulator` with synthetic libdivecomputer
/// sample callbacks, in the order a driver emits them.
final class GenericParserSampleTests: XCTestCase {

    // MARK: - Synthetic callback helpers

    private var acc = GenericParser.SampleAccumulator()

    override func setUp() {
        super.setUp()
        acc = GenericParser.SampleAccumulator()
    }

    private func time(_ seconds: Double) {
        var v = dc_sample_value_t()
        v.time = UInt32(seconds * 1000)
        acc.handle(DC_SAMPLE_TIME, v)
    }

    private func depth(_ meters: Double) {
        var v = dc_sample_value_t()
        v.depth = meters
        acc.handle(DC_SAMPLE_DEPTH, v)
    }

    private func event(_ type: UInt32, value: UInt32 = 0, flags: UInt32 = 0, time: UInt32 = 0) {
        var v = dc_sample_value_t()
        v.event.type = type
        v.event.value = value
        v.event.flags = flags
        v.event.time = time
        acc.handle(DC_SAMPLE_EVENT, v)
    }

    private func deco(_ type: dc_deco_type_t, depth: Double = 0, time: UInt32 = 0, tts: UInt32 = 0) {
        var v = dc_sample_value_t()
        v.deco.type = type.rawValue
        v.deco.depth = depth
        v.deco.time = time
        v.deco.tts = tts
        acc.handle(DC_SAMPLE_DECO, v)
    }

    private func gasmix(_ index: UInt32) {
        var v = dc_sample_value_t()
        v.gasmix = index
        acc.handle(DC_SAMPLE_GASMIX, v)
    }

    private func profile() -> [DiveProfilePoint] {
        acc.finish()
        return acc.data.profile
    }

    // MARK: - Sample timing

    func testValuesBelongToTheSampleTheyFollow() {
        time(0); depth(1.0)
        time(10); depth(5.0)
        time(20); depth(3.0)

        let points = profile()
        XCTAssertEqual(points.map(\.time), [0, 10, 20])
        XCTAssertEqual(points.map(\.depth), [1.0, 5.0, 3.0])
        XCTAssertEqual(acc.data.maxTime, 20)
    }

    func testRepeatedTimeContinuesTheSameSample() {
        time(4); depth(2.0)
        time(4); deco(DC_DECO_NDL, time: 600)
        time(4); event(SAMPLE_EVENT_BOOKMARK.rawValue)

        let points = profile()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].ndl, 600)
        XCTAssertEqual(points[0].rawEvents.count, 1)
    }

    func testValueBeforeFirstTimeOpensSampleAtZero() {
        depth(0.5)
        time(0)
        time(2); depth(1.0)

        XCTAssertEqual(profile().map(\.time), [0, 2])
    }

    func testNoCallbacksNoProfile() {
        XCTAssertTrue(profile().isEmpty)
    }

    // MARK: - Events

    func testEventCarriesPayloadOnItsOwnSample() {
        time(0); depth(10)
        time(10); depth(12)
        event(SAMPLE_EVENT_ASCENT.rawValue, value: 7, flags: SAMPLE_FLAGS_BEGIN.rawValue, time: 3)
        time(20); depth(11)

        let points = profile()
        XCTAssertEqual(points.count, 3, "an event must not add an extra profile point")
        let event = try! XCTUnwrap(points[1].rawEvents.first)
        XCTAssertEqual(event.type, .ascent)
        XCTAssertEqual(event.rawType, SAMPLE_EVENT_ASCENT.rawValue)
        XCTAssertEqual(event.value, 7)
        XCTAssertEqual(event.flags, SAMPLE_FLAGS_BEGIN.rawValue)
        XCTAssertEqual(event.timeOffset, 3)
        XCTAssertEqual(event.phase, .begin)
        XCTAssertEqual(points[1].events, [.ascent])
        XCTAssertEqual(points[1].depth, 12)
        XCTAssertTrue(points[0].rawEvents.isEmpty)
        XCTAssertTrue(points[2].rawEvents.isEmpty)
    }

    func testPhaseFromFlags() {
        time(0)
        event(SAMPLE_EVENT_PO2.rawValue, flags: SAMPLE_FLAGS_END.rawValue)
        event(SAMPLE_EVENT_PO2.rawValue, flags: SAMPLE_FLAGS_NONE.rawValue)
        event(SAMPLE_EVENT_PO2.rawValue, flags: SAMPLE_FLAGS_BEGIN.rawValue)

        XCTAssertEqual(profile()[0].rawEvents.map(\.phase), [.end, .none, .begin])
    }

    func testUnmappedEventTypesAreKeptRaw() {
        time(0)
        event(SAMPLE_EVENT_TISSUELEVEL.rawValue, value: 4)
        event(SAMPLE_EVENT_RBT.rawValue)
        event(999, value: 1)

        let point = profile()[0]
        XCTAssertEqual(point.rawEvents.map(\.type), [.tissueLevel, .rbt, .unknown(999)])
        XCTAssertTrue(point.events.isEmpty, "types without a DiveEvent case stay out of the legacy list")
    }

    func testEveryLibdivecomputerEventTypeRoundTrips() {
        let all: [(parser_sample_event_t, RawDiveEvent.EventType)] = [
            (SAMPLE_EVENT_NONE, .none), (SAMPLE_EVENT_DECOSTOP, .decoStop), (SAMPLE_EVENT_RBT, .rbt),
            (SAMPLE_EVENT_ASCENT, .ascent), (SAMPLE_EVENT_CEILING, .ceiling), (SAMPLE_EVENT_WORKLOAD, .workload),
            (SAMPLE_EVENT_TRANSMITTER, .transmitter), (SAMPLE_EVENT_VIOLATION, .violation),
            (SAMPLE_EVENT_BOOKMARK, .bookmark), (SAMPLE_EVENT_SURFACE, .surface),
            (SAMPLE_EVENT_SAFETYSTOP, .safetyStop), (SAMPLE_EVENT_GASCHANGE, .gasChange),
            (SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY, .safetyStopVoluntary),
            (SAMPLE_EVENT_SAFETYSTOP_MANDATORY, .safetyStopMandatory), (SAMPLE_EVENT_DEEPSTOP, .deepStop),
            (SAMPLE_EVENT_CEILING_SAFETYSTOP, .ceilingSafetyStop), (SAMPLE_EVENT_FLOOR, .floor),
            (SAMPLE_EVENT_DIVETIME, .diveTime), (SAMPLE_EVENT_MAXDEPTH, .maxDepth), (SAMPLE_EVENT_OLF, .olf),
            (SAMPLE_EVENT_PO2, .po2), (SAMPLE_EVENT_AIRTIME, .airTime), (SAMPLE_EVENT_RGBM, .rgbm),
            (SAMPLE_EVENT_HEADING, .heading), (SAMPLE_EVENT_TISSUELEVEL, .tissueLevel),
            (SAMPLE_EVENT_GASCHANGE2, .gasChange2),
        ]
        for (raw, expected) in all {
            XCTAssertEqual(RawDiveEvent.EventType(rawValue: raw.rawValue), expected, "\(raw)")
        }
    }

    func testLegacyEventMapping() {
        let cases: [(parser_sample_event_t, DiveEvent)] = [
            (SAMPLE_EVENT_ASCENT, .ascent), (SAMPLE_EVENT_VIOLATION, .violation),
            (SAMPLE_EVENT_DECOSTOP, .decoStop), (SAMPLE_EVENT_BOOKMARK, .bookmark),
            (SAMPLE_EVENT_SAFETYSTOP, .safetyStop(mandatory: false)),
            (SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY, .safetyStop(mandatory: false)),
            (SAMPLE_EVENT_SAFETYSTOP_MANDATORY, .safetyStop(mandatory: true)),
            (SAMPLE_EVENT_CEILING, .ceiling), (SAMPLE_EVENT_PO2, .po2), (SAMPLE_EVENT_DEEPSTOP, .deepStop),
            (SAMPLE_EVENT_GASCHANGE, .gasChange), (SAMPLE_EVENT_GASCHANGE2, .gasChange),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(RawDiveEvent(rawType: raw.rawValue, value: 0, flags: 0).legacyEvent, expected, "\(raw)")
        }
    }

    // MARK: - Gas changes

    func testGasMixChangeAddsOneGasChangeEvenWithEvent() {
        time(0); gasmix(0)
        time(10); gasmix(1)
        event(SAMPLE_EVENT_GASCHANGE.rawValue, value: 1, flags: SAMPLE_FLAGS_BEGIN.rawValue)

        let points = profile()
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].events, [], "the initial gas is not a switch")
        XCTAssertEqual(points[1].events, [.gasChange])
        XCTAssertEqual(points[1].rawEvents.map(\.value), [1])
        XCTAssertEqual(points[1].currentGas, 1)
    }

    func testUnknownGasMixIsIgnored() {
        time(0); gasmix(0)
        time(10); gasmix(UInt32.max)

        let points = profile()
        XCTAssertEqual(points[1].currentGas, 0)
        XCTAssertTrue(points[1].events.isEmpty)
    }

    // MARK: - Deco

    func testNDL() {
        time(0); deco(DC_DECO_NDL, time: 1200, tts: 0)

        let p = profile()[0]
        XCTAssertEqual(p.decoKind, .ndl)
        XCTAssertEqual(p.ndl, 1200)
        XCTAssertNil(p.decoStop)
        XCTAssertNil(p.decoTime)
        XCTAssertEqual(p.tts, 0)
    }

    func testStopTypesFillStopFields() {
        let stops: [(dc_deco_type_t, DecoKind)] = [
            (DC_DECO_SAFETYSTOP, .safetyStop), (DC_DECO_DECOSTOP, .decoStop), (DC_DECO_DEEPSTOP, .deepStop),
        ]
        for (i, (type, kind)) in stops.enumerated() {
            time(Double(i * 10)); deco(type, depth: 6.0, time: 180, tts: 420)
        }

        let points = profile()
        XCTAssertEqual(points.count, 3)
        for (point, (_, kind)) in zip(points, stops) {
            XCTAssertEqual(point.decoKind, kind)
            XCTAssertEqual(point.decoStop, 6.0)
            XCTAssertEqual(point.decoTime, 180)
            XCTAssertEqual(point.tts, 420)
            XCTAssertNil(point.ndl)
        }
    }

    func testDecoIsNotCarriedIntoLaterSamples() {
        time(0); deco(DC_DECO_DECOSTOP, depth: 9, time: 120, tts: 600)
        time(10)
        time(20); deco(DC_DECO_NDL, time: 300)

        let points = profile()
        XCTAssertEqual(points[0].decoKind, .decoStop)
        XCTAssertNil(points[1].decoKind)
        XCTAssertNil(points[1].decoStop)
        XCTAssertNil(points[1].tts)
        XCTAssertEqual(points[2].decoKind, .ndl)
        XCTAssertNil(points[2].decoStop)
        XCTAssertEqual(points[2].ndl, 300)
        XCTAssertEqual(acc.data.deco?.type, DC_DECO_NDL, "the dive summary keeps the last reported deco state")
    }

    func testUnknownDecoTypeYieldsNoDecoFields() {
        time(0); deco(dc_deco_type_t(rawValue: 42), depth: 3, time: 60, tts: 60)

        let p = profile()[0]
        XCTAssertNil(p.decoKind)
        XCTAssertNil(p.ndl)
        XCTAssertNil(p.decoStop)
    }

    // MARK: - Inert gas

    func testInertGasPartialPressuresAreNeverFabricated() {
        time(0); depth(30); gasmix(0)
        var v = dc_sample_value_t()
        v.ppo2.sensor = 0
        v.ppo2.value = 1.3
        acc.handle(DC_SAMPLE_PPO2, v)

        let p = profile()[0]
        XCTAssertEqual(p.po2, 1.3)
        XCTAssertNil(p.pn2)
        XCTAssertNil(p.phe)
    }

    // MARK: - Dive time / average depth resolution

    func testDivetimePrefersTheComputerField() {
        // Suunto Ocean 1787752091: samples run to ~37 min, the watch says 1922 s.
        XCTAssertEqual(GenericParser.resolveDivetime(field: 1922, sampleSpan: 2220), 1922)
    }

    func testDivetimeFallsBackWhenFieldMissingOrZero() {
        XCTAssertEqual(GenericParser.resolveDivetime(field: nil, sampleSpan: 2220), 2220)
        XCTAssertEqual(GenericParser.resolveDivetime(field: 0, sampleSpan: 2220), 2220)
    }

    func testDivetimeFallsBackWhenFieldOverrunsTheSamples() {
        XCTAssertEqual(GenericParser.resolveDivetime(field: 2281, sampleSpan: 2220), 2220)
        // Whole-minute dive times may round a little past the last sample.
        XCTAssertEqual(GenericParser.resolveDivetime(field: 2280, sampleSpan: 2220), 2280)
    }

    func testDivetimeUsesFieldWhenThereAreNoSamples() {
        XCTAssertEqual(GenericParser.resolveDivetime(field: 1800, sampleSpan: 0), 1800)
    }

    func testAverageDepthPrefersPlausibleField() {
        XCTAssertEqual(GenericParser.resolveAverageDepth(field: 21.5, maxDepth: 33.1, sampled: 18.0), 21.5)
        XCTAssertEqual(GenericParser.resolveAverageDepth(field: nil, maxDepth: 33.1, sampled: 18.0), 18.0)
        XCTAssertEqual(GenericParser.resolveAverageDepth(field: 0, maxDepth: 33.1, sampled: 18.0), 18.0)
        XCTAssertEqual(GenericParser.resolveAverageDepth(field: 40, maxDepth: 33.1, sampled: 18.0), 18.0)
    }

    func testMaxDepthPrefersTheComputersOwnWhenClose() {
        // #29: the watch's 25.0 m sits between samples that peak at 24.72 m.
        XCTAssertEqual(GenericParser.resolveMaxDepth(field: 25.0, sampled: 24.72), 25.0)
        XCTAssertEqual(GenericParser.resolveMaxDepth(field: nil, sampled: 24.72), 24.72)
        XCTAssertEqual(GenericParser.resolveMaxDepth(field: 0, sampled: 24.72), 24.72)
        XCTAssertEqual(GenericParser.resolveMaxDepth(field: 40, sampled: 24.72), 24.72)
        XCTAssertEqual(GenericParser.resolveMaxDepth(field: 20, sampled: 24.72), 24.72)
        XCTAssertEqual(GenericParser.resolveMaxDepth(field: .nan, sampled: 24.72), 24.72)
    }

    func testSampledAverageDepthStopsAtDiveTime() {
        // 10 m for 100 s, then 100 s logged at the surface after the dive.
        for (t, d) in [(0.0, 10.0), (100.0, 10.0), (100.0, 10.0), (101.0, 0.0), (200.0, 0.0)] {
            time(t); depth(d)
        }
        acc.finish()
        XCTAssertEqual(acc.calculateAverageDepth(upTo: 100), 10, accuracy: 0.001)
        XCTAssertLessThan(acc.calculateAverageDepth(), 6)
        // A limit between samples interpolates the partial interval.
        XCTAssertEqual(acc.calculateAverageDepth(upTo: 100.5), (10 * 100 + 7.5 * 0.5) / 100.5, accuracy: 0.001)
    }
}
