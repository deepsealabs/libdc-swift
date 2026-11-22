import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// Replays the watch's side of DC Tester build 32's Suunto-app run on libdc-swift#29 against the driver: auto download
/// on a Nautic while the Suunto app synced it. The frames are the watch's as logged, with a synthetic identity in its
/// hello replies and synthetic dive bytes (`suunto_nautic_app_takeover_replay.json`). Each request the driver sends is
/// answered with the watch's frames for it, in the order of the log, so anything the driver sends after stepping aside
/// shows up as unexpected.
final class NauticAppTakeoverReplayTests: XCTestCase {
    enum Item {
        /// A whole frame; `patch` puts the request's sequence number on it and recomputes its CRC.
        case frame([UInt8], patch: Bool)
        /// HDLC bytes as they arrived, flags and all, such as a stream with a torn chunk.
        case raw([UInt8])
    }

    final class ReplayWatch {
        var steps: [(op: UInt8, items: [Item])] = []
        private(set) var requests: [UInt8] = []
        private(set) var unexpected: [UInt8] = []
        private var rx: [UInt8] = []
        private var rxIndex = 0
        private var decoded: [UInt8] = []
        private var inFrame = false
        private var escaped = false
        private let lock = NSLock()

        func hostWrote(_ bytes: UnsafeRawBufferPointer) {
            lock.lock(); defer { lock.unlock() }
            for b in bytes {
                if b == 0x7E {
                    if inFrame && !decoded.isEmpty { handle(decoded) }
                    decoded.removeAll()
                    inFrame = true
                    escaped = false
                    continue
                }
                guard inFrame else { continue }
                if b == 0x7D { escaped = true; continue }
                decoded.append(escaped ? b ^ 0x20 : b)
                escaped = false
            }
        }

        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = min(size, rx.count - rxIndex)
            guard n > 0 else { return 0 }
            rx.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + rxIndex, byteCount: n) }
            rxIndex += n
            if rxIndex == rx.count { rx.removeAll(); rxIndex = 0 }
            return n
        }

        private func handle(_ request: [UInt8]) {
            requests.append(request[1])
            guard let step = steps.first, step.op == request[1] else {
                unexpected.append(request[1])
                return
            }
            steps.removeFirst()
            for item in step.items {
                switch item {
                case .raw(let bytes):
                    rx += bytes
                case .frame(var frame, let patch):
                    if patch {
                        frame[4] = request[4]
                        frame[5] = request[5]
                        frame.removeLast(4)
                        let crc = SuuntoNauticTransportTests.FakeWatch.crc32(frame)
                        frame += (0..<4).map { UInt8((crc >> (8 * UInt32($0))) & 0xFF) }
                    }
                    rx.append(0x7E)
                    for b in frame {
                        if b == 0x7E || b == 0x7D { rx.append(0x7D); rx.append(b ^ 0x20) } else { rx.append(b) }
                    }
                    rx.append(0x7E)
                }
            }
        }
    }

    private var fixture: [String: Any] = [:]
    private var context: OpaquePointer?
    private var iostreams: [OpaquePointer] = []
    private var devices: [OpaquePointer] = []

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_app_takeover_replay", withExtension: "json"))
        fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
    }

    override func tearDown() {
        devices.forEach { dc_device_close($0) }
        iostreams.forEach { dc_iostream_close($0) }
        if let context { dc_context_free(context) }
        super.tearDown()
    }

    private func bytes(_ key: String) -> [UInt8] { hex(fixture[key] as! String) }

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func open(_ watch: ReplayWatch, resume: SuuntoNauticResume) throws -> OpaquePointer {
        var cbs = dc_custom_cbs_t()
        cbs.set_timeout = { _, _ in DC_STATUS_SUCCESS }
        cbs.read = { userdata, data, size, actual in
            let n = Unmanaged<ReplayWatch>.fromOpaque(userdata!).takeUnretainedValue().hostRead(into: data!, size: size)
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            Unmanaged<ReplayWatch>.fromOpaque(userdata!).takeUnretainedValue()
                .hostWrote(UnsafeRawBufferPointer(start: data, count: size))
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        cbs.purge = { _, _ in DC_STATUS_SUCCESS }
        cbs.sleep = { _, _ in DC_STATUS_SUCCESS }
        cbs.close = { _ in DC_STATUS_SUCCESS }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_BLE, &cbs, Unmanaged.passUnretained(watch).toOpaque()),
                       DC_STATUS_SUCCESS)
        iostreams.append(try XCTUnwrap(iostream))

        var descriptor: OpaquePointer?
        var iterator: OpaquePointer?
        XCTAssertEqual(dc_descriptor_iterator_new(&iterator, context), DC_STATUS_SUCCESS)
        var candidate: OpaquePointer?
        while dc_iterator_next(iterator, &candidate) == DC_STATUS_SUCCESS {
            if dc_descriptor_get_type(candidate) == DC_FAMILY_SUUNTO_NAUTIC { descriptor = candidate; break }
            dc_descriptor_free(candidate)
        }
        dc_iterator_free(iterator)
        defer { dc_descriptor_free(descriptor) }
        var device: OpaquePointer?
        XCTAssertEqual(dc_device_open(&device, context, descriptor, iostream), DC_STATUS_SUCCESS)
        let opened = try XCTUnwrap(device)
        devices.append(opened)
        XCTAssertTrue(resume.attach(opened, watch: "replay"))
        return opened
    }

    /// The probe, answered (the Suunto app's session is on the link), then the by-id download's listing.
    private func openAndListSteps() -> [(op: UInt8, items: [Item])] {
        let pages = (fixture["entries_pages"] as! [String]).map(hex)
        return [
            (0x0A, [.frame(bytes("entries_get"), patch: true)]),
            (0x0A, [.frame(bytes("entries_get"), patch: true)]),
            (0x0D, [.frame(pages[0], patch: true)]),
            (0x0D, [.frame(pages[1], patch: true)]),
        ]
    }

    /// The /Summary as the watch served it: GET, its pages, RELEASE.
    private func summarySteps(_ key: String) -> [(op: UInt8, items: [Item])] {
        (fixture[key] as! [[String: Any]]).map { step in
            (UInt8(step["op"] as! Int), [.frame(hex(step["reply"] as! String), patch: true)])
        }
    }

    private func download(_ device: OpaquePointer, _ id: UInt32) -> dc_status_t {
        let buffer = dc_buffer_new(0)!
        defer { dc_buffer_free(buffer) }
        return suunto_nautic_device_download(device, String(id), buffer)
    }

    /// 14:14:04: the app's hello cut a chunk off, its reply right behind it. Before the shared-flag reading, the hello
    /// was lost with the chunk, and an UNSUBSCRIBE went into the app's session for a 404.
    func testAnAppHelloThatTearsAChunkStepsAsideAndKeepsTheBytes() throws {
        let id: UInt32 = 1_792_334_897
        let watch = ReplayWatch()
        watch.steps = openAndListSteps() + summarySteps("s1_summary") + [
            (0x0A, [.frame(bytes("s1_data_get"), patch: true)]),
            (0x10, [.frame(bytes("s1_sub"), patch: true), .raw(bytes("s1_stream_raw"))]),
            (0x11, [.frame(bytes("s1_unsub"), patch: true)]),
        ]
        let resume = SuuntoNauticResume()
        let device = try open(watch, resume: resume)

        XCTAssertEqual(download(device, id), DC_STATUS_IO)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: id, on: device), 328_040)
        XCTAssertEqual(watch.requests.last, 0x10, "the hello reply is read behind the torn chunk: no UNSUBSCRIBE")
        XCTAssertTrue(watch.unexpected.isEmpty, "nothing after the step-aside: \(watch.unexpected)")
        XCTAssertEqual(watch.steps.count, 1, "only the UNSUBSCRIBE's reply is left")
    }

    /// 14:15:29: the app's hello reply arrived whole between two chunks; 14:15:40: the next connection's resume met
    /// the app's hello and its replies during the /Summary.
    func testAnAppHelloBetweenChunksThenAgainDuringTheResumeKeepsTheBytesBoth() throws {
        let id: UInt32 = 1_792_349_453
        let resume = SuuntoNauticResume()
        let watch = ReplayWatch()
        watch.steps = openAndListSteps() + summarySteps("s2_summary") + [
            (0x0A, [.frame(bytes("s2_data_get"), patch: true)]),
            (0x10, [.frame(bytes("s2_sub"), patch: true), .raw(bytes("s2_stream_raw"))]),
        ]
        let device = try open(watch, resume: resume)

        XCTAssertEqual(download(device, id), DC_STATUS_IO)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: id, on: device), 77_562)
        XCTAssertEqual(watch.requests.last, 0x10)
        XCTAssertTrue(watch.unexpected.isEmpty, "no UNSUBSCRIBE or RELEASE into the app's session: \(watch.unexpected)")

        let frames = (fixture["s3_frames"] as! [String]).map(hex)
        let next = ReplayWatch()
        next.steps = openAndListSteps() + [
            (0x0A, [.frame(bytes("s3_summary_get"), patch: true)]),
            (0x0D, [.frame(frames[0], patch: false), .frame(frames[1], patch: true), .frame(frames[2], patch: false)]),
        ]
        let resumed = try open(next, resume: resume)

        XCTAssertEqual(download(resumed, id), DC_STATUS_IO)
        XCTAssertEqual(suunto_nautic_device_taken_over(resumed), 1)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: id, on: resumed), 77_562, "the kept bytes survive")
        XCTAssertTrue(next.unexpected.isEmpty, "\(next.unexpected)")
    }
}
