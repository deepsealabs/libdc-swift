#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A real computer on a real cable: downloads, records a scrubbed `.dcrec` into Fixtures/Hardware, and downloads again; skipped unless LIBDC_SERIAL_PORT and LIBDC_SERIAL_MODEL are set.
final class SerialHardwareTests: XCTestCase {

    /// The scrubber is picked once the download has reported the serial; `DCStreamRecorder` only applies it in `recording()`.
    private final class LateScrubber: @unchecked Sendable {
        private let lock = NSLock()
        private var current = DCRecordScrubber.none

        var scrubber: DCRecordScrubber {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    static let standInSerial: UInt32 = 0x0539

    /// The serial in the wire encodings drivers commonly use (32- and 16-bit, both byte orders, ASCII digits), each paired with the stand-in in the same encoding.
    static func serialPatterns(_ serial: UInt32) -> [(pattern: [UInt8], replacement: [UInt8])] {
        guard serial != 0 else { return [] }
        func littleEndian(_ value: UInt32, _ width: Int) -> [UInt8] {
            (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
        }
        var pairs: [(pattern: [UInt8], replacement: [UInt8])] = [
            (littleEndian(serial, 4), littleEndian(standInSerial, 4)),
            (littleEndian(serial, 4).reversed(), littleEndian(standInSerial, 4).reversed()),
        ]
        if serial <= 0xFFFF {
            pairs.append((littleEndian(serial, 2), littleEndian(standInSerial, 2)))
            pairs.append((littleEndian(serial, 2).reversed(), littleEndian(standInSerial, 2).reversed()))
        }
        let digits = String(serial)
        let standIn = String(standInSerial)
        if digits.count >= standIn.count {
            let padded = String(repeating: "0", count: digits.count - standIn.count) + standIn
            pairs.append((Array(digits.utf8), Array(padded.utf8)))
        }
        return pairs.filter { $0.pattern != $0.replacement }
    }

    private static func hex(_ value: UInt16?) -> String {
        value.map { String(format: "%04X", $0) } ?? "----"
    }

    private static func fixtureName(_ model: DCModel) -> String {
        let product = model.product.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "\(model.family.rawValue)_\(String(product))"
    }

    private func log(_ line: String) {
        print("[hardware] \(line)")
    }

    func testSerialPatternsScrubTheEncodingsDriversUse() {
        XCTAssertTrue(Self.serialPatterns(0).isEmpty, "serial 0 is no serial")
        let short = DCRecordScrubber.replacing(Self.serialPatterns(1_234))
        XCTAssertEqual(short.scrub([0xAA, 0xD2, 0x04, 0x55], .inbound), [0xAA, 0x39, 0x05, 0x55])
        XCTAssertEqual(short.scrub([0x00, 0x00, 0x04, 0xD2], .inbound), [0x00, 0x00, 0x05, 0x39])
        XCTAssertEqual(short.scrub(Array("SN1234".utf8), .inbound), Array("SN1337".utf8))
        let wide = DCRecordScrubber.replacing(Self.serialPatterns(1_234_567))
        XCTAssertEqual(wide.scrub([0x87, 0xD6, 0x12, 0x00], .inbound), [0x39, 0x05, 0x00, 0x00])
        XCTAssertEqual(wide.scrub(Array("1234567".utf8), .inbound), Array("0001337".utf8))
    }

    func testARealComputerDownloadsRecordsAndStopsAtItsFingerprint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LIBDC_SERIAL_PORT"], let name = environment["LIBDC_SERIAL_MODEL"] else {
            throw XCTSkip("Set LIBDC_SERIAL_PORT to a /dev/cu.* port and LIBDC_SERIAL_MODEL to a serial model's name to run against a real computer")
        }
        let serialModels = DeviceCatalog.models(for: .serial)
        let model = try XCTUnwrap(serialModels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame },
                                  "No serial model named \(name); serial models: \(serialModels.map(\.name).joined(separator: ", "))")

        let discovery = IOKitCableDiscovery()
        discovery.start()
        defer { discovery.stop() }
        let endpoint = try XCTUnwrap(discovery.endpoints.first { $0.calloutPath == path },
                                     "\(path) isn't listed; listed: \(discovery.endpoints.map { $0.calloutPath ?? $0.id })")
        log("\(endpoint.displayName) \(Self.hex(endpoint.vendorID)):\(Self.hex(endpoint.productID)), \(endpoint.status.rawValue), "
            + "adapter serial \(endpoint.usbSerialNumber ?? "none"), \(endpoint.candidates.count) candidates")
        XCTAssertEqual(endpoint.status, .ready)
        XCTAssertTrue(endpoint.candidates.contains(model), "the cable's hint doesn't offer \(model.name)")

        // First download: everything, recorded.
        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedDefaults("fp"))
        let late = LateScrubber()
        let recorder = DCStreamRecorder(scrubber: DCRecordScrubber { late.scrubber.scrub($0, $1) })
        let session = try openCable(endpoint, model: model, discovery: discovery, recorder: recorder, timeout: 30)
        let (firstResult, dives) = downloadToEnd(session, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), timeout: 900)
        let first = try XCTUnwrap(firstResult)
        let rawSerial = session.devicePtr.pointee.have_devinfo != 0 ? session.devicePtr.pointee.devinfo.serial : 0
        let error = CableError(download: first, session: session)
        session.close()
        XCTAssertNil(error, error?.message ?? "")
        XCTAssertEqual(first.outcome, .completed)
        let identity = first.identity
        log("identity \(identity?.canonicalName ?? "none"), serial \(identity?.serial ?? "none"), key \(identity?.deviceKey ?? "none"); "
            + "\(dives.count) dives")
        if let newest = dives.max(by: { $0.datetime < $1.datetime }) {
            log("newest dive: \(newest.maxDepth) m, \(Int(newest.divetime)) s, \(newest.datetime)")
        }

        // The recording, scrubbed, must replay to the same dives under a stand-in serial before it is written.
        late.scrubber = .replacing(Self.serialPatterns(rawSerial))
        let recording = recorder.recording(family: model.dcFamily, model: model.model)
        let (replayed, replayedDives, script) = try replayDownload(recording, displayName: model.name)
        let serialScrubbed = rawSerial == 0 || (replayed.identity != nil && replayed.identity?.serial != identity?.serial)
        let sameDives = replayedDives.map(\.maxDepth).sorted() == dives.map(\.maxDepth).sorted()
            && replayedDives.map(\.divetime).sorted() == dives.map(\.divetime).sorted()
        XCTAssertNil(script.deviation, "the replay left the recorded exchange")
        XCTAssertEqual(replayed.outcome, .completed)
        XCTAssertTrue(serialScrubbed, "the serial wasn't scrubbed: add its wire encoding to serialPatterns")
        XCTAssertTrue(sameDives, "the scrubber changed dive data or a checksum: narrow serialPatterns for this family")
        if script.deviation == nil, replayed.outcome == .completed, serialScrubbed, sameDives, !dives.isEmpty {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Hardware/\(Self.fixtureName(model)).\(DCRecording.fileExtension)")
            try recording.write(to: url)
            log("wrote \(url.path). It still holds the dives as the computer sent them, dates (and positions, where logged) "
                + "included: commit it only for dives you are happy to publish")
        }

        // Second download: the fingerprint the first one left stops it before any dive.
        try XCTUnwrap(first.fingerprintCommit, "a completed download carries a fingerprint commit").acknowledge()
        let again = try openCable(endpoint, model: model, discovery: discovery, timeout: 30)
        let (secondResult, newDives) = downloadToEnd(again, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), timeout: 900)
        again.close()
        XCTAssertEqual(secondResult?.outcome, .noNewDives)
        XCTAssertEqual(newDives.count, 0)
    }
}
#endif
