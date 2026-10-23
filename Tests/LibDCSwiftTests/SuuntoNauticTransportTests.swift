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
            let seed = Int(id % 251)
            profile += (0..<max(0, profileBytes - profile.count)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7 &+ seed) }
            decompressed = profile
            compressed = FakeDive.heatshrinkLiterals(profile)
            var s = Array("SBEM0103".utf8)
            s += (0..<max(0, summaryBytes - s.count)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
            summary = s
            listedSize = UInt32(compressed.count + summary.count)
        }

        /// An empty/aborted logbook entry: listed with size 0, no profile data.
        init(emptyID id: UInt32) {
            self.id = id
            compressed = []
            summary = []
            decompressed = []
            listedSize = 0
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
        /// Served for any /Logbook/byId/<id>/Descriptors, paged like /Summary.
        var descriptors: [UInt8] = []
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
        /// /Data streams to end without their end markers, as if both were lost.
        var streamsWithoutEndMarker = 0
        /// /Data streams in which the second chunk is sent twice.
        var streamsWithRepeatedChunk = 0
        /// Value resources the watch can be subscribed to.
        var unsyncedCount: UInt16 = 0
        var busy: UInt8 = 0
        /// A dropped link leaves the watch's session behind: bound slots, subscriptions and the
        /// requests it saw recently, of which an identical repeat goes unanswered as a retransmit.
        /// Models the reconnects in #29 whose trigger subscription timed out; a clean close ends the session.
        var keepsSessionAcrossDrops = false
        /// Value resources resolve into 00/10 slots like per-id ones, and a GET with both bound
        /// goes unanswered. Real watches answer them with static F0 handles.
        var valueSlots = false
        /// GETs of a value resource to leave unanswered.
        var unansweredValueGets = 0
        /// After a drop, the next hello is answered behind this many frames of the interrupted
        /// /Data stream, and a request that arrives before the host has read the Hello-Ack goes
        /// unanswered. Models the quick Ocean reconnects traced in #29.
        var staleFramesAfterDrop = 0
        /// A sleeping watch: the hello gets one stray frame and no Hello-Ack.
        var withholdHelloAck = false
        private var pendingStaleFrames = 0
        private var helloAckEnd: Int?
        private(set) var ignoredRequests = 0
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
        private(set) var releases = 0
        /// Paths of the /Data streams served, in order.
        private(set) var streamedPaths: [String] = []

        private var rx: [UInt8] = []
        private var rxIndex = 0
        private var rxDecode: [UInt8] = []
        private var rxInFrame = false
        private var rxEscaped = false
        private var handles: [[UInt8]: String] = [:]
        private var nextHandle: UInt8 = 0x10
        /// Per-id resources resolve into a slot (00 or 10) bound to that id until a 0x0B release, as on the real watch.
        private var heldSlots: Set<[UInt8]> = []
        private var recentRequests: [[UInt8]] = []

        /// Handles of per-id resources still bound (not yet released).
        var heldIdHandles: [String] {
            lock.lock(); defer { lock.unlock() }
            return heldSlots.compactMap { handles[$0] }.sorted()
        }

        /// Slots still bound per value resource (valueSlots only).
        func heldValueSlots(_ path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return heldSlots.filter { handles[$0] == path }.count
        }

        init(dives: [FakeDive]) { self.dives = dives }

        /// A fresh link: whatever was in flight on the old one is gone.
        func reconnect() {
            lock.lock(); defer { lock.unlock() }
            if !linkUp { pendingStaleFrames = staleFramesAfterDrop }
            helloAckEnd = nil
            if !(keepsSessionAcrossDrops && !linkUp) {
                heldSlots.removeAll()
                subscribed.removeAll()
                recentRequests.removeAll()
            }
            linkUp = true
            rx.removeAll(); rxIndex = 0
            rxDecode.removeAll(); rxInFrame = false; rxEscaped = false
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
            send(Self.packet(0x01, [0x00, 0x00], h + [0x01, 0x80, 0x00] + body + [0x00]))
        }

        private func value(for path: String) -> [UInt8] {
            path == "/Sync/BusyState" ? [0x03, 0x00, busy] : [0x05, 0x00] + Self.u16(Int(unsyncedCount))
        }

        private static let valueHandles: [String: [UInt8]] = ["/Logbook/UnsynchronisedLogs": [0x24, 0x0D], "/Sync/BusyState": [0x4C, 0x00]]
        private static var valuePaths: Set<String> { Set(valueHandles.keys) }

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
            if let end = helloAckEnd, rxIndex >= end { helloAckEnd = nil }
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
        static func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                crc ^= UInt32(b)
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }

        /// A5 <op> <length:u16> <msgid:2> <payload> <crc32:u32>, as the watch frames every packet.
        static func packet(_ op: UInt8, _ msgid: [UInt8], _ payload: [UInt8]) -> [UInt8] {
            let head = [0xA5, op] + u16(payload.count) + msgid + payload
            return head + u32(crc32(head))
        }

        /// The watch's Hello reply payload (protocol versions, its packed serial, Whiteboard version).
        private static let helloReply: [UInt8] = [0x09, 0x09, 0x04] + [UInt8](repeating: 0x11, count: 12)
            + [0x04, 0x01, 0x02] + [UInt8](repeating: 0, count: 5) + [0x01] + [UInt8](repeating: 0, count: 8)

        private func dataFrame(msgid: [UInt8], handle: [UInt8], status: Int, body: [UInt8]) -> [UInt8] {
            Self.packet(0x05, msgid, handle + [0x01, 0x80, 0x00] + Self.u16(status) + body)
        }

        /// A /Data notification: HANDLE(3) FLAGS(3) ?(4) OFFSET(4) LENGTH(2) ?(6) DATA.
        private func chunkFrame(_ payload: ArraySlice<UInt8>, offset: Int = 0) -> [UInt8] {
            Self.packet(0x01, [0x00, 0x00], [0xF0, 0x24, 0x0E, 0x01, 0x80, 0x00, 0x02, 0x24, 0x22, 0x25]
                + Self.u32(UInt32(offset)) + Self.u16(payload.count) + [0x00, 0x10, 0x0C, 0x00, 0x00, 0x00] + Array(payload))
        }

        private var sortedDives: [FakeDive] { dives.sorted { $0.id < $1.id } }

        private func handle(_ f: [UInt8]) {
            guard f.count >= 6, f[0] == 0xA5 else { return }
            let msgid = Array(f[4...5])
            if f[1] != 0x12 {
                if helloAckEnd != nil {
                    ignoredRequests += 1
                    return
                }
                if keepsSessionAcrossDrops && recentRequests.contains(f) {
                    ignoredRequests += 1
                    return
                }
                recentRequests.append(f)
                if recentRequests.count > 64 { recentRequests.removeFirst() }
            }
            switch f[1] {
            case 0x12: // EVA hello
                if withholdHelloAck {
                    send(chunkFrame(ArraySlice(repeating: 0xEE, count: 40)))
                } else if pendingStaleFrames > 0 {
                    // The tail of a frame cut mid-way, then an empty frame, then the old stream.
                    rx += [0x11, 0x22, 0x7E, 0x7E]
                    for _ in 0..<pendingStaleFrames { send(chunkFrame(ArraySlice(repeating: 0xEE, count: 40))) }
                    pendingStaleFrames = 0
                    send(Self.packet(0x13, [0x00, 0x00], Self.helloReply))
                    helloAckEnd = rx.count
                } else {
                    send(Self.packet(0x13, [0x00, 0x00], Self.helloReply))
                }
            case 0x0A: // GET
                let pathLen = Int(f[9])
                let path = String(decoding: f[10..<(10 + pathLen)], as: UTF8.self)
                getPaths.append(path)
                if Self.valuePaths.contains(path) && unansweredValueGets > 0 {
                    unansweredValueGets -= 1
                    return
                }
                guard let h = resolve(path) else { return }
                handles[h] = path
                if path.hasSuffix("/Summary") && leftoverChunksBeforeSummaryAck > 0 {
                    for _ in 0..<leftoverChunksBeforeSummaryAck { send(chunkFrame(ArraySlice(repeating: 0xEE, count: 40))) }
                    leftoverChunksBeforeSummaryAck = 0
                }
                // Real ACK: A5 02 08 00 <msgid> F0 24 00 01 80 00 C8 00 <crc>.
                send(Self.packet(0x02, msgid, h + [0x01, 0x80, 0x00] + Self.u16(200)))
            case 0x0B: // release a resolved handle
                let h = Array(f[6...8])
                releases += 1
                heldSlots.remove(h)
                send(Self.packet(0x03, msgid, h + [0x01, 0x80, 0x00] + Self.u16(200)))
            case 0x10 where handles[Array(f[6...8])].map(Self.valuePaths.contains) == true: // subscribe to a value
                let h = Array(f[6...8])
                let path = handles[h]!
                subscribed[path] = h
                subscribeCount += 1
                send(Self.packet(0x08, msgid, h + [0x01, 0x80, 0x00] + Self.u16(200) + value(for: path)))
            case 0x11 where handles[Array(f[6...8])].map(Self.valuePaths.contains) == true: // unsubscribe a value
                let h = Array(f[6...8])
                subscribed[handles[h]!] = nil
                send(Self.packet(0x09, msgid, h + [0x01, 0x80, 0x00] + Self.u16(200) + [0x00, 0x00]))
            case 0x10: // subscribe to a /Data handle: stream the dive bound to it
                let h = Array(f[6...8])
                guard let path = handles[h], path.hasSuffix("/Data"), let dive = dive(for: path) else { return }
                if refuseStreams > 0 {
                    refuseStreams -= 1
                    send(Self.packet(0x08, msgid, h + [0x01, 0x80, 0x00] + Self.u16(423) + [0x00, 0x00]))
                    return
                }
                streamsServed += 1
                streamedPaths.append(path)
                send(Self.packet(0x08, msgid, h + [0x01, 0x80, 0x00] + Self.u16(200) + [0x00, 0x00]))
                let truncate = truncatedStreams > 0 ? truncateStreamBy : 0
                if truncate > 0 { truncatedStreams -= 1 }
                let bytes = dive.compressed.dropLast(truncate)
                let repeatChunk = streamsWithRepeatedChunk > 0
                if repeatChunk { streamsWithRepeatedChunk -= 1 }
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
                    send(chunkFrame(bytes[i..<j], offset: i - bytes.startIndex))
                    if repeatChunk && sent == 1 {
                        send(chunkFrame(bytes[i..<j], offset: i - bytes.startIndex))
                    }
                    sent += 1
                    i = j
                }
                if streamsWithoutEndMarker > 0 {
                    streamsWithoutEndMarker -= 1
                    return
                }
                // The end marker: a zero length chunk at the total size, sent twice.
                send(chunkFrame([], offset: bytes.count))
                send(chunkFrame([], offset: bytes.count))
            case 0x11: // unsubscribe a /Data handle; the resolution stays bound until released
                streamStops += 1
                send(Self.packet(0x09, msgid, Array(f[6...8]) + [0x01, 0x80, 0x00] + Self.u16(200) + [0x00, 0x00]))
            case 0x0D: // fetch on a handle
                let h = Array(f[6...8])
                guard let path = handles[h] else { return }
                let sublen = Int(f[2]) | Int(f[3]) << 8
                let param: (type: UInt8, value: UInt32)? = sublen >= 13
                    ? (f[13], UInt32(f[15]) | UInt32(f[16]) << 8 | UInt32(f[17]) << 16 | UInt32(f[18]) << 24)
                    : nil
                if path == "/Logbook/Entries" {
                    serveEntries(msgid: msgid, handle: h, param: param)
                } else if let content = pagedContent(for: path) {
                    let offset = Int(param?.value ?? 0)
                    if path.hasSuffix("/Summary") { summaryOffsets.append(UInt32(offset)) }
                    let end = min(offset + summaryPageSize, content.count)
                    let data = Array(content[min(offset, end)..<end])
                    let len = Self.u16(data.count)
                    let header: [UInt8] = [0x0D, 0x00, 0x02, len[0], len[1], 0x00, len[0], len[1], 0x00, len[0], len[1]]
                    send(dataFrame(msgid: msgid, handle: h, status: end < content.count ? 100 : 200, body: header + data))
                } else if path == "/Info" {
                    send(dataFrame(msgid: msgid, handle: h, status: 200, body: Array("Suunto\0Ocean\0Porvoo\0T\02604C3003306\02.51.28\0".utf8)))
                } else {
                    send(dataFrame(msgid: msgid, handle: h, status: 404, body: []))
                }
            default:
                break
            }
        }

        private func pagedContent(for path: String) -> [UInt8]? {
            if path.hasSuffix("/Summary") { return dive(for: path)?.summary }
            if path.hasSuffix("/Descriptors"), !descriptors.isEmpty { return descriptors }
            return nil
        }

        /// Static paths get a fresh F0 handle; the value resources their fixed ones from the Suunto
        /// app captures. A per-id path (/Logbook/byId/<id>/<res>) gets the resource's 00 slot, or its
        /// 10 slot while 00 is still bound, rebinding 10 when both are.
        private func resolve(_ path: String) -> [UInt8]? {
            if let value = Self.valueHandles[path] {
                guard valueSlots else { return [0xF0] + value }
                let slot0 = [0x00] + value, slot1 = [0x10] + value
                guard let h = [slot0, slot1].first(where: { !heldSlots.contains($0) }) else { return nil }
                heldSlots.insert(h)
                return h
            }
            let parts = path.split(separator: "/")
            guard parts.count == 4, parts[0] == "Logbook", parts[1] == "byId" else {
                defer { nextHandle &+= 1 }
                return [0xF0, 0x24, nextHandle]
            }
            let resource: UInt8 = switch parts[3] {
            case "Data": 0x0E
            case "Descriptors": 0x0F
            case "Summary": 0x12
            default: 0x10
            }
            let slot0: [UInt8] = [0x00, 0x24, resource]
            let h: [UInt8] = heldSlots.contains(slot0) ? [0x10, 0x24, resource] : slot0
            heldSlots.insert(h)
            return h
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
        var onDive: ((Int) -> Void)?
    }

    private func foreach(_ device: OpaquePointer, fingerprint: UInt32? = nil,
                         onDive: ((Int) -> Void)? = nil) -> (dc_status_t, [(fingerprint: UInt32, data: [UInt8])]) {
        if var fp = fingerprint?.littleEndian {
            withUnsafeBytes(of: &fp) { raw in
                _ = dc_device_set_fingerprint(device, raw.bindMemory(to: UInt8.self).baseAddress, 4)
            }
        }
        let downloads = Downloads()
        downloads.onDive = onDive
        let ptr = Unmanaged.passRetained(downloads).toOpaque()
        defer { Unmanaged<Downloads>.fromOpaque(ptr).release() }
        let status = dc_device_foreach(device, { data, size, fp, fpSize, userdata in
            let d = Unmanaged<Downloads>.fromOpaque(userdata!).takeUnretainedValue()
            var id: UInt32 = 0
            if let fp, fpSize == 4 { id = SuuntoNauticTransportTests.le32(Array(UnsafeBufferPointer(start: fp, count: 4)), 0) }
            d.dives.append((id, Array(UnsafeBufferPointer(start: data, count: Int(size)))))
            d.onDive?(d.dives.count)
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

    // MARK: - #72: any paged resource comes through whole

    func testFetchPagedReadsAWholeDescriptorsSchema() throws {
        let dive = FakeDive(id: 1_789_390_909, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.descriptors = (0..<43_140).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let device = try open(watch)

        let buffer = dc_buffer_new(0)!
        defer { dc_buffer_free(buffer) }
        XCTAssertEqual(suunto_nautic_device_fetch_paged(device, "/Logbook/byId/\(dive.id)/Descriptors", buffer), DC_STATUS_SUCCESS)
        let bytes = Array(UnsafeBufferPointer(start: dc_buffer_get_data(buffer), count: dc_buffer_get_size(buffer)))
        XCTAssertEqual(bytes, watch.descriptors)
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

    func testShortDownloadFailsAgainstListedSize() throws {
        let dive = FakeDive(id: 1_789_312_841, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_PROTOCOL)
        XCTAssertTrue(data.isEmpty, "a truncated dive is never handed out")
        XCTAssertEqual(watch.streamsServed, 2, "a mismatch is retried once")
    }

    func testStreamWithoutEndMarkerIsRetried() throws {
        let dive = FakeDive(id: 1_789_312_843, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithoutEndMarker = 1
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.decompressed + dive.summary)
        XCTAssertEqual(watch.streamsServed, 2, "the stream that stopped early is issued again")
    }

    func testStreamWithoutEndMarkerFailsOnceTheRetriesRunOut() throws {
        let dive = FakeDive(id: 1_789_312_844, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithoutEndMarker = Int.max
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertTrue(data.isEmpty, "a stream without its end marker is never handed out")
    }

    func testRepeatedChunkFailsTheStreamAndIsRetried() throws {
        let dive = FakeDive(id: 1_789_312_845, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithRepeatedChunk = 1
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.decompressed + dive.summary)
        XCTAssertEqual(watch.streamsServed, 2)
    }

    func testShortDownloadStopsForeach() throws {
        let dive = FakeDive(id: 1_789_312_842, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_PROTOCOL)
        XCTAssertEqual(dives.count, 0, "the short dive isn't delivered, so the fingerprint can't move past it")
    }

    // MARK: - foreach never moves the fingerprint past a dive it did not deliver

    func testLinkDropMidDataStopsForeachAtTheGapAndTheNextSyncFillsIt() throws {
        let synced = FakeDive(id: 1_789_700_000, profileBytes: 6000)
        let new = (1...3).map { FakeDive(id: 1_789_700_000 + UInt32($0) * 7200, profileBytes: 6000) }
        let watch = FakeWatch(dives: [synced] + new)
        var storedFingerprint = synced.id

        // Newest dive arrives, then the link dies two chunks into the next one's /Data.
        let first = try open(watch)
        let (status, delivered) = foreach(first, fingerprint: storedFingerprint) { n in
            if n == 1 { watch.mutate { $0.dropAfterChunks = 2 } }
        }
        XCTAssertEqual(status, DC_STATUS_IO, "a dive that failed to download is an error, not a skip")
        XCTAssertEqual(delivered.map(\.fingerprint), [new[2].id], "nothing older than the gap is delivered")
        XCTAssertEqual(delivered.first?.data, new[2].decompressed + new[2].summary)
        XCTAssertEqual(watch.drops, 1)

        let afterFirst = DiveLogRetriever.outcome(status: status, family: DC_FAMILY_SUUNTO_NAUTIC, fingerprintMatched: false,
                                                  hasNewDives: true, hadStoredFingerprint: true, emptyReadCount: 0)
        XCTAssertFalse(afterFirst.saveFingerprint)
        XCTAssertTrue(afterFirst.interrupted)
        if afterFirst.saveFingerprint, let newest = delivered.first { storedFingerprint = newest.fingerprint }
        XCTAssertEqual(storedFingerprint, synced.id, "the fingerprint stays behind the gap")
        close(device: first)

        watch.reconnect()
        let streamsBefore = watch.streamsServed
        let second = try open(watch)
        let (status2, delivered2) = foreach(second, fingerprint: storedFingerprint)
        XCTAssertEqual(status2, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered2.map(\.fingerprint), new.map(\.id).reversed(), "every new dive, stopping at the stored fingerprint")
        for (got, fake) in zip(delivered2, new.reversed()) {
            XCTAssertEqual(got.data, fake.decompressed + fake.summary)
        }
        XCTAssertEqual(watch.streamsServed - streamsBefore, 3, "the already-synced dive is not downloaded again")

        // A host keyed by fingerprint ends up with each dive exactly once.
        var host: [UInt32: [UInt8]] = [:]
        for dive in delivered + delivered2 { host[dive.fingerprint] = dive.data }
        XCTAssertEqual(Set(host.keys), Set(new.map(\.id)))
        XCTAssertEqual(delivered.count + delivered2.count - host.count, 1,
                       "only the dive the interrupted session already delivered comes again")

        let afterSecond = DiveLogRetriever.outcome(status: status2, family: DC_FAMILY_SUUNTO_NAUTIC, fingerprintMatched: false,
                                                   hasNewDives: true, hadStoredFingerprint: true, emptyReadCount: 0)
        XCTAssertTrue(afterSecond.saveFingerprint)
        XCTAssertEqual(delivered2.first?.fingerprint, new[2].id, "the fingerprint now advances to the newest dive")
    }

    func testEmptyReadOfAListedDiveIsAGapNotASkip() throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_800_000 + UInt32($0) * 7200, profileBytes: 4000) }
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        // The second dive's stream comes back empty although the listing says it has data.
        let (status, delivered) = foreach(device) { n in
            if n == 1 { watch.mutate { $0.truncateStreamBy = 1_000_000 } }
        }
        XCTAssertNotEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [dives[2].id])
    }

    func testEmptyLogbookEntryIsSkipped() throws {
        let older = FakeDive(id: 1_789_900_000, profileBytes: 4000)
        let empty = FakeDive(emptyID: 1_789_907_200)
        let newer = FakeDive(id: 1_789_914_400, profileBytes: 4000)
        let watch = FakeWatch(dives: [older, empty, newer])
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS, "an entry with nothing to download is not a gap")
        XCTAssertEqual(delivered.map(\.fingerprint), [newer.id, older.id])
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

    // MARK: - #29: a by-id download streams the dive it asked for

    func testByIdDownloadAfterAnotherOnTheSameLinkReturnsTheRequestedDive() throws {
        // urbamax's two dives: same /Summary size, so only the profile tells them apart.
        let a = FakeDive(id: 1_787_752_091, profileBytes: 5000, summaryBytes: 2338)
        let b = FakeDive(id: 1_788_616_918, profileBytes: 6000, summaryBytes: 2338)
        let watch = FakeWatch(dives: [a, b])
        let device = try open(watch)

        let (statusA, dataA) = download(device, id: a.id)
        XCTAssertEqual(statusA, DC_STATUS_SUCCESS)
        XCTAssertEqual(dataA, a.decompressed + a.summary)

        let (statusB, dataB) = download(device, id: b.id)
        XCTAssertEqual(statusB, DC_STATUS_SUCCESS)
        XCTAssertEqual(dataB, b.decompressed + b.summary, "dive B's request must not come back with dive A's profile")
        XCTAssertFalse(dataB.starts(with: a.decompressed))

        XCTAssertEqual(watch.streamedPaths, ["/Logbook/byId/\(a.id)/Data", "/Logbook/byId/\(b.id)/Data"])
        XCTAssertEqual(watch.heldIdHandles, [], "every per-id resolution is released")
    }

    func testForeachOfSeveralDivesStreamsEachOnce() throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_000_000 + UInt32($0) * 7_200, profileBytes: 3000 + $0 * 500) }
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        let (status, got) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        let newestFirst = dives.sorted { $0.id > $1.id }
        XCTAssertEqual(got.map(\.fingerprint), newestFirst.map(\.id))
        XCTAssertEqual(got.map(\.data), newestFirst.map { $0.decompressed + $0.summary })
        XCTAssertEqual(watch.streamedPaths, newestFirst.map { "/Logbook/byId/\($0.id)/Data" })
        XCTAssertEqual(watch.heldIdHandles, [])
    }

    // MARK: - Auto download: reconnect, resume, no duplicates

    /// The one device `CoreBluetoothManager` holds open, shared by every watch's connector.
    /// Closing takes a moment, like the real manager tearing a link down.
    private final class DeviceSlot {
        private let lock = NSLock()
        private var open = 0
        private var peak = 0
        var maxOpen: Int { lock.lock(); defer { lock.unlock() }; return peak }
        func opened() { lock.lock(); open += 1; peak = max(peak, open); lock.unlock() }
        func closed() { usleep(50_000); lock.lock(); open -= 1; lock.unlock() }
    }

    /// Opens a fresh driver session on the same fake watch for every connect, like a real reconnect.
    private final class FakeConnector: NauticSyncConnector {
        let watch: FakeWatch
        let openSession: () throws -> OpaquePointer
        let closeSession: (OpaquePointer) -> Void
        var slot: DeviceSlot?
        private let lock = NSLock()
        private var _connects = 0
        private var _presenceChecks = 0
        private var _cancels = 0
        private let cancelled = DispatchSemaphore(value: 0)
        /// Connect attempts that hang, like a pending CoreBluetooth connect to a sleeping watch, until cancelled.
        var hangingConnects = 0
        var connects: Int { lock.lock(); defer { lock.unlock() }; return _connects }
        var presenceChecks: Int { lock.lock(); defer { lock.unlock() }; return _presenceChecks }
        var cancels: Int { lock.lock(); defer { lock.unlock() }; return _cancels }

        init(watch: FakeWatch, open: @escaping () throws -> OpaquePointer, close: @escaping (OpaquePointer) -> Void) {
            self.watch = watch
            openSession = open
            closeSession = close
        }

        func waitUntilPresent(timeout: TimeInterval?) async throws -> Bool {
            countPresenceCheck()
            return true
        }

        private func countPresenceCheck() {
            lock.lock(); _presenceChecks += 1; lock.unlock()
        }

        func connect() throws -> NauticSyncLink {
            lock.lock()
            _connects += 1
            let hang = hangingConnects > 0
            if hang { hangingConnects -= 1 }
            lock.unlock()
            if hang {
                _ = cancelled.wait(timeout: .now() + 10)
                throw NauticAutoSyncError.connectFailed("could not open")
            }
            watch.reconnect()
            let device = try openSession()
            slot?.opened()
            return DCDeviceNauticLink(device: device) { [closeSession, slot] in
                closeSession($0)
                slot?.closed()
            }
        }

        func simulateDrop() {
            watch.dropLink()
        }

        func cancelConnect() {
            lock.lock(); _cancels += 1; lock.unlock()
            cancelled.signal()
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
                              lease: NauticLinkLease = NauticLinkLease(), slot: DeviceSlot? = nil,
                              configure: (inout NauticAutoSync.Configuration) -> Void = { _ in })
        -> (NauticAutoSync, FakeConnector, VirtualClock, EventLog) {
        let connector = FakeConnector(watch: watch, open: { [unowned self] in try self.open(watch) },
                                      close: { [unowned self] in self.close(device: $0) })
        connector.slot = slot
        var config = NauticAutoSync.Configuration()
        config.refreshInterval = nil
        configure(&config)
        let clock = VirtualClock()
        let sync = NauticAutoSync(deviceKey: "Suunto Nautic test", connector: connector, store: store,
                                  configuration: config, environment: clock.environment, linkLease: lease)
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

    private static func logs(_ events: [NauticAutoSync.Event]) -> [String] {
        events.compactMap { if case .log(let m) = $0 { return m } else { return nil } }
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

    func testAutoSyncRetriesADiveThatFailsItsSizeCheck() async throws {
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
        XCTAssertTrue(Self.logs(log.all).contains { $0.hasPrefix("Dive \(dive.id) failed (PROTOCOL); retrying") })
        XCTAssertEqual(connector.connects, 1, "retried on the same link")
    }

    func testAutoSyncGivesUpOnAPersistentlyShortDive() async throws {
        let dive = FakeDive(id: 1_789_200_000, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        let (sync, connector, _, log) = makeAutoSync(watch) { $0.retriesPerDive = 1 }

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        XCTAssertTrue(Self.dives(log.all).isEmpty, "a short dive is never delivered")
        XCTAssertTrue(log.all.contains(.diveFailed(id: dive.id, reason: "PROTOCOL")))
        XCTAssertEqual(Self.completedSyncs(log.all).first?.failed, [dive.id])
        XCTAssertEqual(connector.connects, 1)
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

    // MARK: - #29: sync trigger after an automatic reconnect

    func testTriggerSubscriptionSurvivesAReconnectAfterADropMidData() async throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_700_000 + UInt32($0) * 7200, profileBytes: 6000) }
        let watch = FakeWatch(dives: dives)
        watch.keepsSessionAcrossDrops = true
        // No retries: the reconnect's first subscription must be answered.
        let (sync, connector, _, log) = makeAutoSync(watch) { $0.triggerSubscribeRetries = 0 }

        var streams = 0
        sync.onDive = { _ in
            streams += 1
            if streams == 1 { watch.mutate { $0.dropAfterChunks = 2 } }
        }
        sync.start()
        await waitFor(log) { events in
            guard let done = events.firstIndex(where: { if case .syncCompleted = $0 { return true } else { return false } }) else { return false }
            return events[done...].contains(.state(.watching))
        }
        await stopAndWait(sync, log)

        let messages = Self.logs(log.all)
        XCTAssertEqual(connector.connects, 2)
        XCTAssertEqual(watch.drops, 1)
        XCTAssertEqual(watch.ignoredRequests, 0, "no request repeats one the watch saw before the drop")
        XCTAssertFalse(messages.contains { $0.hasPrefix("No sync trigger") }, "\(messages)")
        let reconnected = try XCTUnwrap(messages.lastIndex(of: "Connected"))
        XCTAssertTrue(messages[reconnected...].contains { $0.hasPrefix("Listening for sync triggers") })
        XCTAssertEqual(Self.dives(log.all).map(\.id), dives.map(\.id))
    }

    func testUnansweredTriggerSubscriptionIsRetried() async throws {
        let dive = FakeDive(id: 1_789_710_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [dive])
        watch.unansweredValueGets = 1
        let (sync, connector, clock, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { $0.contains(.state(.watching)) }
        XCTAssertNotNil(watch.subscribed["/Logbook/UnsynchronisedLogs"])
        XCTAssertNotNil(watch.subscribed["/Sync/BusyState"])
        await stopAndWait(sync, log)

        let messages = Self.logs(log.all)
        XCTAssertTrue(messages.contains { $0.hasPrefix("Sync trigger subscription failed (TIMEOUT); retrying (1 of 3)") }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.hasPrefix("No sync trigger") })
        XCTAssertTrue(clock.sleeps.contains(2))
        XCTAssertEqual(connector.connects, 1)
        XCTAssertEqual(watch.subscribed, [:], "stopping unsubscribes")
    }

    // Whether the watch really keeps a dropped link's bindings is unconfirmed
    // (libdc-swift#95). If it does, the reconnect's GET gets the other slot,
    // which works just as well; the driver never releases a slot it didn't
    // bind, since another app on the link may hold it.
    func testTriggerSubscriptionUsesTheSlotTheGetReturnsAfterADroppedLink() async throws {
        let first = FakeDive(id: 1_789_720_000, profileBytes: 600, summaryBytes: 100)
        let second = FakeDive(id: 1_789_730_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [first])
        watch.keepsSessionAcrossDrops = true
        watch.valueSlots = true
        let (sync, connector, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { $0.contains(.state(.watching)) }
        sync.simulateDrop()
        await waitFor(log) { events in Self.logs(events).filter { $0.hasPrefix("Listening for sync triggers") }.count >= 3 }
        await waitFor(log) { Self.completedSyncs($0).count == 2 }
        await waitFor(log) { $0.last == .state(.watching) }
        XCTAssertEqual(watch.heldValueSlots("/Logbook/UnsynchronisedLogs"), 2, "the dropped link's slot and ours")
        XCTAssertEqual(watch.heldValueSlots("/Sync/BusyState"), 2)

        watch.mutate {
            $0.dives.append(second)
            $0.unsyncedCount = 1
        }
        watch.notify("/Logbook/UnsynchronisedLogs")
        await waitFor(log) { Self.completedSyncs($0).count == 3 }
        await stopAndWait(sync, log)

        XCTAssertEqual(Self.dives(log.all).map(\.id), [first.id, second.id])
        XCTAssertEqual(connector.connects, 2)
        XCTAssertFalse(Self.logs(log.all).contains { $0.hasPrefix("No sync trigger") })
        XCTAssertEqual(watch.heldValueSlots("/Logbook/UnsynchronisedLogs"), 1, "unsubscribing releases our slot only")
    }

    // MARK: - #29/#45: a quick reconnect while the watch still flushes the old stream

    func testOpenWaitsForTheHandshakeReplyBehindAStaleStream() throws {
        let dives = (0..<2).map { FakeDive(id: 1_789_750_000 + UInt32($0) * 7200, profileBytes: 600, summaryBytes: 100) }
        let watch = FakeWatch(dives: dives)
        watch.staleFramesAfterDrop = 5
        watch.dropLink()
        watch.reconnect()

        let device = try open(watch)
        XCTAssertEqual(list(device).sorted(), dives.map(\.id))
        XCTAssertEqual(watch.ignoredRequests, 0, "nothing was sent before the Hello-Ack was read")
    }

    // MARK: - #29: an open the watch never answered is flagged

    func testHandshakeAcknowledgedOnANormalOpen() throws {
        let device = try open(FakeWatch(dives: []))
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(device), 1)
    }

    func testOpenWithoutAHelloAckIsFlagged() throws {
        let watch = FakeWatch(dives: [])
        watch.withholdHelloAck = true
        let device = try open(watch)
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(device), 0)
    }

    func testTriggerSubscriptionIsAnsweredFirstTimeAfterAQuickReconnect() async throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_760_000 + UInt32($0) * 7200, profileBytes: 6000) }
        let watch = FakeWatch(dives: dives)
        watch.staleFramesAfterDrop = 6
        // No retries: the reconnect's first subscription must be answered.
        let (sync, connector, _, log) = makeAutoSync(watch) { $0.triggerSubscribeRetries = 0 }

        var streams = 0
        sync.onDive = { _ in
            streams += 1
            if streams == 1 { watch.mutate { $0.dropAfterChunks = 2 } }
        }
        sync.start()
        await waitFor(log) { events in
            guard let done = events.firstIndex(where: { if case .syncCompleted = $0 { return true } else { return false } }) else { return false }
            return events[done...].contains(.state(.watching))
        }
        await stopAndWait(sync, log)

        let messages = Self.logs(log.all)
        XCTAssertEqual(connector.connects, 2)
        XCTAssertEqual(watch.drops, 1)
        XCTAssertEqual(watch.ignoredRequests, 0)
        XCTAssertFalse(messages.contains { $0.hasPrefix("No sync trigger") }, "\(messages)")
        let reconnected = try XCTUnwrap(messages.lastIndex(of: "Connected"))
        XCTAssertTrue(messages[reconnected...].contains { $0.hasPrefix("Listening for sync triggers") })
        XCTAssertEqual(Self.dives(log.all).map(\.id), dives.map(\.id))
    }

    // MARK: - #29: switching auto download from one watch to another

    func testSwitchingWatchesWaitsForThePreviousLinkToClose() async throws {
        // Build 17 crashed when one watch's Auto download was turned off and another's on
        // straight away: the new session opened the shared device while the old one was
        // still unsubscribing and closing it.
        let ocean = FakeWatch(dives: (0..<2).map { FakeDive(id: 1_789_810_000 + UInt32($0) * 7200, profileBytes: 600, summaryBytes: 100) })
        let nautic = FakeWatch(dives: (0..<2).map { FakeDive(id: 1_789_820_000 + UInt32($0) * 7200, profileBytes: 600, summaryBytes: 100) })
        let lease = NauticLinkLease(), slot = DeviceSlot()
        let (first, _, _, firstLog) = makeAutoSync(ocean, lease: lease, slot: slot)
        let (second, _, _, secondLog) = makeAutoSync(nautic, lease: lease, slot: slot)

        first.start()
        await waitFor(firstLog) { $0.contains(.state(.watching)) }
        first.stop()
        second.start()
        await waitFor(firstLog) { $0.contains(.state(.stopped)) }
        await waitFor(secondLog) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(second, secondLog)

        XCTAssertEqual(slot.maxOpen, 1, "one link open at a time")
        XCTAssertEqual(Self.dives(firstLog.all).map(\.id), ocean.dives.map(\.id))
        XCTAssertEqual(Self.dives(secondLog.all).map(\.id), nautic.dives.map(\.id))
        XCTAssertEqual(ocean.subscribed, [:], "the first watch's session unsubscribed before closing")
        XCTAssertFalse(lease.isHeld)
    }

    func testStoppingWhileWaitingForTheLeaseStopsCleanly() async throws {
        let lease = NauticLinkLease()
        try await lease.acquire()
        let watch = FakeWatch(dives: [FakeDive(id: 1_789_830_000, profileBytes: 600, summaryBytes: 100)])
        let (sync, connector, _, log) = makeAutoSync(watch, lease: lease)

        sync.start()
        await waitFor(log) { Self.logs($0).contains("Waiting for the other watch's session to close") }
        await stopAndWait(sync, log)
        XCTAssertEqual(connector.connects, 0)
        lease.release()
        XCTAssertFalse(lease.isHeld)
    }

    func testCancelStopsADownloadBetweenStreamFrames() throws {
        let dive = FakeDive(id: 1_789_840_000, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        let link = DCDeviceNauticLink(device: try open(watch)) { _ in }
        defer { link.setCancellation(nil) }
        link.setCancellation { watch.streamsServed > 0 }

        XCTAssertThrowsError(try link.download(dive.id)) { error in
            guard case SuuntoNauticExplorer.ExplorerError.requestFailed(let status) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(status, DC_STATUS_CANCELLED)
        }
        XCTAssertEqual(watch.streamStops, 1, "the stream is stopped, not left running")
    }

    // MARK: - #29: a connect attempt that never completes

    func testConnectTimeoutCancelsThePendingConnectAndFallsBackToScanning() async throws {
        let dive = FakeDive(id: 1_789_740_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [dive])
        let (sync, connector, clock, log) = makeAutoSync(watch) { $0.connectTimeout = 0.3 }
        connector.hangingConnects = 1

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        let events = log.all
        let messages = Self.logs(events)
        XCTAssertTrue(events.contains(.watchUnreachable(after: 0.3)))
        XCTAssertTrue(messages.contains("No connection after 0 s: \(NauticAutoSync.unreachableHint)"), "\(messages)")
        XCTAssertTrue(messages.contains("Connect failed: timed out"))
        XCTAssertEqual(connector.cancels, 1)
        XCTAssertEqual(connector.connects, 2)
        XCTAssertGreaterThanOrEqual(connector.presenceChecks, 2, "looks for the watch again before retrying")
        XCTAssertTrue(events.contains(.state(.reconnecting(attempt: 2, delay: 4))))
        XCTAssertTrue(clock.sleeps.contains(4))
        XCTAssertEqual(Self.dives(events).map(\.id), [dive.id])
    }
}
