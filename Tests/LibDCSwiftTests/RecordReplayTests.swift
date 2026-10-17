#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Recording a real driver's download through `TapStream`, then replaying the `.dcrec` through `ScriptedStream`.
final class RecordReplayTests: XCTestCase {

    private static let serial: UInt16 = 0xC3A5
    private static let devtime: UInt32 = 5_000_000
    private static let fixtureName = "reefnet_sensus_synthetic"

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive.removeAll()
        super.tearDown()
    }

    private func fakeSensus() -> SessionClockTests.FakeSensus {
        SessionClockTests.FakeSensus(serial: Self.serial, devtime: Self.devtime, dives: [
            (100, SessionClockTests.dive(timestamp: Self.devtime - 86_400)),
            (400, SessionClockTests.dive(timestamp: Self.devtime - 3_600)),
        ])
    }

    /// The fake on a minimal serial `dc_custom_open` stream; after `cutoff` bytes the link fails with `failure`.
    private final class Link {
        let fake: SessionClockTests.FakeSensus
        let cutoff: Int?
        let failure: dc_status_t
        var delivered = 0
        init(_ fake: SessionClockTests.FakeSensus, cutoff: Int?, failure: dc_status_t) {
            self.fake = fake
            self.cutoff = cutoff
            self.failure = failure
        }
    }

    private func fakeStream(_ fake: SessionClockTests.FakeSensus, context: OpaquePointer,
                            cutoff: Int? = nil, failure: dc_status_t = DC_STATUS_IO) throws -> OpaquePointer {
        let link = Link(fake, cutoff: cutoff, failure: failure)
        keepAlive.append(link)
        var cbs = dc_custom_cbs_t()
        cbs.read = { userdata, data, size, actual in
            let link = Unmanaged<Link>.fromOpaque(userdata!).takeUnretainedValue()
            if let cutoff = link.cutoff, link.delivered >= cutoff {
                actual?.pointee = 0
                return link.failure
            }
            let allowed = link.cutoff.map { min(size, $0 - link.delivered) } ?? size
            let n = link.fake.hostRead(into: data!, size: allowed)
            link.delivered += n
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            Unmanaged<Link>.fromOpaque(userdata!).takeUnretainedValue().fake.hostWrote(UnsafeRawBufferPointer(start: data, count: size))
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(link).toOpaque()),
                       DC_STATUS_SUCCESS)
        return try XCTUnwrap(iostream)
    }

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.replay.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private struct Download {
        let result: DiveDownloadResult
        let dives: [DiveData]
    }

    /// Opens a Sensus session on `iostream` (which it owns from here), downloads, and closes it.
    private func download(_ iostream: OpaquePointer, context: OpaquePointer,
                          family: dc_family_t = DC_FAMILY_REEFNET_SENSUS, model: UInt32 = 1) throws -> Download {
        let session = try DiveComputerSession.open(
            iostream: iostream, context: context, family: family, model: model,
            displayName: "Reefnet Sensus", storageKey: "serial:sensus",
            deviceStorage: DeviceStorage(userDefaults: isolatedSuite("dev")), lease: DiveComputerSessionLease())
        let viewModel = DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedSuite("fp")))
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        session.close()
        return Download(result: try XCTUnwrap(result), dives: viewModel.dives)
    }

    private func newContext() throws -> OpaquePointer {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        return try XCTUnwrap(context)
    }

    /// A live download through a recording tap, and the recording.
    private func recordedDownload(scrubber: DCRecordScrubber = .none, cutoff: Int? = nil,
                                  failure: dc_status_t = DC_STATUS_IO) throws -> (Download, DCRecording) {
        let context = try newContext()
        let recorder = DCStreamRecorder(scrubber: scrubber)
        let tap = TapStream(inner: try fakeStream(fakeSensus(), context: context, cutoff: cutoff, failure: failure),
                            recorder: recorder)
        let stream = try DCCustomStream.open(backend: tap, transport: tap.transport, context: context)
        let live = try download(stream, context: context)
        return (live, recorder.recording(family: DC_FAMILY_REEFNET_SENSUS, model: 1))
    }

    private func replay(_ recording: DCRecording) throws -> (Download, ScriptedStream) {
        let context = try newContext()
        let script = ScriptedStream(recording: recording)
        let stream = try DCCustomStream.open(backend: script, transport: script.transport, context: context)
        let replayed = try download(stream, context: context, family: try XCTUnwrap(recording.family),
                                    model: try XCTUnwrap(recording.model))
        return (replayed, script)
    }

    private func assertSameDives(_ a: [DiveData], _ b: [DiveData], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.divetime, y.divetime, file: file, line: line)
            XCTAssertEqual(x.maxDepth, y.maxDepth, file: file, line: line)
            XCTAssertEqual(x.profile.map(\.depth), y.profile.map(\.depth), file: file, line: line)
            XCTAssertEqual(x.profile.map(\.time), y.profile.map(\.time), file: file, line: line)
            // Sensus dates come from the host clock at the handshake, which moves on between the two runs.
            XCTAssertEqual(x.datetime.timeIntervalSince1970, y.datetime.timeIntervalSince1970, accuracy: 5, file: file, line: line)
        }
    }

    // MARK: - Round trip

    func testARecordedDownloadReplaysToTheSameDives() throws {
        let (live, recording) = try recordedDownload()
        XCTAssertEqual(live.result.outcome, .completed)
        XCTAssertEqual(live.dives.count, 2)
        XCTAssertEqual(recording.transport, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(recording.exchanges.first?.operation, .configure)
        XCTAssertEqual(recording.exchanges.last, .close(status: DC_STATUS_SUCCESS))

        let decoded = try DCRecording(dcrec: try recording.encoded())
        XCTAssertEqual(decoded, recording)

        let (replayed, script) = try replay(decoded)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete, "played \(script.consumed) of \(script.exchanges.count)")
        XCTAssertEqual(replayed.result.outcome, .completed)
        assertSameDives(live.dives, replayed.dives)
        let liveCommit = try XCTUnwrap(live.result.fingerprintCommit)
        let replayedCommit = try XCTUnwrap(replayed.result.fingerprintCommit)
        XCTAssertEqual(replayedCommit.fingerprint, liveCommit.fingerprint)
        XCTAssertEqual(replayedCommit.serial, "0000c3a5")
        XCTAssertEqual(replayedCommit.deviceType, liveCommit.deviceType)
    }

    func testAScrubbedRecordingStillReplaysWithTheStandInSerial() throws {
        let scrubber = DCRecordScrubber.replacing([(pattern: [0xA5, 0xC3], replacement: [0x01, 0x00])])
        let (live, recording) = try recordedDownload(scrubber: scrubber)
        XCTAssertEqual(live.result.fingerprintCommit?.serial, "0000c3a5", "the live download sees the real bytes")
        let encoded = try recording.encoded()
        XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: "a5c3"))

        let (replayed, script) = try replay(try DCRecording(dcrec: encoded))
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(replayed.result.outcome, .completed)
        XCTAssertEqual(replayed.result.fingerprintCommit?.serial, "00000001")
        assertSameDives(live.dives, replayed.dives)
    }

    func testAnUnplugMidDownloadReplaysAsTheSameFailure() throws {
        let (live, recording) = try recordedDownload(cutoff: 12 + 128 * 8, failure: DC_STATUS_IO)
        XCTAssertEqual(live.result.outcome, .failed(DC_STATUS_IO))
        XCTAssertNil(live.result.fingerprintCommit)
        XCTAssertTrue(recording.exchanges.contains { $0.operation == .read && $0.status == DC_STATUS_IO })

        let (replayed, script) = try replay(recording)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(replayed.result.outcome, live.result.outcome)
        XCTAssertEqual(replayed.dives.count, 0)
        XCTAssertNil(replayed.result.fingerprintCommit)
    }

    func testAComputerThatGoesQuietReplaysAsTheSameTimeout() throws {
        let (live, recording) = try recordedDownload(cutoff: 12 + 128 * 5, failure: DC_STATUS_TIMEOUT)
        XCTAssertEqual(live.result.outcome, .failed(DC_STATUS_TIMEOUT))

        let (replayed, script) = try replay(recording)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(replayed.result.outcome, .failed(DC_STATUS_TIMEOUT))
    }

    // MARK: - Committed fixture

    private var fixtureURL: URL {
        get throws { try XCTUnwrap(Bundle.module.url(forResource: Self.fixtureName, withExtension: DCRecording.fileExtension)) }
    }

    /// The fixture is this fake's download with the serial scrubbed to 1; set LIBDC_REGENERATE_DCREC=1 to rewrite it.
    private func freshFixtureRecording() throws -> DCRecording {
        try recordedDownload(scrubber: .replacing([(pattern: [0xA5, 0xC3], replacement: [0x01, 0x00])])).1
    }

    func testTheCommittedFixtureReplays() throws {
        if ProcessInfo.processInfo.environment["LIBDC_REGENERATE_DCREC"] != nil {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(Self.fixtureName).\(DCRecording.fileExtension)")
            try freshFixtureRecording().write(to: source)
        }
        let recording = try DCRecording(contentsOf: try fixtureURL)
        XCTAssertEqual(recording.version, 1)
        XCTAssertEqual(recording.transport, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(recording.family, DC_FAMILY_REEFNET_SENSUS)

        let (replayed, script) = try replay(recording)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete)
        XCTAssertEqual(replayed.result.outcome, .completed)
        XCTAssertEqual(replayed.dives.count, 2)
        XCTAssertEqual(replayed.dives.map(\.divetime), [250, 250])
        XCTAssertEqual(replayed.result.fingerprintCommit?.serial, "00000001")
    }

    func testTheFixtureMatchesAFreshRecordingByteForByte() throws {
        // Pins the .dcrec format and TapStream's recording: a change here needs a new fixture (and a version bump if old files stop decoding).
        let committed = try Data(contentsOf: try fixtureURL)
        XCTAssertEqual(try freshFixtureRecording().encoded(), committed)
    }

    // MARK: - Strict replay

    private func scripted(_ exchanges: [DCRecording.Exchange]) throws -> (OpaquePointer, ScriptedStream, OpaquePointer) {
        let context = try newContext()
        let script = ScriptedStream(exchanges, transport: DC_TRANSPORT_SERIAL)
        let stream = try DCCustomStream.open(backend: script, transport: DC_TRANSPORT_SERIAL, context: context)
        addTeardownBlock { dc_iostream_close(stream); dc_context_free(context) }
        return (stream, script, context)
    }

    func testAnUnexpectedWriteFailsAndSticks() throws {
        let (stream, script, _) = try scripted([
            .write(data: [0x0A], actual: 1, status: DC_STATUS_SUCCESS),
            .read(size: 2, data: [0x4F, 0x4B], status: DC_STATUS_SUCCESS),
        ])
        var actual = 0
        XCTAssertEqual(dc_iostream_write(stream, [0x0B] as [UInt8], 1, &actual), DC_STATUS_IO)
        XCTAssertEqual(actual, 0)
        let deviation = try XCTUnwrap(script.deviation)
        XCTAssertEqual(deviation.index, 0)
        XCTAssertEqual(deviation.attempted, .write)
        XCTAssertEqual(deviation.expected, .write(data: [0x0A], actual: 1, status: DC_STATUS_SUCCESS))
        XCTAssertTrue(deviation.detail.contains("0b"), deviation.detail)
        XCTAssertTrue(deviation.detail.contains("0a"), deviation.detail)

        // Even the right next call fails once the script has deviated.
        XCTAssertEqual(dc_iostream_write(stream, [0x0A] as [UInt8], 1, &actual), DC_STATUS_IO)
        XCTAssertEqual(script.deviation, deviation)
        XCTAssertFalse(script.isComplete)
    }

    func testUnexpectedLineSettingsFail() throws {
        let configure = DCSerialConfiguration(baudrate: 19200)
        let (stream, script, _) = try scripted([.configure(configure, status: DC_STATUS_SUCCESS)])
        XCTAssertEqual(dc_iostream_configure(stream, 9600, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_IO)
        XCTAssertEqual(script.deviation?.attempted, .configure)
        XCTAssertEqual(script.deviation?.detail, "configure 9600 8N1 flow 0, expected 19200 8N1 flow 0")

        let (parity, parityScript, _) = try scripted([.configure(configure, status: DC_STATUS_SUCCESS)])
        XCTAssertEqual(dc_iostream_configure(parity, 19200, 8, DC_PARITY_EVEN, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE), DC_STATUS_IO)
        XCTAssertNotNil(parityScript.deviation)

        let (dtr, dtrScript, _) = try scripted([.setDTR(1, status: DC_STATUS_SUCCESS), .setRTS(0, status: DC_STATUS_SUCCESS)])
        XCTAssertEqual(dc_iostream_set_rts(dtr, 0), DC_STATUS_IO, "RTS before the recorded DTR")
        XCTAssertEqual(dtrScript.deviation?.detail, "unexpected set_rts")

        let (dtrValue, dtrValueScript, _) = try scripted([.setDTR(1, status: DC_STATUS_SUCCESS)])
        XCTAssertEqual(dc_iostream_set_dtr(dtrValue, 0), DC_STATUS_IO)
        XCTAssertEqual(dtrValueScript.deviation?.detail, "DTR 0, expected 1")

        let (rts, rtsScript, _) = try scripted([.setRTS(0, status: DC_STATUS_SUCCESS)])
        XCTAssertEqual(dc_iostream_set_rts(rts, 1), DC_STATUS_IO)
        XCTAssertEqual(rtsScript.deviation?.detail, "RTS 1, expected 0")
    }

    func testRepliesComeFromTheScript() throws {
        let (stream, script, _) = try scripted([
            .setTimeout(3000, status: DC_STATUS_SUCCESS),
            .getAvailable(value: 9, status: DC_STATUS_SUCCESS),
            .read(size: 4, data: [0x01, 0x02], status: DC_STATUS_TIMEOUT),
            .ioctl(request: StreamOps.ioctlRequest, input: [1, 2, 3, 4], output: [5, 6, 7, 8], status: DC_STATUS_SUCCESS),
            .sleep(milliseconds: 5_000, status: DC_STATUS_SUCCESS),
            .read(size: 4, data: [], status: DC_STATUS_IO),
        ])
        XCTAssertEqual(dc_iostream_set_timeout(stream, 3000), DC_STATUS_SUCCESS)
        var available = 0
        XCTAssertEqual(dc_iostream_get_available(stream, &available), DC_STATUS_SUCCESS)
        XCTAssertEqual(available, 9)
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_TIMEOUT)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x01, 0x02])
        var ioctl: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(dc_iostream_ioctl(stream, StreamOps.ioctlRequest, &ioctl, 4), DC_STATUS_SUCCESS)
        XCTAssertEqual(ioctl, [5, 6, 7, 8])
        let start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_sleep(stream, 5_000), DC_STATUS_SUCCESS)
        XCTAssertLessThan(milliseconds(since: start), 100, "replays don't wait")
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_IO, "an unplug, as recorded")
        XCTAssertEqual(actual, 0)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete)
    }

    func testReadSizeAndThePastTheEndAreDeviations() throws {
        let (stream, script, _) = try scripted([.read(size: 12, data: [0x4F], status: DC_STATUS_SUCCESS)])
        var buffer = [UInt8](repeating: 0, count: 16)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 16, &actual), DC_STATUS_IO)
        XCTAssertEqual(script.deviation?.detail, "read size 16, expected 12")

        let (ended, endedScript, _) = try scripted([.flush(status: DC_STATUS_SUCCESS)])
        XCTAssertEqual(dc_iostream_flush(ended), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_purge(ended, DC_DIRECTION_ALL), DC_STATUS_IO)
        XCTAssertNil(endedScript.deviation?.expected)
        XCTAssertEqual(endedScript.deviation?.index, 1)
        XCTAssertEqual(endedScript.deviation?.detail, "past the end of the script")
    }

    func testAScriptThatEndsBeforeCloseAcceptsIt() throws {
        let context = try newContext()
        defer { dc_context_free(context) }
        let script = ScriptedStream([.flush(status: DC_STATUS_SUCCESS)], transport: DC_TRANSPORT_USBHID)
        let stream = try DCCustomStream.open(backend: script, transport: script.transport, context: context)
        XCTAssertEqual(dc_iostream_get_transport(stream), DC_TRANSPORT_USBHID)
        XCTAssertEqual(dc_iostream_flush(stream), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_close(stream), DC_STATUS_SUCCESS)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete)
    }

    func testADriverThatStraysFromTheRecordingFailsTheReplay() throws {
        var (_, recording) = try recordedDownload()
        // The open's configure: the driver asks for 19200 baud, the edited script says 9600.
        guard case .configure(var configuration, let status) = recording.exchanges[0] else {
            return XCTFail("expected the driver's configure first, got \(recording.exchanges[0])")
        }
        configuration.baudrate = 9600
        recording.exchanges[0] = .configure(configuration, status: status)

        let context = try newContext()
        let script = ScriptedStream(recording: recording)
        let stream = try DCCustomStream.open(backend: script, transport: script.transport, context: context)
        XCTAssertThrowsError(try DiveComputerSession.open(
            iostream: stream, context: context, family: DC_FAMILY_REEFNET_SENSUS, model: 1,
            displayName: "Reefnet Sensus", storageKey: "serial:sensus",
            deviceStorage: DeviceStorage(userDefaults: isolatedSuite("dev")), lease: DiveComputerSessionLease())) { error in
            XCTAssertEqual(error as? DiveComputerSessionError, .openFailed(DC_STATUS_IO))
        }
        XCTAssertEqual(script.deviation?.index, 0)
        XCTAssertEqual(script.deviation?.attempted, .configure)
    }

    // MARK: - .dcrec format

    private static let everyKind: [DCRecording.Exchange] = [
        .setTimeout(-1, status: DC_STATUS_SUCCESS),
        .setBreak(1, status: DC_STATUS_UNSUPPORTED),
        .setDTR(1, status: DC_STATUS_SUCCESS),
        .setRTS(0, status: DC_STATUS_IO),
        .getLines(value: 0x1F, status: DC_STATUS_SUCCESS),
        .getAvailable(value: 4096, status: DC_STATUS_SUCCESS),
        .configure(DCSerialConfiguration(baudrate: 460_800, databits: 7, parity: DC_PARITY_ODD,
                                         stopbits: DC_STOPBITS_ONEPOINTFIVE, flowcontrol: DC_FLOWCONTROL_SOFTWARE),
                   status: DC_STATUS_SUCCESS),
        .poll(timeout: 250, status: DC_STATUS_TIMEOUT),
        .read(size: 8, data: [0x00, 0xFF, 0x10, 0xAB], status: DC_STATUS_TIMEOUT),
        .write(data: [0xDE, 0xAD, 0xBE, 0xEF], actual: 3, status: DC_STATUS_IO),
        .ioctl(request: 0xC004_7301, input: [1, 2, 3, 4], output: [], status: DC_STATUS_NOACCESS),
        .flush(status: DC_STATUS_SUCCESS),
        .purge(DC_DIRECTION_INPUT, status: DC_STATUS_SUCCESS),
        .sleep(milliseconds: 10, status: DC_STATUS_CANCELLED),
        .close(status: DC_STATUS_DONE),
    ]

    func testEveryExchangeKindRoundTripsThroughDcrec() throws {
        XCTAssertEqual(Self.everyKind.map(\.operation), DCIOStreamOperation.allCases)
        let recording = DCRecording(transport: DC_TRANSPORT_USBHID, family: DC_FAMILY_SUUNTO_EONSTEEL, model: 0,
                                    exchanges: Self.everyKind)
        let data = try recording.encoded()
        XCTAssertEqual(try DCRecording(dcrec: data), recording)

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("\"op\":") }.count, Self.everyKind.count, "one exchange per line")
        XCTAssertTrue(text.contains("\"transport\": \"usbhid\""))
        XCTAssertTrue(text.contains("{\"actual\":3,\"data\":\"deadbeef\",\"op\":\"write\",\"status\":\"io\"}"), text)

        let empty = DCRecording(transport: DC_TRANSPORT_BLE)
        XCTAssertEqual(try DCRecording(dcrec: try empty.encoded()), empty)
    }

    func testDcrecRejectsWhatItCannotReplay() {
        func decode(_ json: String) -> DCRecording.FormatError? {
            do {
                _ = try DCRecording(dcrec: Data(json.utf8))
                return nil
            } catch {
                return error as? DCRecording.FormatError
            }
        }
        XCTAssertEqual(decode(#"{"format":"pcap","version":1,"transport":"serial","exchanges":[]}"#), .notADCRec)
        XCTAssertEqual(decode(#"{"format":"dcrec","version":2,"transport":"serial","exchanges":[]}"#), .unsupportedVersion(2))
        XCTAssertEqual(decode(#"{"format":"dcrec","version":1,"transport":"irda2","exchanges":[]}"#), .unknownTransport("irda2"))
        XCTAssertEqual(decode(#"{"format":"dcrec","version":1,"transport":"serial","exchanges":[{"op":"flush","status":"meh"}]}"#),
                       .unknownStatus("meh"))
        XCTAssertEqual(decode(#"{"format":"dcrec","version":1,"transport":"serial","exchanges":[{"op":"read","status":"success","data":""}]}"#),
                       .missingField(.read, "size"))
        XCTAssertEqual(decode(#"{"format":"dcrec","version":1,"transport":"serial","exchanges":[{"op":"read","status":"success","size":1,"data":"0g"}]}"#),
                       .badHex("0g"))
    }

    // MARK: - Scrubbing

    func testTheScrubberSeesEachDirectionAsOneStream() throws {
        let probe = ProbeBackend()
        let recorder = DCStreamRecorder(scrubber: .replacing([(pattern: [0x12, 0x34, 0x56], replacement: [0, 0, 0])]))
        let stream = try DCCustomStream.open(backend: TapStream(inner: try DCCustomStream.open(
            backend: probe, transport: DC_TRANSPORT_SERIAL, context: nil), recorder: recorder), transport: DC_TRANSPORT_SERIAL, context: nil)
        defer { dc_iostream_close(stream) }
        XCTAssertEqual(dc_iostream_set_timeout(stream, 0), DC_STATUS_SUCCESS)

        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        probe.readReply = [0xAA, 0x12]
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_SUCCESS)
        probe.readReply = [0x34, 0x56, 0xBB]
        XCTAssertEqual(dc_iostream_read(stream, &buffer, 4, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x34, 0x56, 0xBB], "the driver still gets the real bytes")
        XCTAssertEqual(dc_iostream_write(stream, [0x09, 0x12, 0x34, 0x56] as [UInt8], 4, &actual), DC_STATUS_SUCCESS)
        var ioctl: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        _ = dc_iostream_ioctl(stream, StreamOps.ioctlRequest, &ioctl, 4)

        let exchanges = recorder.recording().exchanges
        XCTAssertEqual(exchanges[1], .read(size: 4, data: [0xAA, 0x00], status: DC_STATUS_SUCCESS))
        XCTAssertEqual(exchanges[2], .read(size: 4, data: [0x00, 0x00, 0xBB], status: DC_STATUS_SUCCESS))
        XCTAssertEqual(exchanges[3], .write(data: [0x09, 0x00, 0x00, 0x00], actual: 4, status: DC_STATUS_SUCCESS))
        guard case let .ioctl(_, input, _, _) = exchanges[4] else { return XCTFail("expected the ioctl") }
        XCTAssertEqual(input, [0x00, 0x00, 0x00, 0x78])
    }

    func testAScrubberThatChangesTheLengthZeroesTheBytes() throws {
        let probe = ProbeBackend()
        probe.readReply = [0x01, 0x02, 0x03]
        let recorder = DCStreamRecorder(scrubber: DCRecordScrubber { bytes, _ in Array(bytes.dropLast()) })
        let tap = TapStream(inner: try DCCustomStream.open(backend: probe, transport: DC_TRANSPORT_SERIAL, context: nil),
                            recorder: recorder)
        XCTAssertEqual(tap.setTimeout(0), DC_STATUS_SUCCESS)
        var buffer = [UInt8](repeating: 0, count: 3)
        var actual = 0
        XCTAssertEqual(buffer.withUnsafeMutableBytes { tap.read(into: $0, actual: &actual) }, DC_STATUS_SUCCESS)
        XCTAssertEqual(recorder.recording().exchanges.last, .read(size: 3, data: [0, 0, 0], status: DC_STATUS_SUCCESS))
        XCTAssertEqual(recorder.count, 2)
    }

    func testScrubbersChain() {
        let first = DCRecordScrubber.replacing([(pattern: [0x01], replacement: [0x02])])
        let second = DCRecordScrubber.replacing([(pattern: [0x02, 0x02], replacement: [0x07, 0x07])])
        XCTAssertEqual(first.then(second).scrub([0x01, 0x01, 0x03], .inbound), [0x07, 0x07, 0x03])
        XCTAssertEqual(DCRecordScrubber.none.scrub([0x05], .outbound), [0x05])
    }
}
#endif
