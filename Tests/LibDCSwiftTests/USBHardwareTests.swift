#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A real raw USB computer: downloads, records a scrubbed `.dcrec` into Fixtures/Hardware, and downloads again; skipped unless LIBDC_USB_MODEL is set.
final class USBHardwareTests: XCTestCase {

    private final class LateScrubber: @unchecked Sendable {
        private let lock = NSLock()
        private var current = DCRecordScrubber.none

        var scrubber: DCRecordScrubber {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    private func log(_ line: String) {
        print("[hardware] \(line)")
    }

    private static func fixtureName(_ model: DCModel) -> String {
        let product = model.product.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "\(model.family.rawValue)_\(String(product))_usb"
    }

    /// The Cobalt sends its serial as 8 ASCII digits under additive checksums, so the stand-in keeps the digits' sum.
    static func serialPatterns(_ serial: UInt32) -> [(pattern: [UInt8], replacement: [UInt8])] {
        guard serial != 0, serial <= 99_999_999 else { return [] }
        let digits = String(format: "%08u", serial).compactMap(\.wholeNumberValue)
        var left = digits.reduce(0, +)
        var standIn = [Int](repeating: 0, count: 8)
        for index in stride(from: 7, through: 0, by: -1) {
            standIn[index] = min(9, left)
            left -= standIn[index]
        }
        if standIn == digits { standIn.reverse() }
        guard standIn != digits else { return [] }
        let ascii: ([Int]) -> [UInt8] = { $0.map { UInt8(ascii: "0") + UInt8($0) } }
        return [(pattern: ascii(digits), replacement: ascii(standIn))]
    }

    private func usbEndpoint(for model: DCModel, in discovery: IOKitCableDiscovery) throws -> CableEndpoint {
        try XCTUnwrap(discovery.endpoints.first { $0.transport == .usb && $0.candidates.contains(model) },
                      "no USB endpoint offers \(model.name); listed: \(discovery.endpoints.map(\.displayName))")
    }

    func testTheScrubberKeepsTheChecksumsTheSerialIsUnder() {
        let patterns = Self.serialPatterns(12_345)
        XCTAssertEqual(patterns.count, 1)
        let pattern = patterns[0]
        XCTAssertEqual(pattern.pattern, Array("00012345".utf8))
        XCTAssertNotEqual(pattern.replacement, pattern.pattern)
        XCTAssertEqual(pattern.replacement.reduce(0) { $0 + Int($1) }, pattern.pattern.reduce(0) { $0 + Int($1) })
        XCTAssertTrue(pattern.replacement.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        XCTAssertEqual(Self.serialPatterns(0).count, 0)
    }

    func testARealUSBComputerDownloadsRecordsAndStopsAtItsFingerprint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["LIBDC_USB_MODEL"] else {
            throw XCTSkip("Set LIBDC_USB_MODEL to a USB model's name to run against a real computer")
        }
        let usbModels = DeviceCatalog.models(for: .usb)
        let model = try XCTUnwrap(usbModels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame },
                                  "No USB model named \(name); USB models: \(usbModels.map(\.name).joined(separator: ", "))")

        let discovery = IOKitCableDiscovery()
        discovery.start()
        defer { discovery.stop() }
        let endpoint = try usbEndpoint(for: model, in: discovery)
        log("\(endpoint.displayName) " + String(format: "%04X:%04X", endpoint.vendorID ?? 0, endpoint.productID ?? 0)
            + ", \(endpoint.status.rawValue), candidates \(endpoint.candidates.map(\.name)), beta \(endpoint.isBeta)")
        XCTAssertEqual(endpoint.status, .ready)

        // Busy check: with another app holding the interface, the open must say so rather than hang.
        if environment["LIBDC_USB_EXPECT_BUSY"] == "1" {
            XCTAssertEqual(cableOpenError(endpoint, model: model), .busy)
            return
        }

        let fingerprints = DeviceFingerprintStorage(userDefaults: isolatedDefaults("fp"))
        let late = LateScrubber()
        let recorder = DCStreamRecorder(scrubber: DCRecordScrubber { late.scrubber.scrub($0, $1) })
        let started = DispatchTime.now()
        let session = try openCable(endpoint, model: model, discovery: discovery, recorder: recorder, timeout: 30)
        let (firstResult, dives) = downloadToEnd(session, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), timeout: 900)
        let first = try XCTUnwrap(firstResult)
        let rawSerial = session.devicePtr.pointee.have_devinfo != 0 ? session.devicePtr.pointee.devinfo.serial : 0
        let error = CableError(download: first, session: session)
        session.close()
        XCTAssertNil(error, error?.message ?? "")
        XCTAssertEqual(first.outcome, .completed)
        let identity = first.identity
        log("identity \(identity?.canonicalName ?? "none") model \(identity?.model ?? 0), key \(identity?.deviceKey ?? "none"); "
            + "\(dives.count) dives in \(Int(milliseconds(since: started))) ms")
        if let newest = dives.max(by: { $0.datetime < $1.datetime }) {
            log("newest dive: \(newest.maxDepth) m, \(Int(newest.divetime)) s, \(newest.datetime)")
        }

        late.scrubber = .replacing(Self.serialPatterns(rawSerial))
        let recording = recorder.recording(family: model.dcFamily, model: model.model)
        let timedOutReads = recording.exchanges.filter {
            if case .read(_, _, let status) = $0 { return status == DC_STATUS_TIMEOUT } else { return false }
        }.count
        log("\(timedOutReads) reads ended on the timeout")
        let (replayed, replayedDives, script) = try replayDownload(recording, displayName: model.name)
        let serialScrubbed = rawSerial == 0 || (replayed.identity != nil && replayed.identity?.serial != identity?.serial)
        let sameDives = replayedDives.map(\.maxDepth).sorted() == dives.map(\.maxDepth).sorted()
            && replayedDives.map(\.divetime).sorted() == dives.map(\.divetime).sorted()
        XCTAssertNil(script.deviation, "the replay left the recorded exchange")
        XCTAssertEqual(replayed.outcome, .completed)
        XCTAssertTrue(serialScrubbed, "the serial wasn't scrubbed: check serialPatterns against the version block")
        XCTAssertTrue(sameDives, "the scrubber changed dive data or a checksum: narrow serialPatterns")
        if script.deviation == nil, replayed.outcome == .completed, serialScrubbed, sameDives, !dives.isEmpty {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Hardware/\(Self.fixtureName(model)).\(DCRecording.fileExtension)")
            try recording.write(to: url)
            log("wrote \(url.path). It still holds the dives as the computer sent them, dates included: "
                + "commit it only for dives you are happy to publish")
        }

        try XCTUnwrap(first.fingerprintCommit, "a completed download of a computer with dives carries a fingerprint commit").acknowledge()
        let again = try openCable(usbEndpoint(for: model, in: discovery), model: model, discovery: discovery, timeout: 30)
        let (secondResult, newDives) = downloadToEnd(again, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), timeout: 900)
        again.close()
        XCTAssertEqual(secondResult?.outcome, .noNewDives)
        XCTAssertEqual(newDives.count, 0)
    }
}
#endif
