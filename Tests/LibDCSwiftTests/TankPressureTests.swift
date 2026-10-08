import XCTest
@testable import LibDCSwift

/// Regression coverage for deepsealabs/libdc-swift#41: libdivecomputer fires
/// DC_SAMPLE_PRESSURE once per transmitter, so a single sample can carry a
/// reading for several tanks. The parser must keep each against its own tank
/// index rather than collapsing to one value.
final class TankPressureTests: XCTestCase {

    func testMultipleTransmittersInOneSampleAllSurvive() {
        var sample = SampleData()

        // Two transmitters report within the same sample window (sidemount / CCR).
        sample.recordTankPressure(tank: 0, value: 200.0)
        sample.recordTankPressure(tank: 1, value: 210.0)

        XCTAssertEqual(sample.currentTankPressures[0], 200.0)
        XCTAssertEqual(sample.currentTankPressures[1], 210.0,
                       "Second transmitter must not be dropped by the first")
        XCTAssertEqual(sample.currentTankPressures.count, 2)
    }

    func testLaterReadingUpdatesItsOwnTankOnly() {
        var sample = SampleData()
        sample.recordTankPressure(tank: 0, value: 200.0)
        sample.recordTankPressure(tank: 1, value: 210.0)

        // Next window: tank 0 drops, tank 1 unchanged / not re-reported.
        sample.recordTankPressure(tank: 0, value: 190.0)

        XCTAssertEqual(sample.currentTankPressures[0], 190.0)
        XCTAssertEqual(sample.currentTankPressures[1], 210.0,
                       "Updating one tank must not disturb the other")
    }

    func testPrimaryTankPressureIsLowestIndex() {
        var sample = SampleData()
        sample.recordTankPressure(tank: 1, value: 210.0)
        sample.recordTankPressure(tank: 0, value: 200.0)

        XCTAssertEqual(sample.primaryTankPressure, 200.0,
                       "Convenience pressure should be the lowest-index tank regardless of arrival order")
    }

    func testPrimaryTankPressureNilWhenNoReadings() {
        let sample = SampleData()
        XCTAssertNil(sample.primaryTankPressure)
    }

    func testSingleTankBehavesLikeBefore() {
        var sample = SampleData()
        sample.recordTankPressure(tank: 0, value: 180.0)

        XCTAssertEqual(sample.primaryTankPressure, 180.0)
        XCTAssertEqual(sample.currentTankPressures, [0: 180.0])
    }

    func testProfilePointCarriesEveryTank() {
        let point = DiveProfilePoint(
            time: 60,
            depth: 22,
            pressure: 200.0,
            tankPressures: [0: 200.0, 1: 210.0]
        )

        XCTAssertEqual(point.pressure, 200.0)
        XCTAssertEqual(point.tankPressures[0], 200.0)
        XCTAssertEqual(point.tankPressures[1], 210.0)
    }
}

/// Parsers that only report pressure in the samples must still yield tank
/// begin/end pressures (Suunto EON Core, Aqualung i770R).
final class TankPressureFillTests: XCTestCase {

    private func point(_ time: TimeInterval, _ pressures: [Int: Double]) -> DiveProfilePoint {
        DiveProfilePoint(
            time: time,
            depth: 10,
            pressure: pressures.min(by: { $0.key < $1.key })?.value,
            tankPressures: pressures
        )
    }

    private func tank(begin: Double, end: Double, volume: Double = 12, gasMix: Int = 0) -> DiveData.Tank {
        DiveData.Tank(volume: volume, workingPressure: 232, beginPressure: begin, endPressure: end, gasMix: gasMix, usage: .none)
    }

    func testZeroBeginEndFilledFromSamples() {
        let profile = [point(0, [0: 0]), point(10, [0: 210]), point(20, [0: 150]), point(30, [0: 60]), point(40, [0: 0])]

        let tanks = GenericParser.fillTankPressures(tanks: [tank(begin: 0, end: 0)], profile: profile, gasMixCount: 1)

        XCTAssertEqual(tanks.count, 1)
        XCTAssertEqual(tanks[0].beginPressure, 210, "Leading zero readings are a transmitter not yet linked")
        XCTAssertEqual(tanks[0].endPressure, 60, "Trailing zero readings are a lost link, not an empty tank")
        XCTAssertEqual(tanks[0].volume, 12)
    }

    func testReportedPressuresAreKept() {
        let profile = [point(0, [0: 205]), point(10, [0: 70])]

        let tanks = GenericParser.fillTankPressures(tanks: [tank(begin: 200, end: 50)], profile: profile, gasMixCount: 1)

        XCTAssertEqual(tanks[0].beginPressure, 200)
        XCTAssertEqual(tanks[0].endPressure, 50)
    }

    func testOnlyMissingEndIsFilled() {
        let profile = [point(0, [0: 205]), point(10, [0: 70])]

        let tanks = GenericParser.fillTankPressures(tanks: [tank(begin: 200, end: 0)], profile: profile, gasMixCount: 1)

        XCTAssertEqual(tanks[0].beginPressure, 200)
        XCTAssertEqual(tanks[0].endPressure, 70)
    }

    func testTankSynthesizedWhenParserReportsNone() {
        let profile = [point(0, [0: 198]), point(10, [0: 120]), point(20, [0: 55])]

        let tanks = GenericParser.fillTankPressures(tanks: [], profile: profile, gasMixCount: 1)

        XCTAssertEqual(tanks.count, 1)
        XCTAssertEqual(tanks[0].beginPressure, 198)
        XCTAssertEqual(tanks[0].endPressure, 55)
        XCTAssertEqual(tanks[0].volume, 0, "Volume is unknown, not guessed")
        XCTAssertEqual(tanks[0].gasMix, 0)
    }

    func testSynthesizedTankWithoutGasMixesHasNoMixLink() {
        let tanks = GenericParser.fillTankPressures(tanks: [], profile: [point(0, [0: 200])], gasMixCount: 0)

        XCTAssertEqual(tanks.first?.gasMix, -1)
    }

    func testEachTransmitterFillsItsOwnTank() {
        let profile = [point(0, [0: 200, 1: 210]), point(10, [0: 120, 1: 190]), point(20, [0: 80])]

        let tanks = GenericParser.fillTankPressures(
            tanks: [tank(begin: 0, end: 0)], profile: profile, gasMixCount: 2)

        XCTAssertEqual(tanks.count, 2)
        XCTAssertEqual(tanks[0].beginPressure, 200)
        XCTAssertEqual(tanks[0].endPressure, 80)
        XCTAssertEqual(tanks[1].beginPressure, 210)
        XCTAssertEqual(tanks[1].endPressure, 190)
        XCTAssertEqual(tanks[1].gasMix, 1)
    }

    func testNoSamplePressureLeavesTanksUntouched() {
        let profile = [point(0, [:]), point(10, [:])]

        let unchanged = GenericParser.fillTankPressures(tanks: [tank(begin: 0, end: 0)], profile: profile, gasMixCount: 1)
        let none = GenericParser.fillTankPressures(tanks: [], profile: profile, gasMixCount: 1)

        XCTAssertEqual(unchanged[0].beginPressure, 0)
        XCTAssertEqual(unchanged[0].endPressure, 0)
        XCTAssertTrue(none.isEmpty, "No transmitter, no tank")
    }
}
