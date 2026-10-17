#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A Shearwater Petrel's classic-Bluetooth serial protocol (shearwater_common.c's SLIP framing, RDBI
/// DEVINFO reads, and an empty manifest), recorded over a pty and replayed through `ScriptedStream`. Nothing
/// else in the suite drives this code path: it's the branch shearwater_common.c takes once the transport
/// isn't BLE.
final class ShearwaterSerialReplayTests: XCTestCase {

    /// Answers shearwater_common.c's SLIP-framed RDBI and upload requests the way a Petrel does: a serial,
    /// firmware and model over RDBI, a PNF logbook base address, and a one-page manifest with no recognizable
    /// dive header, so the walk ends with no dives.
    final class FakeShearwaterPetrel: FakeSerialDevice {
        static let model: UInt8 = 3 // PETREL (shearwater_common.h)
        static let manifestSize = 0x600 // MANIFEST_SIZE (shearwater_petrel.c)
        static let maxChunk = 252 // shearwater_common.c's SZ_PACKET_V1 (254) minus the 2-byte data-response header

        private static let end: UInt8 = 0xC0
        private static let esc: UInt8 = 0xDB
        private static let escEnd: UInt8 = 0xDC
        private static let escEsc: UInt8 = 0xDD

        let serial: UInt32
        private let lock = NSLock()
        private var inbox: [UInt8] = []
        private var escaped = false
        private var outbox: [UInt8] = []

        init(serial: UInt32) {
            self.serial = serial
        }

        func hostWrote(_ bytes: UnsafeRawBufferPointer) {
            var frames: [[UInt8]] = []
            lock.lock()
            for byte in bytes {
                if byte == Self.end {
                    if !inbox.isEmpty { frames.append(inbox); inbox = [] }
                    escaped = false
                    continue
                }
                if byte == Self.esc {
                    escaped = true
                    continue
                }
                if escaped {
                    inbox.append(byte == Self.escEnd ? Self.end : (byte == Self.escEsc ? Self.esc : byte))
                    escaped = false
                } else {
                    inbox.append(byte)
                }
            }
            lock.unlock()
            frames.forEach(respond)
        }

        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = min(size, outbox.count)
            guard n > 0 else { return 0 }
            outbox.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress!, byteCount: n) }
            outbox.removeFirst(n)
            return n
        }

        private func slipEncode(_ packet: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(packet.count + 1)
            for byte in packet {
                switch byte {
                case Self.end: out += [Self.esc, Self.escEnd]
                case Self.esc: out += [Self.esc, Self.escEsc]
                default: out.append(byte)
                }
            }
            out.append(Self.end)
            return out
        }

        /// Wraps `payload` in shearwater_common_transfer's response header (0x01 0xFF <len+1> 0x00) and queues it, SLIP-encoded.
        private func enqueue(_ payload: [UInt8]) {
            let packet: [UInt8] = [0x01, 0xFF, UInt8(payload.count + 1), 0x00] + payload
            lock.lock()
            outbox += slipEncode(packet)
            lock.unlock()
        }

        /// `frame` is the request with its own header (0xFF 0x01 <len+1> 0x00) still on; `command` is what follows it.
        private func respond(to frame: [UInt8]) {
            guard frame.count >= 4, frame[0] == 0xFF, frame[1] == 0x01 else { return }
            let command = Array(frame[4...])
            guard let opcode = command.first else { return }
            switch opcode {
            case 0x22 where command.count >= 3: // RDBI_REQUEST
                respondRDBI(id: (UInt16(command[1]) << 8) | UInt16(command[2]), echo: [command[1], command[2]])
            case 0x35: // UPLOAD_INIT_REQUEST: max packet length 254, encoded as a 1-byte field
                enqueue([0x75, 0x10, 0xFE])
            case 0x36 where command.count >= 2: // UPLOAD_DATA_REQUEST
                respondUploadData(block: command[1])
            case 0x37: // UPLOAD_EXIT_REQUEST
                enqueue([0x77, 0x00])
            default:
                break // WDBI's shutdown (0x2E) expects no reply, and close() never reads one
            }
        }

        private func respondRDBI(id: UInt16, echo: [UInt8]) {
            switch id {
            case 0x8010: // ID_SERIAL: 8 ASCII hex digits, array_convert_hex2bin'd by the driver
                enqueue([0x62] + echo + Array(String(format: "%08X", serial).utf8))
            case 0x8011: // ID_FIRMWARE: str2num reads decimal digits from offset 1, skipping a version letter
                enqueue([0x62] + echo + Array("V91".utf8))
            case 0x8060: // ID_MODEL
                enqueue([0x62] + echo + [Self.model])
            case 0x8021: // ID_LOGUPLOAD: the base address at bytes 1...4, big-endian; 0x80000000 is the Petrel Native Format
                enqueue([0x62] + echo + [0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            default:
                break
            }
        }

        private func respondUploadData(block: UInt8) {
            let start = Int(block - 1) * Self.maxChunk
            guard start < Self.manifestSize else { return }
            let length = min(Self.maxChunk, Self.manifestSize - start)
            // All zero: no byte pair in the page reads as a dive header (0xA5C4) or a deleted one (0x5A23).
            enqueue([0x76, block] + [UInt8](repeating: 0, count: length))
        }
    }

    private static let rawSerial: UInt32 = 0x00AB_CDEF
    private static let fixtureName = "shearwater_petrel_serial_synthetic"

    private static let scrubber = DCRecordScrubber.replacing(SerialHardwareTests.serialPatterns(rawSerial))

    private var links: [PtyLink] = []

    override func tearDown() {
        links.forEach { $0.close() }
        links.removeAll()
        super.tearDown()
    }

    private func model() throws -> DCModel {
        try XCTUnwrap(DeviceCatalog.models(for: .classicBTSerial).first { $0.name == "Shearwater Petrel" })
    }

    /// A live download over a pty through `DiveComputerSession.open`, recorded and scrubbed.
    private func recordOverAPairedPort() throws -> (result: DiveDownloadResult, dives: [DiveData], recording: DCRecording) {
        let link = try PtyLink()
        links.append(link)
        link.attach(FakeShearwaterPetrel(serial: Self.rawSerial))
        let recorder = DCStreamRecorder(scrubber: Self.scrubber)
        let paired = CableEndpoint(id: link.path, transport: .classicBTSerial, calloutPath: link.path,
                                  candidates: DeviceCatalog.models(for: .classicBTSerial))
        let petrel = try model()
        let session = try openCable(paired, model: petrel, recorder: recorder)
        let (result, dives) = downloadToEnd(session)
        session.close()
        return (try XCTUnwrap(result), dives, recorder.recording(family: DC_FAMILY_SHEARWATER_PETREL, model: petrel.model))
    }

    private func replay(_ recording: DCRecording) throws -> (result: DiveDownloadResult, dives: [DiveData], script: ScriptedStream) {
        try replayDownload(recording, displayName: "Shearwater Petrel")
    }

    func testARecordedClassicBTDownloadReplaysWithNoDives() throws {
        let (live, liveDives, recording) = try recordOverAPairedPort()
        XCTAssertEqual(liveDives.count, 0, "the manifest page has no recognizable dive header")
        XCTAssertEqual(live.identity?.serial, String(format: "%08x", Self.rawSerial), "the live download sees the real serial")
        XCTAssertEqual(recording.transport, DC_TRANSPORT_SERIAL, "a classic-Bluetooth port is DC_TRANSPORT_SERIAL to libdivecomputer")

        let (replayed, dives, script) = try replay(try DCRecording(dcrec: try recording.encoded()))
        XCTAssertNil(script.deviation, script.deviation.map(String.init(describing:)) ?? "")
        XCTAssertTrue(script.isComplete, "played \(script.consumed) of \(script.exchanges.count)")
        XCTAssertTrue(replayed.outcome == .completed || replayed.outcome == .noNewDives, "\(replayed.outcome)")
        XCTAssertEqual(dives.count, 0)
        XCTAssertEqual(replayed.identity?.family, .shearwaterPetrel)
        XCTAssertEqual(replayed.identity?.transport, .serial)
        XCTAssertEqual(replayed.identity?.serial, String(format: "%08x", SerialHardwareTests.standInSerial), "the serial is scrubbed")
        XCTAssertNotEqual(replayed.identity?.serial, live.identity?.serial)
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
            try recordOverAPairedPort().recording.write(to: source)
            return try DCRecording(contentsOf: source)
        }
        return try DCRecording(contentsOf: try fixtureURL)
    }

    func testTheCommittedFixtureReplays() throws {
        let recording = try committedFixture()
        XCTAssertEqual(recording.transport, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(recording.family, DC_FAMILY_SHEARWATER_PETREL)

        let (replayed, dives, script) = try replay(recording)
        XCTAssertNil(script.deviation, script.deviation.map(String.init(describing:)) ?? "")
        XCTAssertTrue(script.isComplete, "played \(script.consumed) of \(script.exchanges.count)")
        XCTAssertTrue(replayed.outcome == .completed || replayed.outcome == .noNewDives, "\(replayed.outcome)")
        XCTAssertEqual(dives.count, 0)
        XCTAssertEqual(replayed.identity?.family, .shearwaterPetrel)
        XCTAssertEqual(replayed.identity?.canonicalName, "Shearwater Petrel")
        XCTAssertEqual(replayed.identity?.transport, .serial)
        XCTAssertEqual(replayed.identity?.serial, String(format: "%08x", SerialHardwareTests.standInSerial))
    }

    func testTheCommittedFixtureCarriesNoUnscrubbedSerial() throws {
        let text = String(decoding: try Data(contentsOf: try fixtureURL), as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains(String(format: "%08x", Self.rawSerial)))
    }
}
#endif
