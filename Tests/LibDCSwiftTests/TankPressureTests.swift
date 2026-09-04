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
