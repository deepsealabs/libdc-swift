import XCTest
@testable import LibDCSwift

/// Coverage for the empty-read guard (deepsealabs/currents DEE-44).
///
/// On the Suunto NG family a contended BLE stream (the official Suunto app
/// still holding the link) lets enumeration succeed while the data payload
/// comes back empty. libdivecomputer still hands us a record, which parses
/// into a degenerate `DiveData` (no profile samples, ~0 duration). Persisting
/// it produces a phantom dive (max depth ~1.4 m, 0 min, flat pressure) and,
/// worse, burns the fingerprint so a later clean retry reports "no new dives"
/// forever. `DiveLogRetriever.isEmptyRead` is the gate that classifies these.
final class EmptyReadTests: XCTestCase {

    /// Builds a DiveData varying only what the guard inspects.
    private func makeDive(profile: [DiveProfilePoint], divetime: TimeInterval) -> DiveData {
        DiveData(
            number: 1,
            datetime: Date(timeIntervalSince1970: 1_787_000_000),
            maxDepth: profile.map(\.depth).max() ?? 1.4,
            avgDepth: 0,
            divetime: divetime,
            temperature: 21,
            profile: profile,
            tankPressure: [],
            gasMix: nil,
            gasMixCount: nil,
            gasMixes: nil,
            salinity: nil,
            atmospheric: nil,
            surfaceTemperature: nil,
            minTemperature: nil,
            maxTemperature: nil,
            tankCount: nil,
            tanks: nil,
            diveMode: nil,
            decoModel: nil,
            location: nil,
            rbt: nil,
            heartbeat: nil,
            bearing: nil,
            setpoint: nil,
            ppo2Readings: [],
            cns: nil,
            decoStop: nil
        )
    }

    private func sample(_ time: TimeInterval, _ depth: Double) -> DiveProfilePoint {
        DiveProfilePoint(time: time, depth: depth)
    }

    func testNoSamplesAndZeroDurationIsEmptyRead() {
        // Jeroen's exact case: a "dive" with no profile and no time.
        let dive = makeDive(profile: [], divetime: 0)
        XCTAssertTrue(DiveLogRetriever.isEmptyRead(dive))
    }

    func testRealDiveWithSamplesIsNotEmptyRead() {
        let profile = (0...30).map { sample(TimeInterval($0 * 2), Double($0) * 0.1) }
        let dive = makeDive(profile: profile, divetime: 60)
        XCTAssertFalse(DiveLogRetriever.isEmptyRead(dive))
    }

    func testGenuineUltraShortDiveIsNotDropped() {
        // A very short real dive still carries samples -- the guard requires
        // BOTH conditions precisely so this is never mistaken for empty.
        let profile = [sample(0, 0.5), sample(1, 1.2)]
        let dive = makeDive(profile: profile, divetime: 1)
        XCTAssertFalse(DiveLogRetriever.isEmptyRead(dive))
    }

    func testSamplesButZeroReportedDurationIsNotEmptyRead() {
        // Has real samples; only requiring both conditions keeps this dive.
        let profile = [sample(0, 0.5), sample(2, 3.0), sample(4, 1.0)]
        let dive = makeDive(profile: profile, divetime: 0)
        XCTAssertFalse(DiveLogRetriever.isEmptyRead(dive))
    }

    func testEmptyReadProgressIsDistinctFromNoNewDives() {
        XCTAssertNotEqual(
            DiveDataViewModel.DownloadProgress.emptyRead,
            DiveDataViewModel.DownloadProgress.noNewDives
        )
        XCTAssertEqual(
            DiveDataViewModel.DownloadProgress.emptyRead,
            DiveDataViewModel.DownloadProgress.emptyRead
        )
    }
}
