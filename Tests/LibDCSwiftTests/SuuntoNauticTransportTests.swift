import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// Drives the real Nautic/Ocean driver (`suunto_nautic.c`) against a scripted
/// fake watch behind a `dc_custom_open` iostream, so the transport fixes for
/// #57-#61 are covered without hardware. The fake speaks the HDLC + RPC framing
/// as captured from real watches (see the issue threads for the wire evidence).
final class SuuntoNauticTransportTests: XCTestCase {

    // MARK: - Fake watch

    struct FakeDive {
        let id: UInt32
        let compressed: [UInt8]
        let summary: [UInt8]
        let decompressed: [UInt8]
        /// The size /Logbook/Entries lists; defaults to the true /Data + /Summary.
        var listedSize: UInt32

        init(id: UInt32, profileBytes: Int, summaryBytes: Int = 2036) {
            self.id = id
            var profile = Array("SBEM0103".utf8)
            profile += (0..<max(0, profileBytes - profile.count)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            decompressed = profile
            compressed = FakeDive.heatshrinkLiterals(profile)
            var s = Array("SBEM0103".utf8)
            s += (0..<max(0, summaryBytes - s.count)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
            summary = s
            listedSize = UInt32(compressed.count + summary.count)
        }

        /// Literal-only Heatshrink stream (tag bit 1 + 8 data bits, MSB first),
        /// valid for any window/lookahead setting.
        static func heatshrinkLiterals(_ input: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(input.count * 9 / 8 + 2)
            var acc: UInt32 = 0
            var bits = 0
            for byte in input {
                acc = (acc << 9) | 0x100 | UInt32(byte)
                bits += 9
                while bits >= 8 {
                    out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits - 8)))
                    bits -= 8
                }
                acc &= (1 << UInt32(bits)) - 1
            }
            if bits > 0 { out.append(UInt8(truncatingIfNeeded: acc << UInt32(8 - bits))) }
            return out
        }
    }

    final class FakeWatch {
        var dives: [FakeDive]                   // any order; served oldest-first
        var entriesPerPage = 18
        var summaryPageSize = 451
        var mdsPayloadSize = 278
        /// Stale 0x01 chunks emitted just before the next /Summary GET's ACK.
        var leftoverChunksBeforeSummaryAck = 0
        /// Streams to refuse with 423 before accepting.
        var refuseStreams = 0
        /// Drop this many bytes off the end of every /Data stream (a short download).
        var truncateStreamBy = 0
        /// How many /Data streams `truncateStreamBy` applies to.
        var truncatedStreams = Int.max
        /// Lose the link after this many chunks of the next /Data stream.
        var dropAfterChunks: Int?
        /// Value resources the watch can be subscribed to.
        var unsyncedCount: UInt16 = 0
        var busy: UInt8 = 0
        private(set) var linkUp = true
        private(set) var drops = 0
        private(set) var connects = 0
        private(set) var subscribed: [String: [UInt8]] = [:]
        private(set) var subscribeCount = 0
        private let lock = NSLock()

        private(set) var getPaths: [String] = []
        private(set) var summaryOffsets: [UInt32] = []
        private(set) var entriesStartAfter: [UInt32?] = []
        private(set) var streamStops = 0
        private(set) var streamsServed = 0

        private var rx: [UInt8] = []
        private var rxIndex = 0
        private var rxDecode: [UInt8] = []
        private var rxInFrame = false
        private var rxEscaped = false
        private var handles: [[UInt8]: String] = [:]
        private var nextHandle: UInt8 = 0x10
        private var pendingDataPath: String?

        init(dives: [FakeDive]) { self.dives = dives }

        /// A fresh link: whatever was in flight on the old one is gone.
        func reconnect() {
            lock.lock(); defer { lock.unlock() }
            linkUp = true
            rx.removeAll(); rxIndex = 0
            rxDecode.removeAll(); rxInFrame = false; rxEscaped = false
            pendingDataPath = nil
            subscribed.removeAll()
            connects += 1
        }

        func dropLink() {
            lock.lock(); defer { lock.unlock() }
            linkUp = false
            drops += 1
        }

        func mutate(_ body: (FakeWatch) -> Void) {
            lock.lock(); defer { lock.unlock() }
            body(self)
        }

        /// Pushes the current value of a subscribed resource, as the watch does when it changes.
        func notify(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            guard let h = subscribed[path] else { return }
            let body = value(for: path)
            let content = [0x00, 0x00] + h + [0x01, 0x80, 0x00] + body + [0x00] + Self.crc
            send([0xA5, 0x01] + Self.u16(content.count - 6) + content)
        }

        private func value(for path: String) -> [UInt8] {
            path == "/Sync/BusyState" ? [0x03, 0x00, busy] : [0x05, 0x00] + Self.u16(Int(unsyncedCount))
        }

        private static let valuePaths: Set<String> = ["/Logbook/UnsynchronisedLogs", "/Sync/BusyState"]

        // Host -> watch bytes (HDLC-encoded). False once the link is down.
        @discardableResult
        func hostWrote(_ bytes: UnsafeRawBufferPointer) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard linkUp else { return false }
            for b in bytes {
                if b == 0x7E {
                    if rxInFrame && !rxDecode.isEmpty { handle(rxDecode) }
                    rxDecode.removeAll(keepingCapacity: true)
                    rxInFrame = true
                    rxEscaped = false
                    continue
                }
                guard rxInFrame else { continue }
                if b == 0x7D { rxEscaped = true; continue }
                rxDecode.append(rxEscaped ? b ^ 0x20 : b)
                rxEscaped = false
            }
            return true
        }

        // Watch -> host bytes; nil once the link is down and nothing is left in flight.
        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            let n = min(size, rx.count - rxIndex)
            guard n > 0 else { return linkUp ? 0 : nil }
            rx.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + rxIndex, byteCount: n) }
            rxIndex += n
            if rxIndex == rx.count { rx.removeAll(keepingCapacity: true); rxIndex = 0 }
            return n
        }

        private func send(_ frame: [UInt8]) {
            rx.append(0x7E)
            for b in frame {
                if b == 0x7E || b == 0x7D { rx.append(0x7D); rx.append(b ^ 0x20) } else { rx.append(b) }
            }
            rx.append(0x7E)
        }

        private static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        private static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        private static let crc: [UInt8] = [0xC1, 0xC2, 0xC3, 0xC4]

        private func dataFrame(msgid: [UInt8], handle: [UInt8], status: Int, body: [UInt8]) -> [UInt8] {
            let content = msgid + handle + [0x01, 0x80, 0x00] + Self.u16(status) + body + Self.crc
            return [0xA5, 0x05] + Self.u16(content.count - 2) + content
        }

        private func chunkFrame(_ payload: ArraySlice<UInt8>) -> [UInt8] {
            var mds = [UInt8](repeating: 0, count: 28)
            mds[0] = 0xA5; mds[1] = 0x01
            mds[6] = 0xF0; mds[7] = 0x24; mds[8] = 0x0E
            mds[20] = UInt8(payload.count & 0xFF); mds[21] = UInt8(payload.count >> 8)
            return mds + payload + Self.crc
        }

        private var sortedDives: [FakeDive] { dives.sorted { $0.id < $1.id } }

        private func handle(_ f: [UInt8]) {
            guard f.count >= 6, f[0] == 0xA5 else { return }
            let msgid = Array(f[4...5])
            switch f[1] {
            case 0x12: // EVA hello
                send([0xA5, 0x13, 0x02, 0x00, 0x00, 0x00, 0x01, 0x02])
            case 0x0A: // GET
                let pathLen = Int(f[9])
                let path = String(decoding: f[10..<(10 + pathLen)], as: UTF8.self)
                getPaths.append(path)
                let h: [UInt8] = [0xF0, 0x24, nextHandle]
                nextHandle &+= 1
                handles[h] = path
                if path.hasSuffix("/Data") { pendingDataPath = path }
                if path.hasSuffix("/Summary") && leftoverChunksBeforeSummaryAck > 0 {
                    for _ in 0..<leftoverChunksBeforeSummaryAck { send(chunkFrame(ArraySlice(repeating: 0xEE, count: 40))) }
                    leftoverChunksBeforeSummaryAck = 0
                }
                // Real ACK: A5 02 08 00 <msgid> F0 24 00 01 80 00 C8 00 <crc>.
                send([0xA5, 0x02, 0x08, 0x00] + msgid + h + [0x01, 0x80, 0x00] + Self.u16(200) + Self.crc)
            case 0x0B: // FETCH1
                break
            case 0x10 where handles[Array(f[6...8])].map(Self.valuePaths.contains) == true: // subscribe to a value
                let h = Array(f[6...8])
                let path = handles[h]!
                subscribed[path] = h
                subscribeCount += 1
                let content = msgid + h + [0x01, 0x80, 0x00] + Self.u16(200) + value(for: path) + Self.crc
                send([0xA5, 0x08] + Self.u16(content.count - 6) + content)
            case 0x11 where handles[Array(f[6...8])].map(Self.valuePaths.contains) == true: // unsubscribe a value
                let h = Array(f[6...8])
                subscribed[handles[h]!] = nil
                let content = msgid + h + [0x01, 0x80, 0x00] + Self.u16(200) + [0x00, 0x00] + Self.crc
                send([0xA5, 0x09] + Self.u16(content.count - 6) + content)
            case 0x10: // FETCH2: stream the pending /Data
                guard let path = pendingDataPath, let dive = dive(for: path) else { return }
                if refuseStreams > 0 {
                    refuseStreams -= 1
                    send([0xA5, 0x08, 0x08, 0x00, 0x00, 0x00, 0xF0, 0x24, 0x0E, 0x01, 0x80, 0x00] + Self.u16(423))
                    return
                }
                streamsServed += 1
                send([0xA5, 0x08, 0x08, 0x00, 0x00, 0x00, 0xF0, 0x24, 0x0E, 0x01, 0x80, 0x00] + Self.u16(200))
                let truncate = truncatedStreams > 0 ? truncateStreamBy : 0
                if truncate > 0 { truncatedStreams -= 1 }
                let bytes = dive.compressed.dropLast(truncate)
                var i = bytes.startIndex
                var sent = 0
                while i < bytes.endIndex {
                    if let limit = dropAfterChunks, sent == limit {
                        dropAfterChunks = nil
                        linkUp = false
                        drops += 1
                        return
                    }
                    let j = min(i + mdsPayloadSize, bytes.endIndex)
                    send(chunkFrame(bytes[i..<j]))
                    sent += 1
                    i = j
                }
            case 0x11: // STREAM_STOP
                streamStops += 1
                pendingDataPath = nil
                send([0xA5, 0x09, 0x02, 0x00] + msgid)
            case 0x0D: // fetch on a handle
                let h = Array(f[6...8])
                guard let path = handles[h] else { return }
                let sublen = Int(f[2]) | Int(f[3]) << 8
                let param: (type: UInt8, value: UInt32)? = sublen >= 13
                    ? (f[13], UInt32(f[15]) | UInt32(f[16]) << 8 | UInt32(f[17]) << 16 | UInt32(f[18]) << 24)
                    : nil
                if path == "/Logbook/Entries" {
                    serveEntries(msgid: msgid, handle: h, param: param)
                } else if path.hasSuffix("/Summary"), let dive = dive(for: path) {
                    let offset = Int(param?.value ?? 0)
                    summaryOffsets.append(UInt32(offset))
                    let end = min(offset + summaryPageSize, dive.summary.count)
                    let data = Array(dive.summary[min(offset, end)..<end])
                    let len = Self.u16(data.count)
                    let header: [UInt8] = [0x0D, 0x00, 0x02, len[0], len[1], 0x00, len[0], len[1], 0x00, len[0], len[1]]
                    send(dataFrame(msgid: msgid, handle: h, status: end < dive.summary.count ? 100 : 200, body: header + data))
                } else if path == "/Info" {
                    send(dataFrame(msgid: msgid, handle: h, status: 200, body: Array("Suunto\0Ocean\0".utf8)))
                } else {
                    send(dataFrame(msgid: msgid, handle: h, status: 404, body: []))
                }
            default:
                break
            }
        }

        private func dive(for path: String) -> FakeDive? {
            let parts = path.split(separator: "/")
            guard parts.count >= 3, let id = UInt32(parts[2]) else { return nil }
            return dives.first { $0.id == id }
        }

        private func serveEntries(msgid: [UInt8], handle: [UInt8], param: (type: UInt8, value: UInt32)?) {
            entriesStartAfter.append(param?.value)
            let all = sortedDives
            let start = param.map { p in all.firstIndex { $0.id > p.value } ?? all.count } ?? 0
            let page = Array(all[start..<min(start + entriesPerPage, all.count)])
            let more = start + page.count < all.count
            var body: [UInt8] = [0x01, 0x24] + Self.u32(2_100_000_000 - 1) + Self.u32(UInt32(page.count))
                + Self.u32(12) + Self.u32(16)
            for d in page {
                body += Self.u32(d.id) + Self.u32(d.id + 1800) + Self.u32(1) + Self.u32(0)
                    + Self.u32(d.listedSize) + Self.u32(0)
            }
            send(dataFrame(msgid: msgid, handle: handle, status: more ? 100 : 200, body: body))
        }
    }

    // MARK: - Harness

    private final class Session {
        let watch: FakeWatch
        var context: OpaquePointer?
        var iostream: OpaquePointer?
        var device: OpaquePointer?
        init(watch: FakeWatch) { self.watch = watch }
    }

    private var sessions: [Session] = []
    private let sessionsLock = NSLock()

    override func tearDown() {
        sessionsLock.lock()
        let open = sessions
        sessions.removeAll()
        sessionsLock.unlock()
        open.forEach(Self.close)
        super.tearDown()
    }

    private static func close(_ s: Session) {
        if let d = s.device { dc_device_close(d) }
        if let io = s.iostream { dc_iostream_close(io) }
        if let c = s.context { dc_context_free(c) }
    }

    private func close(device: OpaquePointer) {
        sessionsLock.lock()
        let index = sessions.firstIndex { $0.device == device }
        let session = index.map { sessions.remove(at: $0) }
        sessionsLock.unlock()
        session.map(Self.close)
    }

    private static func watch(_ userdata: UnsafeMutableRawPointer?) -> FakeWatch {
        Unmanaged<FakeWatch>.fromOpaque(userdata!).takeUnretainedValue()
    }

    private func open(_ watch: FakeWatch) throws -> OpaquePointer {
        let s = Session(watch: watch)
        sessionsLock.lock()
        sessions.append(s)
        sessionsLock.unlock()
        XCTAssertEqual(dc_context_new(&s.context), DC_STATUS_SUCCESS)

        var cbs = dc_custom_cbs_t()
        cbs.set_timeout = { _, _ in DC_STATUS_SUCCESS }
        cbs.read = { userdata, data, size, actual in
            guard let n = SuuntoNauticTransportTests.watch(userdata).hostRead(into: data!, size: size) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            guard SuuntoNauticTransportTests.watch(userdata).hostWrote(UnsafeRawBufferPointer(start: data, count: size)) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        cbs.purge = { _, _ in DC_STATUS_SUCCESS }
        cbs.sleep = { _, _ in DC_STATUS_SUCCESS }
        cbs.close = { _ in DC_STATUS_SUCCESS }

        let userdata = Unmanaged.passUnretained(watch).toOpaque()
        XCTAssertEqual(dc_custom_open(&s.iostream, s.context, DC_TRANSPORT_BLE, &cbs, userdata), DC_STATUS_SUCCESS)

        var descriptor: OpaquePointer?
        var iterator: OpaquePointer?
        XCTAssertEqual(dc_descriptor_iterator_new(&iterator, s.context), DC_STATUS_SUCCESS)
        var candidate: OpaquePointer?
        while dc_iterator_next(iterator, &candidate) == DC_STATUS_SUCCESS {
            if dc_descriptor_get_type(candidate) == DC_FAMILY_SUUNTO_NAUTIC {
                descriptor = candidate
                break
            }
            dc_descriptor_free(candidate)
        }
        dc_iterator_free(iterator)
        let desc = try XCTUnwrap(descriptor, "no Suunto Nautic descriptor")
        defer { dc_descriptor_free(desc) }

        XCTAssertEqual(dc_device_open(&s.device, s.context, desc, s.iostream), DC_STATUS_SUCCESS)
        return try XCTUnwrap(s.device)
    }

    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * UInt32(i)) }
        return v
    }

    private final class Downloads {
        var dives: [(fingerprint: UInt32, data: [UInt8])] = []
    }

    private func foreach(_ device: OpaquePointer, fingerprint: UInt32? = nil) -> (dc_status_t, [(fingerprint: UInt32, data: [UInt8])]) {
        if var fp = fingerprint?.littleEndian {
            withUnsafeBytes(of: &fp) { raw in
                _ = dc_device_set_fingerprint(device, raw.bindMemory(to: UInt8.self).baseAddress, 4)
            }
        }
        let downloads = Downloads()
        let ptr = Unmanaged.passRetained(downloads).toOpaque()
        defer { Unmanaged<Downloads>.fromOpaque(ptr).release() }
        let status = dc_device_foreach(device, { data, size, fp, fpSize, userdata in
            let d = Unmanaged<Downloads>.fromOpaque(userdata!).takeUnretainedValue()
            var id: UInt32 = 0
            if let fp, fpSize == 4 { id = SuuntoNauticTransportTests.le32(Array(UnsafeBufferPointer(start: fp, count: 4)), 0) }
            d.dives.append((id, Array(UnsafeBufferPointer(start: data, count: Int(size)))))
            return 1
        }, ptr)
        return (status, downloads.dives)
    }

    private func list(_ device: OpaquePointer) -> [UInt32] {
        let buffer = dc_buffer_new(0)!
        defer { dc_buffer_free(buffer) }
        XCTAssertEqual(suunto_nautic_device_list(device, buffer), DC_STATUS_SUCCESS)
        let bytes = Array(UnsafeBufferPointer(start: dc_buffer_get_data(buffer), count: dc_buffer_get_size(buffer)))
        return stride(from: 0, to: bytes.count, by: 4).map { Self.le32(bytes, $0) }
    }

    private func download(_ device: OpaquePointer, id: UInt32) -> (dc_status_t, [UInt8]) {
        let buffer = dc_buffer_new(0)!
        defer { dc_buffer_free(buffer) }
        let status = suunto_nautic_device_download(device, String(id), buffer)
        let size = dc_buffer_get_size(buffer)
        let bytes = size > 0 ? Array(UnsafeBufferPointer(start: dc_buffer_get_data(buffer), count: size)) : []
        return (status, bytes)
    }

    // MARK: - #60: the stream is read to its end, then closed

    func testLongDiveStreamIsNotCutAt4096Frames() throws {
        // ~1.2 MB compressed: well past the old 4096-frame cap (~1.14 MB).
        let dive = FakeDive(id: 1_789_487_761, profileBytes: 1_080_000)
        XCTAssertGreaterThan(dive.compressed.count / 278, 4096)
        let watch = FakeWatch(dives: [dive])
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.count, 1)
        XCTAssertEqual(dives.first?.data, dive.decompressed + dive.summary)
        XCTAssertEqual(watch.streamStops, 1)
    }

    // MARK: - #57: /Summary page header and CRC are stripped, offsets count data

    func testSummaryPagingKeepsOnlyDataBytes() throws {
        let dive = FakeDive(id: 1_789_390_908, profileBytes: 4000, summaryBytes: 2036)
        let watch = FakeWatch(dives: [dive])
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.first?.data, dive.decompressed + dive.summary)
        XCTAssertEqual(watch.summaryOffsets, [0, 451, 902, 1353, 1804])
    }

    // MARK: - #59: a leftover stream chunk is never taken as a GET's reply

    func testLeftoverStreamChunksAreNotTakenAsTheSummaryAck() throws {
        let dive = FakeDive(id: 1_789_487_762, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.leftoverChunksBeforeSummaryAck = 3
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.first?.data, dive.decompressed + dive.summary)
    }

    func testRefusedStreamIsRetried() throws {
        let dive = FakeDive(id: 1_789_487_763, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.refuseStreams = 1
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.first?.data, dive.decompressed + dive.summary)
        XCTAssertEqual(watch.streamsServed, 1)
    }

    // MARK: - #61: every /Logbook/Entries page is listed

    private func ocean23() -> [FakeDive] {
        (0..<23).map { FakeDive(id: 1_788_000_000 + UInt32($0) * 20_000, profileBytes: 600, summaryBytes: 100) }
    }

    func testListingFollowsStartAfterIdPages() throws {
        let dives = ocean23()
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        let ids = list(device)
        XCTAssertEqual(ids, dives.map(\.id).sorted(by: >))
        XCTAssertEqual(watch.entriesStartAfter, [nil, dives[17].id])
    }

    func testFingerprintOnSecondPageDownloadsOnlyNewerDives() throws {
        let dives = ocean23()
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        let (status, downloaded) = foreach(device, fingerprint: dives[20].id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(downloaded.map(\.fingerprint), [dives[22].id, dives[21].id])
    }

    // MARK: - #58: downloads are checked against the listed size

    func testShortDownloadIsReportedAgainstListedSize() throws {
        let dive = FakeDive(id: 1_789_312_841, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_DATAFORMAT)
        XCTAssertFalse(data.isEmpty, "the truncated dive stays available to the caller")
        XCTAssertEqual(watch.streamsServed, 2, "a mismatch is retried once")
    }

    func testShortDownloadIsStillDeliveredByForeach() throws {
        let dive = FakeDive(id: 1_789_312_842, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.count, 1)
    }

    func testCompleteDownloadById() throws {
        let dive = FakeDive(id: 1_789_312_843, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.decompressed + dive.summary)
        XCTAssertEqual(watch.streamsServed, 1)
    }

    // MARK: - Auto download: reconnect, resume, no duplicates

    /// Opens a fresh driver session on the same fake watch for every connect, like a real reconnect.
    private final class FakeConnector: NauticSyncConnector {
        let watch: FakeWatch
        let openSession: () throws -> OpaquePointer
        let closeSession: (OpaquePointer) -> Void
        private let lock = NSLock()
        private var _connects = 0
        var connects: Int { lock.lock(); defer { lock.unlock() }; return _connects }

        init(watch: FakeWatch, open: @escaping () throws -> OpaquePointer, close: @escaping (OpaquePointer) -> Void) {
            self.watch = watch
            openSession = open
            closeSession = close
        }

        func waitUntilPresent(timeout: TimeInterval?) async throws -> Bool { true }

        func connect() throws -> NauticSyncLink {
            lock.lock(); _connects += 1; lock.unlock()
            watch.reconnect()
            return DCDeviceNauticLink(device: try openSession(), onClose: closeSession)
        }

        func simulateDrop() {
            watch.dropLink()
        }
    }

    /// Virtual time: sleeps return at once and are recorded.
    private final class VirtualClock {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        private var recorded: [TimeInterval] = []
        var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }

        private func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
            recorded.append(seconds)
        }

        var environment: NauticAutoSync.Environment {
            NauticAutoSync.Environment(now: { [self] in
                lock.lock(); defer { lock.unlock() }
                return current
            }, sleep: { [self] seconds in
                advance(seconds)
                try Task.checkCancellation()
                await Task.yield()
            })
        }
    }

    private final class EventLog {
        private let lock = NSLock()
        private var items: [NauticAutoSync.Event] = []
        var all: [NauticAutoSync.Event] { lock.lock(); defer { lock.unlock() }; return items }
        func append(_ e: NauticAutoSync.Event) { lock.lock(); items.append(e); lock.unlock() }
    }

    private func makeAutoSync(_ watch: FakeWatch, store: AutoSyncStore = InMemoryAutoSyncStore(),
                              configure: (inout NauticAutoSync.Configuration) -> Void = { _ in })
        -> (NauticAutoSync, FakeConnector, VirtualClock, EventLog) {
        let connector = FakeConnector(watch: watch, open: { [unowned self] in try self.open(watch) },
                                      close: { [unowned self] in self.close(device: $0) })
        var config = NauticAutoSync.Configuration()
        config.refreshInterval = nil
        configure(&config)
        let clock = VirtualClock()
        let sync = NauticAutoSync(deviceKey: "Suunto Nautic test", connector: connector, store: store,
                                  configuration: config, environment: clock.environment)
        let log = EventLog()
        Task { for await event in sync.events { log.append(event) } }
        return (sync, connector, clock, log)
    }

    private func waitFor(_ log: EventLog, timeout: TimeInterval = 20, _ done: ([NauticAutoSync.Event]) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(log.all) {
            if Date() > deadline { return XCTFail("timed out; events: \(log.all)") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func stopAndWait(_ sync: NauticAutoSync, _ log: EventLog) async {
        sync.stop()
        await waitFor(log) { $0.contains(.state(.stopped)) }
    }

    private static func dives(_ events: [NauticAutoSync.Event]) -> [NauticAutoSync.DownloadedDive] {
        events.compactMap { if case .dive(let d) = $0 { return d } else { return nil } }
    }

    private static func completedSyncs(_ events: [NauticAutoSync.Event]) -> [NauticAutoSync.SyncSummary] {
        events.compactMap { if case .syncCompleted(let s) = $0 { return s } else { return nil } }
    }

    func testAutoSyncReconnectsAfterADropMidDataAndResumes() async throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_000_000 + UInt32($0) * 7200, profileBytes: 6000) }
        let watch = FakeWatch(dives: dives)
        let store = InMemoryAutoSyncStore()
        let (sync, connector, clock, log) = makeAutoSync(watch, store: store)

        // First dive downloads, then the link dies two chunks into the second.
        var streams = 0
        sync.onDive = { _ in
            streams += 1
            if streams == 1 { watch.mutate { $0.dropAfterChunks = 2 } }
        }
        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        let events = log.all
        let delivered = Self.dives(events)
        XCTAssertEqual(delivered.map(\.id), dives.map(\.id), "oldest first, each dive exactly once")
        for (dive, fake) in zip(delivered, dives) {
            XCTAssertEqual(dive.data, Data(fake.decompressed + fake.summary))
            XCTAssertTrue(dive.isComplete)
        }
        XCTAssertEqual(delivered[1].attempts, 2, "the dive the link died on is fetched again from the start")
        XCTAssertEqual(watch.drops, 1)
        XCTAssertEqual(connector.connects, 2)
        XCTAssertTrue(events.contains(.state(.reconnecting(attempt: 1, delay: 4))))
        XCTAssertTrue(clock.sleeps.contains(4))
        XCTAssertEqual(store.syncedIDs(device: sync.deviceKey), Set(dives.map(\.id)))
        XCTAssertEqual(Self.completedSyncs(events).first?.downloaded, dives.map(\.id))
    }

    func testAutoSyncReconnectsToRetryAnIncompleteDive() async throws {
        let dive = FakeDive(id: 1_789_100_000, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        watch.truncatedStreams = 2 // the driver's own retry also comes back short
        let (sync, connector, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        let delivered = Self.dives(log.all)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.isComplete, true)
        XCTAssertEqual(delivered.first?.data, Data(dive.decompressed + dive.summary))
        XCTAssertEqual(connector.connects, 2)
    }

    func testAutoSyncKeepsAPersistentlyShortDiveOnceRetriesRunOut() async throws {
        let dive = FakeDive(id: 1_789_200_000, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        let (sync, connector, _, log) = makeAutoSync(watch) { $0.retriesPerDive = 1 }

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        let delivered = Self.dives(log.all)
        XCTAssertEqual(delivered.count, 1, "delivered once, never duplicated")
        XCTAssertEqual(delivered.first?.isComplete, false)
        XCTAssertEqual(delivered.first?.attempts, 2)
        XCTAssertEqual(connector.connects, 2)
    }

    func testAutoSyncSkipsDivesAlreadySynced() async throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_300_000 + UInt32($0) * 7200, profileBytes: 600, summaryBytes: 100) }
        let watch = FakeWatch(dives: dives)
        let store = InMemoryAutoSyncStore()
        store.markSynced([dives[0].id, dives[1].id], device: "Suunto Nautic test")
        let (sync, _, _, log) = makeAutoSync(watch, store: store)

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        XCTAssertEqual(Self.dives(log.all).map(\.id), [dives[2].id])
        XCTAssertEqual(watch.streamsServed, 1)
    }

    func testUnsynchronisedLogsNotificationTriggersASync() async throws {
        let first = FakeDive(id: 1_789_400_000, profileBytes: 600, summaryBytes: 100)
        let second = FakeDive(id: 1_789_410_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [first])
        watch.unsyncedCount = 1
        let (sync, connector, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { events in
            guard let done = events.firstIndex(where: { if case .syncCompleted = $0 { return true } else { return false } }) else { return false }
            return events[done...].contains(.state(.watching))
        }
        XCTAssertNotNil(watch.subscribed["/Logbook/UnsynchronisedLogs"], "subscribed again after the download")
        XCTAssertNotNil(watch.subscribed["/Sync/BusyState"])

        watch.mutate {
            $0.dives.append(second)
            $0.unsyncedCount = 2
        }
        watch.notify("/Logbook/UnsynchronisedLogs")
        await waitFor(log) { Self.completedSyncs($0).count == 2 }
        await stopAndWait(sync, log)

        XCTAssertEqual(Self.dives(log.all).map(\.id), [first.id, second.id])
        XCTAssertEqual(Self.completedSyncs(log.all).last?.downloaded, [second.id])
        XCTAssertEqual(connector.connects, 1, "the trigger is handled on the same connection")
    }

    func testBusyWatchDefersTheSync() async throws {
        let dive = FakeDive(id: 1_789_500_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [dive])
        watch.busy = 1
        let (sync, _, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { $0.contains(.state(.watchBusy)) }
        XCTAssertFalse(watch.getPaths.contains("/Logbook/Entries"), "nothing is listed while the watch is busy")

        watch.mutate { $0.busy = 0 }
        watch.notify("/Sync/BusyState")
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        XCTAssertEqual(Self.dives(log.all).map(\.id), [dive.id])
    }

    func testSimulatedDropDuringIdleReconnects() async throws {
        let dive = FakeDive(id: 1_789_600_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [dive])
        let (sync, connector, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { $0.contains(.state(.watching)) }
        watch.mutate { $0.dives.append(FakeDive(id: 1_789_610_000, profileBytes: 600, summaryBytes: 100)) }
        sync.simulateDrop()
        await waitFor(log) { Self.completedSyncs($0).count == 2 }
        await stopAndWait(sync, log)

        XCTAssertEqual(Self.dives(log.all).map(\.id), [dive.id, 1_789_610_000], "a reconnect always re-lists")
        XCTAssertEqual(connector.connects, 2)
        XCTAssertEqual(watch.drops, 1)
    }
}
