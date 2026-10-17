#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A Cobalt conversation written out exchange by exchange (version 0x01, first dive 0x09, next dive 0x0A) and played to libdivecomputer's driver through `ScriptedStream`, which fails on anything it doesn't expect.
final class USBReplayTests: XCTestCase {
    private static let version = Array("00012345".utf8) + FakeCobalt.le16(2) + FakeCobalt.le16(7) + FakeCobalt.le16(2)
    private static let newer = CobaltDive.make(year: 2001, month: 2, day: 4, hour: 11, minute: 25,
                                               depthsMbar: CobaltDive.profile(20, maxMbar: 1900))
    private static let older = CobaltDive.make(year: 2001, month: 2, day: 3, hour: 9, minute: 10,
                                               depthsMbar: CobaltDive.profile(14, maxMbar: 1200))
    private static let endOfDives: [UInt8] = [0xFF, 0xFF]

    private static func command(_ bRequest: UInt8) -> DCRecording.Exchange {
        .ioctl(request: USBControl.controlWrite, input: USBControl.command(bRequest), output: [], status: DC_STATUS_SUCCESS)
    }

    private static func read(_ data: [UInt8], status: dc_status_t = DC_STATUS_SUCCESS, size: Int = 8192) -> DCRecording.Exchange {
        .read(size: size, data: data, status: status)
    }

    /// atomics_cobalt_device_open: the 2 s timeout, then the version and its checksum.
    private static let opening: [DCRecording.Exchange] = [
        .setTimeout(2000, status: DC_STATUS_SUCCESS),
        command(FakeCobalt.cmdVersion),
        read(FakeCobalt.withChecksum(version), size: 16),
    ]

    /// Each dive after its command, newest first, then the two 0xFF bytes that end the walk.
    private static func walk(_ replies: [[DCRecording.Exchange]]) -> [DCRecording.Exchange] {
        var exchanges = opening
        for (index, reply) in replies.enumerated() {
            exchanges.append(command(index == 0 ? FakeCobalt.cmdFirstDive : FakeCobalt.cmdNextDive))
            exchanges += reply
        }
        exchanges.append(command(replies.isEmpty ? FakeCobalt.cmdFirstDive : FakeCobalt.cmdNextDive))
        exchanges.append(read(endOfDives))
        exchanges.append(.close(status: DC_STATUS_SUCCESS))
        return exchanges
    }

    private func replay(_ exchanges: [DCRecording.Exchange]) throws -> (result: DiveDownloadResult, dives: [DiveData], script: ScriptedStream) {
        let recording = DCRecording(transport: DC_TRANSPORT_USB, family: DC_FAMILY_ATOMICS_COBALT, model: 2, exchanges: exchanges)
        return try replayDownload(recording, displayName: "Atomic Aquatics Cobalt 2")
    }

    func testAScriptedCobaltDownloadsBothDives() throws {
        let (result, dives, script) = try replay(Self.walk([
            [Self.read(FakeCobalt.withChecksum(Self.newer))],
            [Self.read(FakeCobalt.withChecksum(Self.older))],
        ]))
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete, "played \(script.consumed) of \(script.exchanges.count)")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.divesDownloaded, 2)
        XCTAssertEqual(dives.map(\.profile.count).sorted(), [14, 20])
        XCTAssertEqual(result.identity?.serial, String(format: "%08x", 12_345))
        XCTAssertEqual(result.identity?.firmware, String((2 << 16) + 7), "firmware words 8 and 10 of the version")
        XCTAssertEqual(result.identity?.canonicalName, "Atomic Aquatics Cobalt 2")
        XCTAssertEqual(result.identity?.transport, .usb)
        XCTAssertEqual(result.fingerprintCommit?.fingerprint, CobaltDive.fingerprint(Self.newer))
    }

    func testAnEmptyLogbookIsJustTheEndMarker() throws {
        let (result, dives, script) = try replay(Self.walk([]))
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(dives.count, 0)
        XCTAssertNil(result.fingerprintCommit)
    }

    func testADiveEndedByATimeoutKeepsItsPartialCount() throws {
        let (result, dives, script) = try replay(Self.walk([
            [Self.read(FakeCobalt.withChecksum(Self.newer), status: DC_STATUS_TIMEOUT)],
        ]))
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(result.outcome, .completed, "atomics_cobalt.c takes a timed-out read's bytes as the end of the dive")
        XCTAssertEqual(dives.first?.profile.count, 20)
    }

    func testADiveSpanningReadsIsJoined() throws {
        let long = CobaltDive.make(year: 2001, month: 2, day: 5, hour: 7, minute: 0,
                                   depthsMbar: CobaltDive.profile(600, maxMbar: 2600), interval: 10)
        let wire = FakeCobalt.withChecksum(long)
        let (result, dives, script) = try replay(Self.walk([
            [Self.read(Array(wire.prefix(8192))), Self.read(Array(wire.dropFirst(8192)))],
        ]))
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(dives.first?.profile.count, 600)

        // Exactly one full read: the driver reads again, and the next read's timeout with nothing ends the dive.
        let full = CobaltDive.make(year: 2001, month: 2, day: 6, hour: 7, minute: 0,
                                   depthsMbar: CobaltDive.profile(496, maxMbar: 1800), interval: 10,
                                   trailer: [UInt8](repeating: 0, count: 8))
        let exact = try replay(Self.walk([
            [Self.read(FakeCobalt.withChecksum(full)), Self.read([], status: DC_STATUS_TIMEOUT)],
        ]))
        XCTAssertTrue(exact.script.isComplete)
        XCTAssertEqual(exact.result.outcome, .completed)
        XCTAssertEqual(exact.dives.first?.profile.count, 496)
    }

    func testABadDiveChecksumFailsTheWalk() throws {
        var corrupt = FakeCobalt.withChecksum(Self.newer)
        corrupt[corrupt.count - 1] ^= 0xFF
        var exchanges = Self.opening
        exchanges += [Self.command(FakeCobalt.cmdFirstDive), Self.read(corrupt), .close(status: DC_STATUS_SUCCESS)]
        let (result, dives, script) = try replay(exchanges)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete, "nothing more is asked of the computer")
        XCTAssertEqual(result.outcome, .failed(DC_STATUS_PROTOCOL))
        XCTAssertEqual(dives.count, 0)
        XCTAssertNil(result.fingerprintCommit)
    }

    func testAFailedControlTransferFailsTheWalk() throws {
        var exchanges = Self.opening
        exchanges += [
            .ioctl(request: USBControl.controlWrite, input: USBControl.command(FakeCobalt.cmdFirstDive), output: [],
                   status: DC_STATUS_IO),
            .close(status: DC_STATUS_SUCCESS),
        ]
        let (result, _, script) = try replay(exchanges)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(result.outcome, .failed(DC_STATUS_IO))
    }
}
#endif
