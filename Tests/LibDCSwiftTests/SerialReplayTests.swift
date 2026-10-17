#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A classic OSTC download recorded over a real serial port, then replayed through `ScriptedStream`.
final class SerialReplayTests: XCTestCase {

    /// The classic OSTC (Mk2, 2N, 2C) as hw_ostc.c reads it: 'a' gets a 266-byte header, then the profile memory.
    final class FakeOSTC: FakeSerialDevice {
        static let headerSize = 266
        /// Firmware up to 1.90 (0x015A) sends 32 KB.
        static let profileSize = 0x8000

        let image: [UInt8]
        private var tx: [UInt8] = []
        private var txIndex = 0
        private let lock = NSLock()

        init(serial: UInt16, firmware: UInt16 = 0x0140, dives: [[UInt8]]) {
            var header = [UInt8](repeating: 0, count: Self.headerSize)
            header.replaceSubrange(0..<6, with: [0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x55])
            header[6] = UInt8(serial & 0xFF)
            header[7] = UInt8(serial >> 8)
            header[264] = UInt8(firmware >> 8)
            header[265] = UInt8(firmware & 0xFF)
            // Erased memory, with the dives oldest first; the driver walks back from the end.
            var profile = [UInt8](repeating: 0xFF, count: Self.profileSize)
            var offset = 0
            for dive in dives {
                profile.replaceSubrange(offset..<(offset + dive.count), with: dive)
                offset += dive.count
            }
            image = header + profile
        }

        func hostWrote(_ bytes: UnsafeRawBufferPointer) {
            lock.lock(); defer { lock.unlock() }
            if bytes.contains(UInt8(ascii: "a")) { tx += image }
        }

        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = min(size, tx.count - txIndex)
            guard n > 0 else { return 0 }
            tx.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + txIndex, byteCount: n) }
            txIndex += n
            return n
        }
    }

    /// A profile version 0x20 record as hw_ostc_parser.c reads it; `end` (month, day, year - 2000, hour, minute) is also the fingerprint.
    static func dive(end: [UInt8], depthsCm: [UInt16], samplerate: UInt8 = 10, temperatureDeciC: UInt16 = 215) -> [UInt8] {
        precondition(end.count == 5)
        var h = [UInt8](repeating: 0, count: 47)
        h[0] = 0xFA; h[1] = 0xFA; h[2] = 0x20
        h.replaceSubrange(3..<8, with: end)
        let maxDepth = depthsCm.max() ?? 0
        h[8] = UInt8(maxDepth & 0xFF); h[9] = UInt8(maxDepth >> 8)
        let seconds = depthsCm.count * Int(samplerate)
        h[10] = UInt8((seconds / 60) & 0xFF); h[11] = UInt8((seconds / 60) >> 8); h[12] = UInt8(seconds % 60)
        h[13] = UInt8(temperatureDeciC & 0xFF); h[14] = UInt8(temperatureDeciC >> 8)
        h[15] = 0xF5; h[16] = 0x03 // 1013 mbar
        for (i, o2) in [21, 32, 36, 50, 100].enumerated() { h[19 + 2 * i] = UInt8(o2) }
        h[31] = 1 // the first gas to start
        h[32] = 0x01; h[33] = 0x40 // firmware 1.64
        h[36] = samplerate
        h[37] = 0x26 // temperature: 2 bytes every 6th sample; the other five sample kinds off
        h[43] = 103 // salt water
        var samples: [UInt8] = []
        for (i, depth) in depthsCm.enumerated() {
            samples += [UInt8(depth & 0xFF), UInt8(depth >> 8)]
            if (i + 1) % 6 == 0 {
                samples += [0x02, UInt8(temperatureDeciC & 0xFF), UInt8(temperatureDeciC >> 8)]
            } else {
                samples.append(0x00)
            }
        }
        return h + samples + [0xFD, 0xFD]
    }

    // Synthetic values throughout: a made-up serial, made-up dates, no positions.
    private static let rawSerial: UInt16 = 0x04D2
    private static let scrubbedSerial: UInt16 = 0x0539
    private static let olderEnd: [UInt8] = [2, 3, 1, 4, 35]
    private static let newerEnd: [UInt8] = [2, 3, 1, 7, 12]
    private static let olderDepths: [UInt16] = [150, 420, 880, 1210, 1460, 1525, 1490, 1320, 990, 640, 410, 300, 300, 260, 120, 40]
    private static let newerDepths: [UInt16] = [180, 510, 920, 1480, 1850, 1830, 1610, 1240, 870, 520, 330, 310, 290, 90]
    private static let fixtureName = "hw_ostc_mk2_synthetic"

    private func fakeOSTC() -> FakeOSTC {
        FakeOSTC(serial: Self.rawSerial, dives: [
            Self.dive(end: Self.olderEnd, depthsCm: Self.olderDepths),
            Self.dive(end: Self.newerEnd, depthsCm: Self.newerDepths),
        ])
    }

    private var links: [PtyLink] = []

    override func tearDown() {
        links.forEach { $0.close() }
        links.removeAll()
        super.tearDown()
    }

    private func model() throws -> DCModel { try CableFixtures.model("Heinrichs Weikamp OSTC Mk2") }

    private static let scrubber = DCRecordScrubber.replacing([
        (pattern: [UInt8(rawSerial & 0xFF), UInt8(rawSerial >> 8)], replacement: [UInt8(scrubbedSerial & 0xFF), UInt8(scrubbedSerial >> 8)]),
    ])

    /// A live download over a pty through `DiveComputerSession.open`, recorded and scrubbed.
    private func recordOverASerialPort() throws -> (result: DiveDownloadResult, dives: [DiveData], recording: DCRecording) {
        let link = try PtyLink()
        links.append(link)
        link.attach(fakeOSTC())
        let recorder = DCStreamRecorder(scrubber: Self.scrubber)
        let session = try openCable(CableFixtures.endpoint(link), model: model(), recorder: recorder)
        let (result, dives) = downloadToEnd(session)
        session.close()
        return (try XCTUnwrap(result), dives, recorder.recording(family: DC_FAMILY_HW_OSTC, model: 1))
    }

    private func replay(_ recording: DCRecording, viewModel: DiveDataViewModel? = nil) throws
        -> (result: DiveDownloadResult, dives: [DiveData], script: ScriptedStream) {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        let script = ScriptedStream(recording: recording)
        let stream = try DCCustomStream.open(backend: script, transport: script.transport, context: context)
        let session = try DiveComputerSession.open(
            iostream: stream, context: try XCTUnwrap(context), family: try XCTUnwrap(recording.family),
            model: try XCTUnwrap(recording.model), displayName: "Heinrichs Weikamp OSTC Mk2", storageKey: "serial:replay",
            locator: .serial(path: "/dev/cu.usbserial-REPLAY", usbSerial: nil, vid: 0x0403, pid: 0x6001),
            deviceStorage: DeviceStorage(userDefaults: isolatedDefaults("dev")), lease: DiveComputerSessionLease())
        defer { session.close() }
        let (result, dives) = downloadToEnd(session, viewModel: viewModel)
        return (try XCTUnwrap(result), dives, script)
    }

    private func assertSameDives(_ a: [DiveData], _ b: [DiveData], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.datetime, y.datetime, file: file, line: line)
            XCTAssertEqual(x.divetime, y.divetime, file: file, line: line)
            XCTAssertEqual(x.maxDepth, y.maxDepth, file: file, line: line)
            XCTAssertEqual(x.profile.map(\.depth), y.profile.map(\.depth), file: file, line: line)
            XCTAssertEqual(x.profile.map(\.temperature), y.profile.map(\.temperature), file: file, line: line)
        }
    }

    private func newest(_ dives: [DiveData]) -> DiveData? {
        dives.max { $0.datetime < $1.datetime }
    }

    /// What the OSTC's newer dive parses to.
    private func assertNewerDive(_ dive: DiveData, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(dive.maxDepth, 18.5, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(dive.divetime, TimeInterval(Self.newerDepths.count * 10), file: file, line: line)
        XCTAssertEqual(dive.profile.count, Self.newerDepths.count, file: file, line: line)
        // The OSTC stores when the dive ended; the parser starts it one dive time earlier, on the computer's wall clock.
        let start = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dive.datetime)
        XCTAssertEqual([start.year, start.month, start.day, start.hour, start.minute, start.second],
                       [2001, 2, 3, 7, 9, 40], file: file, line: line)
    }

    // MARK: - Record and replay

    func testADownloadRecordedOverASerialPortReplaysToTheSameDives() throws {
        let (live, liveDives, recording) = try recordOverASerialPort()
        XCTAssertEqual(live.outcome, .completed)
        XCTAssertEqual(liveDives.count, 2)
        assertNewerDive(try XCTUnwrap(newest(liveDives)))
        XCTAssertEqual(live.identity?.serial, "000004d2", "the download itself sees the real serial")

        XCTAssertEqual(recording.transport, DC_TRANSPORT_SERIAL)
        // hw_ostc_device_open, as serial_posix saw it.
        XCTAssertEqual(Array(recording.exchanges.prefix(4)), [
            .configure(DCSerialConfiguration(baudrate: 115_200), status: DC_STATUS_SUCCESS),
            .setTimeout(4000, status: DC_STATUS_SUCCESS),
            .sleep(milliseconds: 100, status: DC_STATUS_SUCCESS),
            .purge(DC_DIRECTION_ALL, status: DC_STATUS_SUCCESS),
        ])
        XCTAssertEqual(recording.exchanges[4], .write(data: [UInt8(ascii: "a")], actual: 1, status: DC_STATUS_SUCCESS))
        XCTAssertEqual(recording.exchanges.last, .close(status: DC_STATUS_SUCCESS))
        let inbound = recording.exchanges.flatMap { exchange -> [UInt8] in
            if case let .read(_, data, _) = exchange { return data }
            return []
        }
        XCTAssertEqual(inbound.count, FakeOSTC.headerSize + FakeOSTC.profileSize)
        XCTAssertEqual(Array(inbound[6..<8]), [0x39, 0x05], "the serial is scrubbed")

        let (replayed, replayedDives, script) = try replay(try DCRecording(dcrec: try recording.encoded()))
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete, "played \(script.consumed) of \(script.exchanges.count)")
        XCTAssertEqual(replayed.outcome, .completed)
        assertSameDives(liveDives, replayedDives)
        XCTAssertEqual(replayed.identity?.serial, "00000539")
        XCTAssertEqual(replayed.fingerprintCommit?.fingerprint, live.fingerprintCommit?.fingerprint)
        XCTAssertEqual(replayed.fingerprintCommit?.fingerprint, Data(Self.newerEnd))
    }

    // MARK: - Committed fixture

    private var fixtureURL: URL {
        get throws { try XCTUnwrap(Bundle.module.url(forResource: Self.fixtureName, withExtension: DCRecording.fileExtension)) }
    }

    /// Set LIBDC_REGENERATE_DCREC=1 to record the fixture again over a pty.
    private func committedFixture() throws -> DCRecording {
        if ProcessInfo.processInfo.environment["LIBDC_REGENERATE_DCREC"] != nil {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(Self.fixtureName).\(DCRecording.fileExtension)")
            try recordOverASerialPort().recording.write(to: source)
            return try DCRecording(contentsOf: source)
        }
        return try DCRecording(contentsOf: try fixtureURL)
    }

    func testTheCommittedFixtureReplays() throws {
        let recording = try committedFixture()
        XCTAssertEqual(recording.version, 1)
        XCTAssertEqual(recording.transport, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(recording.family, DC_FAMILY_HW_OSTC)
        XCTAssertEqual(recording.model, 1)

        let (replayed, dives, script) = try replay(recording)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(replayed.outcome, .completed)
        XCTAssertEqual(replayed.divesDownloaded, 2)
        XCTAssertEqual(dives.count, 2)
        assertNewerDive(try XCTUnwrap(newest(dives)))
        XCTAssertEqual(dives.map(\.maxDepth).min() ?? 0, 15.25, accuracy: 0.001)
        XCTAssertEqual(replayed.identity?.serial, "00000539")
        XCTAssertEqual(replayed.identity?.canonicalName, "Heinrichs Weikamp OSTC Mk2")
        XCTAssertEqual(replayed.fingerprintCommit?.serial, "00000539")
    }

    func testTheCommittedFixtureCarriesNoUnscrubbedSerial() throws {
        let text = String(decoding: try Data(contentsOf: try fixtureURL), as: UTF8.self)
        XCTAssertFalse(text.contains("aaaaaaaaaa55d204"), "the header's serial is the stand-in")
        XCTAssertTrue(text.contains("aaaaaaaaaa553905"))
        XCTAssertFalse(text.contains("/dev/"), "no port path")
        XCTAssertFalse(text.contains("TESTADAPTER"), "no adapter serial")
    }

    func testASecondDownloadStopsAtTheFingerprint() throws {
        let recording = try committedFixture()
        let store = DeviceFingerprintStorage(userDefaults: isolatedDefaults("fp"))
        let viewModel = DiveDataViewModel(fingerprintStore: store)
        let (first, _, _) = try replay(recording, viewModel: viewModel)
        let commit = try XCTUnwrap(first.fingerprintCommit)
        commit.acknowledge()
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        // The OSTC sends its whole memory every time; the walk stops at the dive it already has.
        let (second, dives, script) = try replay(recording, viewModel: DiveDataViewModel(fingerprintStore: store))
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(second.outcome, .noNewDives)
        XCTAssertEqual(dives.count, 0)
    }
}
#endif
