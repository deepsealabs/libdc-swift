#if os(macOS)
import XCTest
import IOKit.hid
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A real USB HID computer: downloads, records a scrubbed `.dcrec` into Fixtures/Hardware, and downloads again; skipped unless LIBDC_USBHID_MODEL is set.
final class HIDHardwareTests: XCTestCase {

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
        return "\(model.family.rawValue)_\(String(product))_usbhid"
    }

    private func hidEndpoint(for model: DCModel, in discovery: IOKitCableDiscovery) throws -> CableEndpoint {
        try XCTUnwrap(discovery.endpoints.first { $0.transport == .usbHID && $0.candidates.contains(model) },
                      "no USB HID endpoint offers \(model.name); listed: \(discovery.endpoints.map(\.displayName))")
    }

    func testARealHIDComputerDownloadsRecordsAndStopsAtItsFingerprint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["LIBDC_USBHID_MODEL"] else {
            throw XCTSkip("Set LIBDC_USBHID_MODEL to a USB HID model's name to run against a real computer")
        }
        let hidModels = DeviceCatalog.models(for: .usbHID)
        let model = try XCTUnwrap(hidModels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame },
                                  "No USB HID model named \(name); USB HID models: \(hidModels.map(\.name).joined(separator: ", "))")
        let accessBefore = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)

        let discovery = IOKitCableDiscovery()
        discovery.start()
        defer { discovery.stop() }
        let endpoint = try hidEndpoint(for: model, in: discovery)
        log("\(endpoint.displayName) " + String(format: "%04X:%04X", endpoint.vendorID ?? 0, endpoint.productID ?? 0)
            + ", \(endpoint.status.rawValue), candidates \(endpoint.candidates.map(\.name))")
        XCTAssertEqual(endpoint.status, .ready)

        // Busy check: with the maker's app holding the device, the open must say so rather than hang.
        if environment["LIBDC_USBHID_EXPECT_BUSY"] == "1" {
            XCTAssertEqual(cableOpenError(endpoint, model: model), .busy)
            return
        }

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
        log("identity \(identity?.canonicalName ?? "none"), key \(identity?.deviceKey ?? "none"); \(dives.count) dives")
        if let newest = dives.max(by: { $0.datetime < $1.datetime }) {
            log("newest dive: \(newest.maxDepth) m, \(Int(newest.divetime)) s, \(newest.datetime)")
        }
        XCTAssertEqual(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent), accessBefore, "the download asked for Input Monitoring")

        late.scrubber = .replacing(SerialHardwareTests.serialPatterns(rawSerial))
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
            log("wrote \(url.path). It still holds the dives as the computer sent them, dates included: "
                + "commit it only for dives you are happy to publish")
        }

        try XCTUnwrap(first.fingerprintCommit, "a completed download of a computer with dives carries a fingerprint commit").acknowledge()
        let again = try openCable(hidEndpoint(for: model, in: discovery), model: model, discovery: discovery, timeout: 30)
        let (secondResult, newDives) = downloadToEnd(again, viewModel: DiveDataViewModel(fingerprintStore: fingerprints), timeout: 900)
        again.close()
        XCTAssertEqual(secondResult?.outcome, .noNewDives)
        XCTAssertEqual(newDives.count, 0)
    }
}
#endif
