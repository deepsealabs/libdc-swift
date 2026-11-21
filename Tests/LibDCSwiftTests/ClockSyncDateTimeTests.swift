import XCTest
import Clibdivecomputer
@testable import LibDCSwift

final class ClockSyncDateTimeTests: XCTestCase {

    /// 2026-07-01 10:00:00 UTC, inside northern-hemisphere DST.
    private let summer = Date(timeIntervalSince1970: 1_782_900_000)

    private func zone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier))
    }

    func testTheTimeZoneIsInSecondsEastOfUTC() throws {
        let cases: [(String, Int32)] = [
            ("UTC", 0),
            ("Europe/Berlin", 7200),
            ("Asia/Kathmandu", 20700),
            ("America/St_Johns", -9000),
            ("America/Los_Angeles", -25200),
        ]
        for (identifier, seconds) in cases {
            let dt = try XCTUnwrap(DiveLogRetriever.clockSyncDateTime(at: summer, in: zone(identifier)))
            XCTAssertEqual(dt.timezone, seconds, identifier)
        }
    }

    func testTheWallClockIsLocalTime() throws {
        let dt = try XCTUnwrap(DiveLogRetriever.clockSyncDateTime(at: summer, in: zone("Europe/Berlin")))
        XCTAssertEqual([dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second], [2026, 7, 1, 12, 0, 0])
    }

    func testLibdivecomputerReadsItBackAsTheSameInstant() throws {
        let now = summer.addingTimeInterval(0.75)
        for identifier in ["UTC", "Europe/Berlin", "Asia/Kathmandu", "America/St_Johns", "Australia/Lord_Howe"] {
            var dt = try XCTUnwrap(DiveLogRetriever.clockSyncDateTime(at: now, in: zone(identifier)))
            XCTAssertEqual(dc_datetime_mktime(&dt), 1_782_900_000, identifier)
        }
    }

    func testTheOffsetFollowsDaylightSavingAtTheGivenInstant() throws {
        let winter = Date(timeIntervalSince1970: 1_798_797_600) // 2027-01-01 10:00:00 UTC
        let dt = try XCTUnwrap(DiveLogRetriever.clockSyncDateTime(at: winter, in: zone("Europe/Berlin")))
        XCTAssertEqual(dt.timezone, 3600)
    }
}
