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
        /// Whether the entry flags its size as present, as every real one does.
        var hasSize = true

        /// A dive the parser reads: a /Summary of `summaryBytes` (at least its dive header) and a profile of
        /// `profileBytes`: the timeline base (the dive starts at `id`, UTC), a 1 m depth sample, then chunks
        /// no parser decodes, a second apart. A profile of 8 bytes is the SBEM0103 header alone, an empty read.
        init(id: UInt32, profileBytes: Int, summaryBytes: Int = 2036) {
            self.id = id
            var profile = Array("SBEM0103".utf8)
            if profileBytes >= profile.count + 10 + 143 {
                profile += [0x01, 8] + Array(withUnsafeBytes(of: (UInt64(id) * 1000).littleEndian, Array.init).prefix(7)) + [0x00]
                var status = [UInt8](repeating: 0, count: 141)
                status.replaceSubrange(2..<6, with: withUnsafeBytes(of: Float(1).bitPattern.littleEndian, Array.init))
                profile += [0x16, 141] + status
            }
            let seed = Int(id % 251)
            var remaining = profileBytes - profile.count
            while remaining >= 4 {
                let length = remaining > 259 ? 254 : remaining > 256 ? 100 : remaining - 2
                profile += [0x40, UInt8(length), 0xE8, 0x03]
                let base = profile.count
                profile += (0..<(length - 2)).map { UInt8(truncatingIfNeeded: (base + $0) &* 31 &+ 7 &+ seed) }
                remaining = profileBytes - profile.count
            }
            decompressed = profile
            compressed = FakeDive.heatshrinkLiterals(profile)
            // The dive header (id 0x20, five gas records, air in the first) fills the /Summary.
            var header = [UInt8](repeating: 0, count: max(410, summaryBytes - 14))
            header[185 + 1] = 21
            summary = Array("SBEM0103".utf8) + [0x20, 0xFF] + withUnsafeBytes(of: UInt32(header.count).littleEndian, Array.init) + header
            listedSize = UInt32(compressed.count + summary.count)
        }

        /// The dive as the driver delivers it: SUMMARY_SIZE(4) SUMMARY PROFILE.
        var blob: [UInt8] {
            withUnsafeBytes(of: UInt32(summary.count).littleEndian, Array.init) + summary + decompressed
        }

        /// An entry with this /Summary and profile, listed with their true size.
        init(id: UInt32, summary: [UInt8], profile: [UInt8]) {
            self.id = id
            self.summary = summary
            decompressed = profile
            compressed = FakeDive.heatshrinkLiterals(profile)
            listedSize = UInt32(compressed.count + summary.count)
        }

        /// An activity the watch logs like a dive, a run by default. The /Summary is three Windows records and the
        /// Header (ids 0x26 and 0x24, as on an Ocean), whose DateTime is the start, 0.3 s after `id` at UTC+2, and
        /// whose ActivityType is `sport`. The profile is the timeline base, the activity record and heart rate samples,
        /// without the dive status records. `diveHeader` puts a dive header first, `header: false` leaves the Header
        /// out, `headerStart` gives the Header another start, and `diveStatus` adds a dive status record. `windowID`
        /// and `headerID` give the records the ids another set of descriptors could, and `headerFirst` puts the Header
        /// before the Windows.
        static func activity(id: UInt32, sport: UInt8 = 3, diveHeader: Bool = false, header: Bool = true,
                             headerStart: UInt32? = nil, diveStatus: Bool = false, profileBytes: Int = 3000,
                             windowID: UInt8 = 0x26, headerID: UInt8 = 0x24, headerFirst: Bool = false) -> FakeDive {
            func record(_ rid: UInt8, _ data: [UInt8]) -> [UInt8] {
                data.count < 0xFF ? [rid, UInt8(data.count)] + data
                    : [rid, 0xFF] + withUnsafeBytes(of: UInt32(data.count).littleEndian, Array.init) + data
            }
            // local64: the local time in ms in 7 bytes, then the UTC offset in quarter hours.
            func local64(_ seconds: UInt32) -> [UInt8] {
                let local = UInt64(seconds) * 1000 + 300 + 8 * 900_000
                return Array(withUnsafeBytes(of: local.littleEndian, Array.init).prefix(7)) + [8]
            }
            var summary = Array("SBEM0103".utf8)
            if diveHeader {
                var dive = [UInt8](repeating: 0, count: 410)
                dive[185 + 1] = 21
                summary += record(0x20, dive)
            }
            var window = [UInt8](repeating: 0, count: 239)
            window.replaceSubrange(0..<8, with: local64(id + 1800))
            window[8] = 1
            window[9] = sport
            let windows = (0..<3).flatMap { _ in record(windowID, window) }
            var headerRecord: [UInt8] = []
            if header {
                var h = [UInt8](repeating: 0, count: 370)
                h.replaceSubrange(0..<8, with: local64(id + 1800))
                h.replaceSubrange(8..<16, with: local64(headerStart ?? id))
                h[36] = sport
                headerRecord = record(headerID, h)
            }
            summary += headerFirst ? headerRecord + windows : windows + headerRecord
            var profile = Array("SBEM0103".utf8) + record(0x01, local64(id)) + record(0x08, [0, 0, sport] + Array(String(sport).utf8) + [0])
            if diveStatus {
                profile += record(0x16, [UInt8](repeating: 0, count: 141))
            }
            while profile.count + 5 <= profileBytes {
                profile += record(0x0F, [0xE8, 0x03, 120])
            }
            return FakeDive(id: id, summary: summary, profile: profile)
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
        /// Most bytes one read returns, as a BLE notification caps it (60 in #29's Nautic capture); nil for no cap.
        var maxReadSize: Int?
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
        /// Lose the link at the next /Summary GET, before it is answered.
        var dropAtSummaryGet = false
        /// /Summary GETs to leave unanswered on a live link.
        var unansweredSummaryGets = 0
        /// Lose the link right after the next /Data stream's end markers, before the UNSUBSCRIBE.
        var dropAfterEndMarker = false
        /// Lose the link at the Nth /Data page request from now, before it is answered.
        var dropAtDataPage: Int?
        /// Answer CANCELLED from the Nth /Data page request from now, as a close mid-download does.
        var cancelAtDataPage: Int?
        /// /Data page requests to leave unanswered on a live link.
        var unansweredDataPages = 0
        /// Answer every /Data page request with 400.
        var refuseDataPages = false
        /// Answer a /Data page request at or past the end of the /Data with 400.
        var refuseDataPagesAtEnd = false
        /// /Data streams to end without their end markers, as if both were lost.
        var streamsWithoutEndMarker = 0
        /// /Data streams in which the second chunk is sent twice.
        var streamsWithRepeatedChunk = 0
        /// /Data streams in which the second chunk never arrives. A FETCH on the /Data handle
        /// serves the resource in pages from any offset, as in the Ocean capture of #29.
        var streamsWithLostChunk = 0
        /// Dives /Logbook/Entries leaves out; their per-id resources are still served.
        var unlistedIDs: Set<UInt32> = []
        /// Dives whose /Data stream never ends with its end marker.
        var divesWithoutEndMarker: Set<UInt32> = []
        /// /Data streams during which a value the Suunto app subscribed to is pushed.
        var streamsWithForeignNotification = 0
        /// Paths the watch doesn't know: their GET answers FF FF FF with 404.
        var unknownPaths: Set<String> = []
        /// Reads, writes and sleeps answer CANCELLED, as the BLE iostream does once the device is closed mid-download.
        var ioCancelled = false
        /// Set `ioCancelled` once this many bytes of the next /Data stream have been read.
        var cancelIOAfterStreamBytes: Int?
        private var streamBytesRead: Int?
        /// /Info's product: "Ocean" on an Ocean, "Nautic" on a Nautic.
        var product = "Ocean"
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

        // The session: the watch answers a request only once a client on the link has said hello. A fresh link has
        // no session, so the driver's probe (a GET before any hello) goes unanswered and it says hello itself.

        /// Whether someone said hello on this link. A dropped link takes it, unless `keepsSessionAcrossDrops`.
        private var session = false
        /// The Suunto app has a session on the link, from before our open or from a hello of its own: requests are
        /// answered without a hello of ours. It outlasts our reconnects, which leave the app's link up.
        var appSession = false
        /// The Suunto app is busy with the watch: every read that finds nothing else gets one of its replies.
        var appBusy = false
        /// The Suunto app starts using the watch as our hello goes out (`appBusy` from then on).
        var appBusyAfterHello = false
        /// A fresh link answers the request that came before our hello late, just ahead of the hello reply.
        var answersProbeLate = false
        /// The next request with this opcode is answered only just before the reply to the request after it.
        var lateReplyTo: UInt8?
        enum AppEvent {
            /// The app's hello cuts off the chunk it arrives in (no closing flag), as in build 32's 14:14:04.
            case tornHello
            /// The app's hello reply arrives whole between two chunks, as at 14:15:29.
            case hello
            /// A reply to one of the app's requests arrives between two chunks.
            case reply
        }
        /// What the Suunto app does after this many chunks of the next /Data stream. Its hello ends the stream there.
        var appDuringStream: (afterChunks: Int, event: AppEvent)?
        /// Requests left unanswered because nobody had said hello on the link.
        private(set) var sessionlessRequests = 0
        private(set) var hellosReceived = 0
        /// The status each /Data UNSUBSCRIBE got: 404 once the app's hello has ended our session.
        private(set) var streamUnsubscribes: [Int] = []
        private var appTookSession = false
        private var appSeq = 900
        private var lateProbe: [UInt8]?
        private var lateReply: [UInt8] = []
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
        /// Offsets of the /Data pages fetched, and how many were fetched before the stream's UNSUBSCRIBE.
        private(set) var dataPageOffsets: [UInt32] = []
        private(set) var dataPagesWhileSubscribed = 0
        private(set) var entriesStartAfter: [UInt32?] = []
        private(set) var streamStops = 0
        private(set) var streamsServed = 0
        private(set) var releases = 0
        /// FETCHes on a per-id or value slot after its release; each is answered 404.
        private(set) var fetchesOnReleasedHandles = 0
        /// Paths of the /Data streams served, in order.
        private(set) var streamedPaths: [String] = []
        /// Called with the running count as each /Data stream starts, on the host's I/O thread.
        var onStreamStart: ((Int) -> Void)?

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
            lateProbe = nil
            lateReply.removeAll()
            // A new connection binds its handles in the app's session, so they are good in it.
            appTookSession = false
            if !(keepsSessionAcrossDrops && !linkUp) {
                heldSlots.removeAll()
                subscribed.removeAll()
                recentRequests.removeAll()
                session = false
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

        /// Replies to the Suunto app's requests, as they reach every client on the link.
        func pushAppReplies(_ n: Int = 1) {
            lock.lock(); defer { lock.unlock() }
            for _ in 0..<n { pushAppReplyLocked() }
        }

        /// The Suunto app's hello reply: the app now has the session, and ours is over.
        func pushAppHello() {
            lock.lock(); defer { lock.unlock() }
            appHelloLocked()
        }

        private func pushAppReplyLocked() {
            send(Self.packet(0x02, Self.u16(appSeq), [0xF0, 0x31, 0x1C, 0x01, 0x80, 0x00] + Self.u16(200)))
            appSeq += 1
        }

        private func appHelloLocked() {
            send(Self.packet(0x13, [0x00, 0x00], Self.helloReply))
            appSession = true
            appTookSession = true
        }

        /// The first half of that push, then nothing: a frame the link cut off.
        func notifyCutOff(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            guard let h = subscribed[path] else { return }
            let frame = Self.packet(0x01, [0x00, 0x00], h + [0x01, 0x80, 0x00] + value(for: path) + [0x00])
            rx.append(0x7E)
            for b in frame.prefix(frame.count / 2) {
                if b == 0x7E || b == 0x7D { rx.append(0x7D); rx.append(b ^ 0x20) } else { rx.append(b) }
            }
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

        enum IOCall: Equatable { case read, write, sleep }

        /// I/O calls answered CANCELLED, in order.
        private(set) var cancelledCalls: [IOCall] = []

        func answersCancelled(_ call: IOCall) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if ioCancelled { cancelledCalls.append(call) }
            return ioCancelled
        }

        // Watch -> host bytes; nil once the link is down and nothing is left in flight.
        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            if appBusy && linkUp && rx.count == rxIndex { pushAppReplyLocked() }
            let n = min(size, rx.count - rxIndex, maxReadSize ?? Int.max)
            guard n > 0 else { return linkUp ? 0 : nil }
            rx.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + rxIndex, byteCount: n) }
            rxIndex += n
            if let read = streamBytesRead, let limit = cancelIOAfterStreamBytes {
                streamBytesRead = read + n
                if read + n >= limit {
                    ioCancelled = true
                    cancelIOAfterStreamBytes = nil
                    streamBytesRead = nil
                }
            }
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

        /// A /Data notification: HANDLE(3) FLAGS(3) ?(4) OFFSET(4) LENGTH(2) ?(6) DATA 00.
        private func chunkFrame(_ payload: ArraySlice<UInt8>, offset: Int = 0) -> [UInt8] {
            Self.packet(0x01, [0x00, 0x00], [0xF0, 0x24, 0x0E, 0x01, 0x80, 0x00, 0x02, 0x24, 0x22, 0x25]
                + Self.u32(UInt32(offset)) + Self.u16(payload.count) + [0x00, 0x10, 0x0C, 0x00, 0x00, 0x00] + Array(payload) + [0x00])
        }

        /// /Info as the watch serves it: TYPE(2) SIZE(2) ?(2), then a struct led by the offsets of its eight strings.
        private var info: [UInt8] {
            let strings = ["Suunto", product, "Porvoo", "T", "2604C3003306", "01385D425091602000000100034252D12543", "2.51.28", "4252D1"]
            var offsets: [UInt8] = [], text: [UInt8] = []
            for string in strings {
                offsets += Self.u32(UInt32(strings.count * 4 + text.count))
                text += Array(string.utf8) + [0x00]
            }
            return [0x02, 0x2F, 0x19, 0x25, 0x01, 0x00] + offsets + text
        }

        private var sortedDives: [FakeDive] { dives.sorted { $0.id < $1.id } }

        private func handle(_ f: [UInt8]) {
            guard f.count >= 6, f[0] == 0xA5 else { return }
            if !lateReply.isEmpty {
                rx += lateReply
                lateReply.removeAll()
            }
            let mark = rx.count
            handleRequest(f)
            if let op = lateReplyTo, f[1] == op, rx.count > mark {
                lateReplyTo = nil
                lateReply = Array(rx[mark...])
                rx.removeSubrange(mark...)
            }
        }

        private func handleRequest(_ f: [UInt8]) {
            let msgid = Array(f[4...5])
            if f[1] == 0x12 {
                hellosReceived += 1
                session = true
                appTookSession = false
                if let probe = lateProbe {
                    lateProbe = nil
                    send(Self.packet(0x02, probe, [0xF0, 0x24, 0x00, 0x01, 0x80, 0x00] + Self.u16(200)))
                }
                if appBusyAfterHello {
                    appBusy = true
                    pushAppReplyLocked()
                }
            } else if !session && !appSession {
                sessionlessRequests += 1
                if answersProbeLate && lateProbe == nil { lateProbe = msgid }
                return
            }
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
                if unknownPaths.contains(path) {
                    send(Self.packet(0x02, msgid, [0xFF, 0xFF, 0xFF, 0x01, 0x80, 0x00] + Self.u16(404)))
                    return
                }
                if path.hasSuffix("/Summary") && unansweredSummaryGets > 0 {
                    unansweredSummaryGets -= 1
                    return
                }
                if path.hasSuffix("/Summary") && dropAtSummaryGet {
                    dropAtSummaryGet = false
                    linkUp = false
                    drops += 1
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
                if cancelIOAfterStreamBytes != nil { streamBytesRead = 0 }
                onStreamStart?(streamsServed)
                send(Self.packet(0x08, msgid, h + [0x01, 0x80, 0x00] + Self.u16(200) + [0x00, 0x00]))
                let truncate = truncatedStreams > 0 ? truncateStreamBy : 0
                if truncate > 0 { truncatedStreams -= 1 }
                let bytes = dive.compressed.dropLast(truncate)
                let repeatChunk = streamsWithRepeatedChunk > 0
                if repeatChunk { streamsWithRepeatedChunk -= 1 }
                let foreignNotification = streamsWithForeignNotification > 0
                if foreignNotification { streamsWithForeignNotification -= 1 }
                let lostChunk = streamsWithLostChunk > 0
                if lostChunk { streamsWithLostChunk -= 1 }
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
                    if let app = appDuringStream, sent == app.afterChunks {
                        appDuringStream = nil
                        switch app.event {
                        case .tornHello:
                            // The chunk loses its tail and closing flag; the hello's opening flag ends it.
                            rx.append(0x7E)
                            for b in chunkFrame(bytes[i..<j], offset: i - bytes.startIndex).dropLast(30) {
                                if b == 0x7E || b == 0x7D { rx.append(0x7D); rx.append(b ^ 0x20) } else { rx.append(b) }
                            }
                            appHelloLocked()
                            return
                        case .hello:
                            appHelloLocked()
                            return
                        case .reply:
                            pushAppReplyLocked()
                        }
                    }
                    if !(lostChunk && sent == 1) {
                        send(chunkFrame(bytes[i..<j], offset: i - bytes.startIndex))
                    }
                    if repeatChunk && sent == 1 {
                        send(chunkFrame(bytes[i..<j], offset: i - bytes.startIndex))
                    }
                    if foreignNotification && sent == 2 {
                        // /Sync/BusyState = 1, pushed on the Suunto app's own handle.
                        send(Self.packet(0x01, [0x00, 0x00], [0xF0, 0xBF, 0x06, 0x01, 0x80, 0x00, 0x03, 0x00, 0x01, 0x00]))
                    }
                    sent += 1
                    i = j
                }
                if let limit = dropAfterChunks, sent == limit {
                    // Every chunk went out; the link goes before the end marker.
                    dropAfterChunks = nil
                    linkUp = false
                    drops += 1
                    return
                }
                if divesWithoutEndMarker.contains(dive.id) { return }
                if streamsWithoutEndMarker > 0 {
                    streamsWithoutEndMarker -= 1
                    return
                }
                // The end marker: a zero length chunk at the total size, sent twice.
                send(chunkFrame([], offset: bytes.count))
                send(chunkFrame([], offset: bytes.count))
                if dropAfterEndMarker {
                    dropAfterEndMarker = false
                    linkUp = false
                    drops += 1
                }
            case 0x11: // unsubscribe a /Data handle; the resolution stays bound until released
                streamStops += 1
                let status = appTookSession ? 404 : 200
                streamUnsubscribes.append(status)
                send(Self.packet(0x09, msgid, Array(f[6...8]) + [0x01, 0x80, 0x00] + Self.u16(status) + [0x00, 0x00]))
            case 0x0D: // fetch on a handle
                let h = Array(f[6...8])
                guard let path = handles[h] else { return }
                // A slot handle is unknown to the watch once released; only F0 handles stay valid.
                if h[0] != 0xF0 && !heldSlots.contains(h) {
                    fetchesOnReleasedHandles += 1
                    send(dataFrame(msgid: msgid, handle: h, status: 404, body: []))
                    return
                }
                let sublen = Int(f[2]) | Int(f[3]) << 8
                let param: (type: UInt8, value: UInt32)? = sublen >= 13
                    ? (f[13], UInt32(f[15]) | UInt32(f[16]) << 8 | UInt32(f[17]) << 16 | UInt32(f[18]) << 24)
                    : nil
                if path == "/Logbook/Entries" {
                    serveEntries(msgid: msgid, handle: h, param: param)
                } else if let content = pagedContent(for: path) {
                    let offset = Int(param?.value ?? 0)
                    if path.hasSuffix("/Summary") { summaryOffsets.append(UInt32(offset)) }
                    if path.hasSuffix("/Data") {
                        dataPageOffsets.append(UInt32(offset))
                        if streamStops < streamsServed { dataPagesWhileSubscribed += 1 }
                        if let n = dropAtDataPage {
                            dropAtDataPage = n > 1 ? n - 1 : nil
                            if n <= 1 {
                                linkUp = false
                                drops += 1
                                return
                            }
                        }
                        if let n = cancelAtDataPage {
                            cancelAtDataPage = n > 1 ? n - 1 : nil
                            if n <= 1 {
                                ioCancelled = true
                                return
                            }
                        }
                        if unansweredDataPages > 0 {
                            unansweredDataPages -= 1
                            return
                        }
                        if refuseDataPages || (refuseDataPagesAtEnd && offset >= content.count) {
                            send(dataFrame(msgid: msgid, handle: h, status: 400, body: []))
                            return
                        }
                    }
                    let end = min(offset + summaryPageSize, content.count)
                    let data = Array(content[min(offset, end)..<end])
                    let len = Self.u16(data.count)
                    let header: [UInt8] = [0x0D, 0x00, 0x02, len[0], len[1], 0x00, len[0], len[1], 0x00, len[0], len[1]]
                    send(dataFrame(msgid: msgid, handle: h, status: end < content.count ? 100 : 200, body: header + data))
                } else if path == "/Info" {
                    send(dataFrame(msgid: msgid, handle: h, status: 200, body: info))
                } else {
                    send(dataFrame(msgid: msgid, handle: h, status: 404, body: []))
                }
            default:
                break
            }
        }

        private func pagedContent(for path: String) -> [UInt8]? {
            if path.hasSuffix("/Summary") { return dive(for: path)?.summary }
            if path.hasSuffix("/Data") { return dive(for: path)?.compressed }
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
            let all = sortedDives.filter { !unlistedIDs.contains($0.id) }
            let start = param.map { p in all.firstIndex { $0.id > p.value } ?? all.count } ?? 0
            let page = Array(all[start..<min(start + entriesPerPage, all.count)])
            let more = start + page.count < all.count
            // An empty page has a 14-byte header (these bytes are from a Nautic S with no dives).
            var body: [UInt8] = page.isEmpty
                ? [0x01, 0x24, 0x0A, 0x24, 0x00, 0x00, 0x00, 0x00, 0x08, 0x3C, 0x08, 0x00, 0x00, 0x00]
                : [0x01, 0x24] + Self.u32(2_100_000_000 - 1) + Self.u32(UInt32(page.count)) + Self.u32(12) + Self.u32(16)
            for d in page {
                body += Self.u32(d.id) + Self.u32(d.id + 1800) + Self.u32(d.hasSize ? 1 : 0) + Self.u32(0)
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
    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        sessionsLock.lock()
        let open = sessions
        sessions.removeAll()
        sessionsLock.unlock()
        open.forEach(Self.close)
        keepAlive.removeAll()
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

    /// `logging`: the context logs through the bridge at `LibDCLogging.level`, as a connect's does.
    private func open(_ watch: FakeWatch, resume: SuuntoNauticResume? = nil, logging: Bool = false) throws -> OpaquePointer {
        let (status, device) = try openStatus(watch, resume: resume, logging: logging)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        return try XCTUnwrap(device)
    }

    /// Collects a context's log lines.
    final class DriverLog {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func count(_ needle: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return lines.filter { $0.contains(needle) }.count
        }
        /// The open's wait for the link to go quiet, and the step-aside's.
        var openWaits: Int { count("waiting until it is done") }
        var stepAsideWaits: Int { count("Waiting for the other app to finish") }
    }

    /// The custom iostream every open here runs on: the fake watch behind it.
    private func stream(_ watch: FakeWatch, context: OpaquePointer?) throws -> OpaquePointer {
        var cbs = dc_custom_cbs_t()
        cbs.set_timeout = { _, _ in DC_STATUS_SUCCESS }
        cbs.read = { userdata, data, size, actual in
            let watch = SuuntoNauticTransportTests.watch(userdata)
            if watch.answersCancelled(.read) {
                actual?.pointee = 0
                return DC_STATUS_CANCELLED
            }
            guard let n = watch.hostRead(into: data!, size: size) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            let watch = SuuntoNauticTransportTests.watch(userdata)
            if watch.answersCancelled(.write) {
                actual?.pointee = 0
                return DC_STATUS_CANCELLED
            }
            guard watch.hostWrote(UnsafeRawBufferPointer(start: data, count: size)) else {
                actual?.pointee = 0
                return DC_STATUS_IO
            }
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        cbs.purge = { _, _ in DC_STATUS_SUCCESS }
        cbs.sleep = { userdata, _ in
            SuuntoNauticTransportTests.watch(userdata).answersCancelled(.sleep) ? DC_STATUS_CANCELLED : DC_STATUS_SUCCESS
        }
        cbs.close = { _ in DC_STATUS_SUCCESS }

        var iostream: OpaquePointer?
        let userdata = Unmanaged.passUnretained(watch).toOpaque()
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_BLE, &cbs, userdata), DC_STATUS_SUCCESS)
        return try XCTUnwrap(iostream)
    }

    /// The open's status, and the device when it opened. `log` collects the driver's lines at every level.
    private func openStatus(_ watch: FakeWatch, resume: SuuntoNauticResume? = nil, logging: Bool = false,
                            log: DriverLog? = nil) throws -> (dc_status_t, OpaquePointer?) {
        let s = Session(watch: watch)
        sessionsLock.lock()
        sessions.append(s)
        sessionsLock.unlock()
        XCTAssertEqual(dc_context_new(&s.context), DC_STATUS_SUCCESS)
        if logging, let context = s.context { LibDCLogging.configure(context) }
        if let log {
            dc_context_set_loglevel(s.context, DC_LOGLEVEL_ALL)
            dc_context_set_logfunc(s.context, { _, _, _, _, _, message, userdata in
                guard let message, let userdata else { return }
                Unmanaged<DriverLog>.fromOpaque(userdata).takeUnretainedValue().append(String(cString: message))
            }, Unmanaged.passUnretained(log).toOpaque())
            keepAlive.append(log)
        }
        s.iostream = try stream(watch, context: s.context)

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

        let status = dc_device_open(&s.device, s.context, desc, s.iostream)
        if let resume, let device = s.device { XCTAssertTrue(resume.attach(device, watch: Self.watchName)) }
        return (status, s.device)
    }

    private static let watchName = "Suunto Nautic test"

    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * UInt32(i)) }
        return v
    }

    private final class Downloads {
        var dives: [(fingerprint: UInt32, data: [UInt8])] = []
        var onDive: ((Int) -> Void)?
        var stopAtDive: Int?
    }

    /// `stopAtDive`: the callback declines that dive (returns 0), as DiveLogRetriever does on a host stop.
    private func foreach(_ device: OpaquePointer, fingerprint: UInt32? = nil, stopAtDive: Int? = nil,
                         onDive: ((Int) -> Void)? = nil) -> (dc_status_t, [(fingerprint: UInt32, data: [UInt8])]) {
        if var fp = fingerprint?.littleEndian {
            withUnsafeBytes(of: &fp) { raw in
                _ = dc_device_set_fingerprint(device, raw.bindMemory(to: UInt8.self).baseAddress, 4)
            }
        }
        let downloads = Downloads()
        downloads.onDive = onDive
        downloads.stopAtDive = stopAtDive
        let ptr = Unmanaged.passRetained(downloads).toOpaque()
        defer { Unmanaged<Downloads>.fromOpaque(ptr).release() }
        let status = dc_device_foreach(device, { data, size, fp, fpSize, userdata in
            let d = Unmanaged<Downloads>.fromOpaque(userdata!).takeUnretainedValue()
            if d.stopAtDive == d.dives.count + 1 { return 0 }
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
        XCTAssertEqual(dives.first?.data, dive.blob)
        XCTAssertEqual(watch.streamStops, 1)
    }

    // MARK: - #57: /Summary page header and CRC are stripped, offsets count data

    func testSummaryPagingKeepsOnlyDataBytes() throws {
        let dive = FakeDive(id: 1_789_390_908, profileBytes: 4000, summaryBytes: 2036)
        let watch = FakeWatch(dives: [dive])
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.first?.data, dive.blob)
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
        XCTAssertEqual(dives.first?.data, dive.blob)
    }

    func testRefusedStreamFailsTheDive() throws {
        let dive = FakeDive(id: 1_789_487_763, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        // The driver ends a left-over stream (423) and subscribes again, twice; a third 423 fails the dive.
        watch.refuseStreams = 3
        let device = try open(watch)

        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_PROTOCOL, "the driver doesn't keep issuing a refused stream")
        XCTAssertTrue(dives.isEmpty)
        XCTAssertEqual(watch.streamsServed, 0)
        XCTAssertEqual(watch.streamUnsubscribes, [200, 200], "an UNSUBSCRIBE after each of the first two refusals")
        XCTAssertEqual(watch.summaryOffsets.filter { $0 == 0 }.count, 1, "the /Summary comes before the stream")
        XCTAssertEqual(watch.heldIdHandles, [], "the refused stream's handle is released")

        // The retry is the application's, and works on the same link.
        let (retryStatus, retried) = foreach(device)
        XCTAssertEqual(retryStatus, DC_STATUS_SUCCESS)
        XCTAssertEqual(retried.first?.data, dive.blob)
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

    // MARK: - libdc-swift#29: the activities that aren't dives

    private final class ProgressEvents {
        var last = dc_event_progress_t()
        var count = 0
    }

    /// Records the progress events of `device` into `events`.
    private func trackProgress(_ device: OpaquePointer, _ events: ProgressEvents) {
        let status = dc_device_set_events(device, DC_EVENT_PROGRESS.rawValue, { _, event, data, userdata in
            guard event == DC_EVENT_PROGRESS, let data, let userdata else { return }
            let events = Unmanaged<ProgressEvents>.fromOpaque(userdata).takeUnretainedValue()
            events.last = data.assumingMemoryBound(to: dc_event_progress_t.self).pointee
            events.count += 1
        }, Unmanaged.passUnretained(events).toOpaque())
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
    }

    private func nonDives(_ device: OpaquePointer) -> UInt32 {
        var count: UInt32 = .max
        XCTAssertEqual(suunto_nautic_device_get_nondives(device, &count), DC_STATUS_SUCCESS)
        return count
    }

    private func dataGets(_ watch: FakeWatch, _ id: UInt32) -> Int {
        watch.getPaths.filter { $0 == "/Logbook/byId/\(id)/Data" }.count
    }

    func testARunBetweenDivesIsSkippedBeforeItsData() throws {
        let older = FakeDive(id: 1_789_000_000, profileBytes: 600, summaryBytes: 100)
        let run = FakeDive.activity(id: 1_789_010_000)
        let newer = FakeDive(id: 1_789_020_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [older, run, newer])
        let device = try open(watch)
        let progress = ProgressEvents()
        trackProgress(device, progress)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [newer.id, older.id], "the walk goes on past the run")
        XCTAssertEqual(delivered.map(\.data), [newer.blob, older.blob])
        XCTAssertTrue(watch.getPaths.contains("/Logbook/byId/\(run.id)/Summary"))
        XCTAssertEqual(dataGets(watch, run.id), 0, "the run's /Data is never requested")
        XCTAssertFalse(watch.streamedPaths.contains("/Logbook/byId/\(run.id)/Data"))
        XCTAssertEqual(watch.streamsServed, 2)
        XCTAssertEqual(nonDives(device), 1)
        XCTAssertEqual(progress.last.current, progress.last.maximum, "the run's step is counted too")
        XCTAssertEqual(progress.last.maximum, 4 * 1000)
        XCTAssertEqual(watch.heldIdHandles, [])
    }

    func testANewestRunNeverBecomesTheFingerprintAndTheNextSyncReadsOnlyItsSummary() throws {
        let dive = FakeDive(id: 1_789_000_000, profileBytes: 600, summaryBytes: 100)
        let runs = [FakeDive.activity(id: 1_789_010_000), FakeDive.activity(id: 1_789_020_000, sport: 100)]
        let watch = FakeWatch(dives: [dive] + runs)
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [dive.id], "the first fingerprint delivered, the one a host stores, is the dive's")
        XCTAssertEqual(nonDives(device), 2)
        close(device: device)

        watch.reconnect()
        let next = try open(watch)
        let (status2, delivered2) = foreach(next, fingerprint: dive.id)
        XCTAssertEqual(status2, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered2.map(\.fingerprint), [], "nothing new, and the walk ends at the stored dive")
        XCTAssertEqual(watch.getPaths.filter { $0.hasSuffix("/Summary") }.count, 3 + 2, "the second sync reads only the newer runs' /Summary")
        XCTAssertEqual(watch.getPaths.filter { $0 == "/Logbook/byId/\(dive.id)/Summary" }.count, 1, "the stored dive isn't read again")
        XCTAssertEqual(runs.map { dataGets(watch, $0.id) }, [0, 0])
        XCTAssertEqual(nonDives(next), 2)
    }

    func testAFingerprintOnARunStillEndsTheWalk() throws {
        let older = FakeDive(id: 1_789_000_000, profileBytes: 600, summaryBytes: 100)
        let run = FakeDive.activity(id: 1_789_010_000)
        let newer = FakeDive(id: 1_789_020_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [older, run, newer])
        let device = try open(watch)

        // A build that delivered runs may have stored one as the fingerprint.
        let (status, delivered) = foreach(device, fingerprint: run.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [newer.id])
        XCTAssertFalse(watch.getPaths.contains { $0.contains("/\(run.id)/") || $0.contains("/\(older.id)/") })
        XCTAssertEqual(nonDives(device), 0)
    }

    func testAnEntryThatCantBeToldFromADiveIsDownloaded() throws {
        let entries = [
            FakeDive.activity(id: 1_789_000_000, sport: 51),               // a diving sport
            FakeDive.activity(id: 1_789_010_000, sport: 61),
            FakeDive.activity(id: 1_789_020_000, sport: 62),
            FakeDive.activity(id: 1_789_030_000, diveHeader: true),        // a dive header, whatever the sport
            FakeDive.activity(id: 1_789_040_000, header: false),           // no Header to read the sport from
            FakeDive.activity(id: 1_789_050_000, headerStart: 1_789_049_990), // a Header that doesn't start with the entry
        ]
        let watch = FakeWatch(dives: entries)
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), Array(entries.map(\.id).reversed()), "all of them, left to the parser")
        XCTAssertEqual(delivered.map(\.data), entries.reversed().map(\.blob))
        XCTAssertEqual(entries.map { dataGets(watch, $0.id) }, Array(repeating: 1, count: entries.count))
        XCTAssertEqual(nonDives(device), 0)
    }

    func testARunWhoseRecordsGetTheDiveHeaderIdsIsStillSkipped() throws {
        // The descriptors of a run, without the dive records, could number its records from 0x20.
        let runs = [
            FakeDive.activity(id: 1_789_000_000, headerID: 0x20, headerFirst: true), // the Header first, as 0x20
            FakeDive.activity(id: 1_789_010_000, windowID: 0x21, headerID: 0x20),    // Windows 0x21, Header 0x20
            FakeDive.activity(id: 1_789_020_000, windowID: 0x20, headerID: 0x21),    // Windows 0x20, Header 0x21
            FakeDive.activity(id: 1_789_030_000, windowID: 0x21, headerID: 0x22),    // Windows 0x21 first
        ]
        let dive = FakeDive(id: 1_789_040_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: runs + [dive])
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [dive.id])
        XCTAssertEqual(runs.map { dataGets(watch, $0.id) }, [0, 0, 0, 0], "a record too small for a dive header isn't one")
        XCTAssertEqual(nonDives(device), 4)
    }

    func testTheSkipCountIsTheLastForeachsOnTheSameDevice() throws {
        let older = FakeDive(id: 1_789_000_000, profileBytes: 600, summaryBytes: 100)
        let runs = [FakeDive.activity(id: 1_789_010_000), FakeDive.activity(id: 1_789_020_000, sport: 100)]
        let watch = FakeWatch(dives: [older] + runs)
        let device = try open(watch)

        XCTAssertEqual(foreach(device).0, DC_STATUS_SUCCESS)
        XCTAssertEqual(nonDives(device), 2)

        // The Explorer downloads again on the same connection.
        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [older.id])
        XCTAssertEqual(nonDives(device), 2, "this foreach's skips, not the connection's")

        let (status3, delivered3) = foreach(device, fingerprint: runs[0].id)
        XCTAssertEqual(status3, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered3.count, 0)
        XCTAssertEqual(nonDives(device), 1, "only the newer run was walked")
    }

    func testTheHeaderOfARealOceanSummaryIsRead() throws {
        // The /Summary of the synthetic run, whose Header is Ocean dive 1787699873's with the sport set to 3.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_ocean_nondive_synthetic", withExtension: "bin"))
        let run = [UInt8](try Data(contentsOf: url))
        let size = Int(Self.le32(run, 0))
        let ocean = FakeDive(id: 1_787_699_873, summary: Array(run[4..<(4 + size)]), profile: Array(run[(4 + size)...]))
        // A real dive's /Summary, which starts with the Nautic's dive header (0x21).
        let nautic = [UInt8](try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_1787752091", withExtension: "bin"))))
        let nauticSize = Int(Self.le32(nautic, 0))
        let dive = FakeDive(id: 1_787_752_091, summary: Array(nautic[4..<(4 + nauticSize)]), profile: Array(nautic[(4 + nauticSize)...]))
        let watch = FakeWatch(dives: [ocean, dive])
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [dive.id])
        XCTAssertEqual(delivered.first?.data, dive.blob)
        XCTAssertEqual(dataGets(watch, ocean.id), 0)
        XCTAssertEqual(nonDives(device), 1)
    }

    func testTheByIdDownloadFetchesARunWhole() throws {
        let run = FakeDive.activity(id: 1_789_010_000)
        let watch = FakeWatch(dives: [run])
        let device = try open(watch)

        let (status, data) = download(device, id: run.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, run.blob, "the extension API fetches any entry; the parser judges it")
    }

    func testBytesKeptForARunAreForgottenWhenItIsSkipped() throws {
        let run = FakeDive.activity(id: 1_789_010_000, profileBytes: 60_000)
        let watch = FakeWatch(dives: [run])
        watch.keepsSessionAcrossDrops = true
        watch.dropAfterChunks = 10
        let resume = SuuntoNauticResume()

        // A by-id download keeps the bytes of a run, as an older build's foreach did.
        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: run.id).0, DC_STATUS_IO)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: run.id, on: first), 10 * watch.mdsPayloadSize)
        close(device: first)

        watch.reconnect()
        let second = try open(watch, resume: resume)
        let (status, delivered) = foreach(second)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.count, 0)
        XCTAssertEqual(dataGets(watch, run.id), 1, "only the by-id download asked for the /Data")
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: run.id, on: second))
    }

    func testALostLinkAtARunsSummaryStopsTheWalkLikeADive() throws {
        let older = FakeDive(id: 1_789_000_000, profileBytes: 600, summaryBytes: 100)
        let run = FakeDive.activity(id: 1_789_010_000)
        let watch = FakeWatch(dives: [older, run])
        watch.dropAtSummaryGet = true
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertNotEqual(status, DC_STATUS_SUCCESS, "it isn't known to be a run before its /Summary arrives")
        XCTAssertEqual(delivered.count, 0, "nothing older is delivered past it")
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
        XCTAssertEqual(watch.streamsServed, 1, "a mismatch isn't downloaded again")
        XCTAssertEqual(watch.summaryOffsets.filter { $0 == 0 }.count, 1)
    }

    func testStreamWithoutEndMarkerFailsTheDive() throws {
        let dive = FakeDive(id: 1_789_312_843, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithoutEndMarker = 1
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertTrue(data.isEmpty, "a stream without its end marker is never handed out")
        XCTAssertEqual(watch.streamsServed, 1, "the stream that stopped early isn't issued again")

        // The application's retry on the same link gets the whole dive.
        let (retryStatus, retried) = download(device, id: dive.id)
        XCTAssertEqual(retryStatus, DC_STATUS_SUCCESS)
        XCTAssertEqual(retried, dive.blob)
        XCTAssertEqual(watch.streamsServed, 2)
    }

    func testStreamThatNeverEndsIsIssuedOnceAndUnsubscribed() throws {
        let dive = FakeDive(id: 1_789_312_844, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithoutEndMarker = Int.max
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertTrue(data.isEmpty, "a stream without its end marker is never handed out")
        XCTAssertEqual(watch.streamsServed, 1, "one stream, not retried by the driver")
        XCTAssertEqual(watch.streamStops, 1, "and it was unsubscribed")
        XCTAssertEqual(watch.summaryOffsets.filter { $0 == 0 }.count, 1, "the /Summary comes before the stream")
        XCTAssertEqual(watch.heldIdHandles, [], "and released")
    }

    func testRepeatedChunkFailsTheDive() throws {
        let dive = FakeDive(id: 1_789_312_845, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithRepeatedChunk = 1
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_PROTOCOL)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(watch.streamsServed, 1)
        XCTAssertEqual(watch.streamStops, 1, "the failed stream is still unsubscribed")
        XCTAssertEqual(watch.summaryOffsets.filter { $0 == 0 }.count, 1, "the /Summary comes before the stream")
        XCTAssertTrue(watch.dataPageOffsets.isEmpty, "a chunk at an earlier offset isn't read again in pages")

        let (retryStatus, retried) = download(device, id: dive.id)
        XCTAssertEqual(retryStatus, DC_STATUS_SUCCESS)
        XCTAssertEqual(retried, dive.blob)
        XCTAssertEqual(watch.streamsServed, 2)
    }

    func testLostChunkIsReadInPagesFromTheFirstMissingByte() throws {
        let dive = FakeDive(id: 1_789_312_847, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithLostChunk = 1
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob, "the same dive as an uninterrupted stream")
        XCTAssertEqual(watch.streamsServed, 1, "recovered on the same stream, not by downloading again")
        XCTAssertEqual(watch.streamStops, 1)
        let first = watch.mdsPayloadSize, page = watch.summaryPageSize
        XCTAssertEqual(watch.dataPageOffsets, stride(from: first, to: dive.compressed.count, by: page).map(UInt32.init))
        XCTAssertEqual(watch.dataPagesWhileSubscribed, 0, "the pages are read after the UNSUBSCRIBE")
        XCTAssertEqual(watch.getPaths.filter { $0 == "/Logbook/byId/\(dive.id)/Data" }.count, 1,
                       "the pages are read on the stream's own handle, not a second GET")
        XCTAssertEqual(watch.fetchesOnReleasedHandles, 0, "and before its RELEASE")
        XCTAssertEqual(watch.heldIdHandles, [])
    }

    // MARK: - A dive the link dropped in carries on from the bytes received (SuuntoNauticResume)

    func testDropMidDataKeepsTheBytesAndTheNextConnectionReadsOnlyTheRest() throws {
        let dive = FakeDive(id: 1_789_390_906, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        watch.keepsSessionAcrossDrops = true
        watch.dropAfterChunks = 100
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        let (status, data) = download(first, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_IO)
        XCTAssertTrue(data.isEmpty, "nothing is delivered from a dropped download")
        let kept = 100 * watch.mdsPayloadSize
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: first), kept)
        close(device: first)

        watch.reconnect()
        let second = try open(watch, resume: resume)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: second), kept, "the next connection's device has the kept bytes")
        let (status2, data2) = download(second, id: dive.id)
        XCTAssertEqual(status2, DC_STATUS_SUCCESS)
        XCTAssertEqual(data2, dive.blob, "byte for byte the dive an uninterrupted stream gives")
        XCTAssertEqual(watch.streamsServed, 1, "the rest isn't streamed again")
        XCTAssertEqual(watch.dataPageOffsets, stride(from: kept, to: dive.compressed.count, by: watch.summaryPageSize).map(UInt32.init),
                       "pages from the first missing byte to the end")
        XCTAssertEqual(watch.getPaths.filter { $0 == "/Logbook/byId/\(dive.id)/Data" }.count, 2, "one GET of the /Data per connection")
        XCTAssertEqual(watch.fetchesOnReleasedHandles, 0)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: second), "a dive that downloaded forgets what was kept")
    }

    func testDropAtTheSummaryComesBeforeTheProfileSoTheNextConnectionDownloadsItWhole() throws {
        let dive = FakeDive(id: 1_789_390_907, profileBytes: 8000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAtSummaryGet = true
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: first), "no /Data had arrived yet")
        XCTAssertEqual(watch.streamsServed, 0)
        close(device: first)

        watch.reconnect()
        let second = try open(watch, resume: resume)
        let (status, data) = download(second, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamsServed, 1)
        XCTAssertTrue(watch.dataPageOffsets.isEmpty)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: second))
    }

    func testACancelledDownloadKeepsTheBytesForTheNextConnection() throws {
        let dive = FakeDive(id: 1_789_390_908, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        watch.cancelIOAfterStreamBytes = 5_000
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_CANCELLED)
        let kept = try XCTUnwrap(SuuntoNauticResume.resumableBytes(of: dive.id, on: first))
        XCTAssertGreaterThan(kept, 0)
        XCTAssertEqual(kept % watch.mdsPayloadSize, 0, "only whole chunks are kept")
        close(device: first)

        watch.mutate { $0.ioCancelled = false }
        watch.reconnect()
        let second = try open(watch, resume: resume)
        let (status, data) = download(second, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.dataPageOffsets.first, UInt32(kept))
        XCTAssertEqual(watch.streamsServed, 1)
    }

    func testAFailureThatIsNotTheLinksForgetsTheKeptBytes() throws {
        let dive = FakeDive(id: 1_789_390_909, profileBytes: 30_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        XCTAssertNotNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: first))
        close(device: first)

        // The watch no longer serves the dive's /Data: nothing says the kept bytes are still good.
        watch.reconnect()
        watch.unknownPaths = ["/Logbook/byId/\(dive.id)/Data"]
        let second = try open(watch, resume: resume)
        XCTAssertEqual(download(second, id: dive.id).0, DC_STATUS_PROTOCOL)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: second))
        close(device: second)

        watch.reconnect()
        watch.unknownPaths = []
        let third = try open(watch, resume: resume)
        let (status, data) = download(third, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamsServed, 2, "streamed from the start again")
        XCTAssertTrue(watch.dataPageOffsets.isEmpty)
    }

    func testKeptBytesOfADiveListedWithAnotherSizeAreNotUsed() throws {
        let dive = FakeDive(id: 1_789_390_910, profileBytes: 30_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        close(device: first)

        // Same id, other content: the kept bytes belong to what was listed before.
        let other = FakeDive(id: dive.id, profileBytes: 31_000)
        watch.reconnect()
        watch.mutate { $0.dives = [other] }
        let second = try open(watch, resume: resume)
        let (status, data) = download(second, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, other.blob)
        XCTAssertTrue(watch.dataPageOffsets.isEmpty, "streamed from the start")
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: second))
    }

    func testEachDiveKeepsItsOwnBytesAndAnotherDivesDownloadLeavesThemAlone() throws {
        let a = FakeDive(id: 1_789_500_000, profileBytes: 20_000)
        let b = FakeDive(id: 1_789_507_200, profileBytes: 20_000)
        let watch = FakeWatch(dives: [a, b])
        watch.dropAfterChunks = 10
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: a.id).0, DC_STATUS_IO)
        close(device: first)

        watch.reconnect()
        let second = try open(watch, resume: resume)
        XCTAssertEqual(download(second, id: b.id).0, DC_STATUS_SUCCESS)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: a.id, on: second), 10 * watch.mdsPayloadSize,
                       "dive B's download leaves dive A's bytes alone")
        watch.mutate { $0.dropAfterChunks = 15 }
        XCTAssertEqual(download(second, id: b.id).0, DC_STATUS_IO)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: a.id, on: second), 10 * watch.mdsPayloadSize, "dive B's drop doesn't evict dive A")
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: b.id, on: second), 15 * watch.mdsPayloadSize)
        close(device: second)

        watch.reconnect()
        let third = try open(watch, resume: resume)
        for dive in [a, b] {
            let (status, data) = download(third, id: dive.id)
            XCTAssertEqual(status, DC_STATUS_SUCCESS)
            XCTAssertEqual(data, dive.blob)
            XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: third))
        }
        XCTAssertEqual(watch.streamedPaths, ["/Logbook/byId/\(a.id)/Data", "/Logbook/byId/\(b.id)/Data", "/Logbook/byId/\(b.id)/Data"],
                       "both carry on in pages")
    }

    func testUpToFourDivesAreKeptAndTheOldestGoesFirst() throws {
        let dives = (0..<5).map { FakeDive(id: 1_789_600_000 + UInt32($0) * 7200, profileBytes: 8000) }
        let watch = FakeWatch(dives: dives)
        let resume = SuuntoNauticResume()

        for (n, dive) in dives.enumerated() {
            watch.reconnect()
            let device = try open(watch, resume: resume)
            watch.mutate { $0.dropAfterChunks = n + 1 }
            XCTAssertEqual(download(device, id: dive.id).0, DC_STATUS_IO)
            XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: device), (n + 1) * watch.mdsPayloadSize)
            close(device: device)
        }
        watch.reconnect()
        let last = try open(watch, resume: resume)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dives[0].id, on: last), "the oldest went to make room")
        for (n, dive) in dives.enumerated().dropFirst() {
            XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: last), (n + 1) * watch.mdsPayloadSize)
        }
    }

    func testASecondDropWhileReadingThePagesKeepsTheLongerPrefix() throws {
        let dive = FakeDive(id: 1_789_390_912, profileBytes: 30_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        close(device: first)

        // The link drops again at the fifth page: the four pages before it are kept too.
        watch.reconnect()
        watch.dropAtDataPage = 5
        let second = try open(watch, resume: resume)
        XCTAssertEqual(download(second, id: dive.id).0, DC_STATUS_IO)
        let kept = 20 * watch.mdsPayloadSize + 4 * watch.summaryPageSize
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: second), kept)
        close(device: second)

        watch.reconnect()
        let pagesBefore = watch.dataPageOffsets.count
        let third = try open(watch, resume: resume)
        let (status, data) = download(third, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.dataPageOffsets[pagesBefore], UInt32(kept), "the third connection starts where the second stopped")
        XCTAssertEqual(watch.streamsServed, 1)
    }

    func testACancelWhileReadingThePagesKeepsTheLongerPrefix() throws {
        let dive = FakeDive(id: 1_789_390_913, profileBytes: 30_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        close(device: first)

        watch.reconnect()
        watch.cancelAtDataPage = 3
        let second = try open(watch, resume: resume)
        XCTAssertEqual(download(second, id: dive.id).0, DC_STATUS_CANCELLED)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: second), 20 * watch.mdsPayloadSize + 2 * watch.summaryPageSize)
        close(device: second)

        watch.mutate { $0.ioCancelled = false }
        watch.reconnect()
        let third = try open(watch, resume: resume)
        let (status, data) = download(third, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
    }

    /// The whole /Data arrived, but the stream didn't end cleanly: no end marker, the link went right
    /// before it, or right after it. The next attempt needs only the /Summary, and never asks for a
    /// page at the end of the /Data, whose answer from a real watch is unknown.
    func testAWholeProfileWithoutACleanEndIsFinishedFromTheSummaryAlone() throws {
        enum Ending: CaseIterable { case noEndMarker, dropBeforeEndMarker, dropAfterEndMarker }
        for (n, ending) in Ending.allCases.enumerated() {
            let dive = FakeDive(id: 1_789_400_000 + UInt32(n) * 7200, profileBytes: 8000)
            let watch = FakeWatch(dives: [dive])
            watch.refuseDataPagesAtEnd = true
            let chunks = (dive.compressed.count + watch.mdsPayloadSize - 1) / watch.mdsPayloadSize
            switch ending {
            case .noEndMarker: watch.streamsWithoutEndMarker = 1
            case .dropBeforeEndMarker: watch.dropAfterChunks = chunks
            case .dropAfterEndMarker: watch.dropAfterEndMarker = true
            }
            let resume = SuuntoNauticResume()

            let first = try open(watch, resume: resume)
            XCTAssertNotEqual(download(first, id: dive.id).0, DC_STATUS_SUCCESS, "\(ending)")
            XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: first), dive.compressed.count, "\(ending)")
            close(device: first)

            watch.reconnect()
            let before = watch.getPaths.count
            let second = try open(watch, resume: resume)
            let (status, data) = download(second, id: dive.id)
            XCTAssertEqual(status, DC_STATUS_SUCCESS, "\(ending)")
            XCTAssertEqual(data, dive.blob, "\(ending)")
            XCTAssertFalse(watch.getPaths[before...].contains("/Logbook/byId/\(dive.id)/Data"), "\(ending): the /Data isn't asked for again")
            XCTAssertTrue(watch.dataPageOffsets.isEmpty, "\(ending)")
            XCTAssertEqual(watch.streamsServed, 1, "\(ending)")
        }
    }

    func testWhenTheWatchWontServeThePagesTheDiveIsStreamedAgainInTheSameAttempt() throws {
        let dive = FakeDive(id: 1_789_390_914, profileBytes: 20_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        close(device: first)

        watch.reconnect()
        watch.refuseDataPages = true
        let second = try open(watch, resume: resume)
        let (status, data) = download(second, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.dataPageOffsets, [UInt32(20 * watch.mdsPayloadSize)], "one refused page, then the stream")
        XCTAssertEqual(watch.streamsServed, 2)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: second))
    }

    func testAResumeThatTimesOutWithoutGettingFurtherStartsOverNextTime() throws {
        let dive = FakeDive(id: 1_789_390_915, profileBytes: 20_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        close(device: first)

        watch.reconnect()
        watch.unansweredDataPages = 1
        let second = try open(watch, resume: resume)
        XCTAssertEqual(download(second, id: dive.id).0, DC_STATUS_TIMEOUT)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: second), "the same request isn't tried again")
        close(device: second)

        watch.reconnect()
        let third = try open(watch, resume: resume)
        let (status, data) = download(third, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamsServed, 2, "streamed from the start")
    }

    func testAResumedDiveWhoseSummaryTimesOutKeepsItsBytes() throws {
        let dive = FakeDive(id: 1_789_390_916, profileBytes: 20_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20
        let resume = SuuntoNauticResume()

        let first = try open(watch, resume: resume)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        close(device: first)
        let kept = 20 * watch.mdsPayloadSize

        // A quiet watch on a live link times out at the /Summary, before any /Data read.
        watch.reconnect()
        watch.unansweredSummaryGets = 1
        let second = try open(watch, resume: resume)
        XCTAssertEqual(download(second, id: dive.id).0, DC_STATUS_TIMEOUT)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: second), kept, "kept for the next connection")
        close(device: second)

        watch.reconnect()
        let third = try open(watch, resume: resume)
        let (status, data) = download(third, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamsServed, 1, "the rest is read in pages, not streamed again")
        XCTAssertEqual(watch.dataPageOffsets.first, UInt32(kept))
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: third))
    }

    func testForeachCarriesOnWithTheDiveTheLinkDroppedIn() throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_700_000 + UInt32($0) * 7200, profileBytes: 20_000) }
        let watch = FakeWatch(dives: dives)
        let resume = SuuntoNauticResume()

        // The newest dive arrives, then the link dies 30 chunks into the next one's /Data.
        let first = try open(watch, resume: resume)
        let (status, delivered) = foreach(first) { n in
            if n == 1 { watch.mutate { $0.dropAfterChunks = 30 } }
        }
        XCTAssertEqual(status, DC_STATUS_IO)
        XCTAssertEqual(delivered.map(\.fingerprint), [dives[2].id])
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dives[1].id, on: first), 30 * watch.mdsPayloadSize)
        close(device: first)

        watch.reconnect()
        let second = try open(watch, resume: resume)
        let (status2, delivered2) = foreach(second)
        XCTAssertEqual(status2, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered2.map(\.fingerprint), dives.reversed().map(\.id))
        XCTAssertEqual(delivered2.map(\.data), dives.reversed().map { $0.blob })
        XCTAssertEqual(watch.streamedPaths, [dives[2], dives[1], dives[2], dives[0]].map { "/Logbook/byId/\($0.id)/Data" },
                       "the dive the link dropped in isn't streamed a second time")
        XCTAssertEqual(watch.dataPageOffsets.first, UInt32(30 * watch.mdsPayloadSize))
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dives[1].id, on: second))
    }

    func testWithoutAResumeBufferADropStartsOver() throws {
        let dive = FakeDive(id: 1_789_390_911, profileBytes: 20_000)
        let watch = FakeWatch(dives: [dive])
        watch.dropAfterChunks = 20

        let first = try open(watch)
        XCTAssertEqual(download(first, id: dive.id).0, DC_STATUS_IO)
        XCTAssertNil(SuuntoNauticResume.resumableBytes(of: dive.id, on: first))
        close(device: first)

        watch.reconnect()
        let second = try open(watch)
        XCTAssertEqual(download(second, id: dive.id).0, DC_STATUS_SUCCESS)
        XCTAssertEqual(watch.streamsServed, 2)
        XCTAssertTrue(watch.dataPageOffsets.isEmpty)
    }

    func testForeignNotificationDuringAStreamIsSkipped() throws {
        let dive = FakeDive(id: 1_789_312_846, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        watch.streamsWithForeignNotification = 1
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamsServed, 1, "skipped, not recovered by a retry")
    }

    func testEmptyLogbookListsNoDives() throws {
        let watch = FakeWatch(dives: [])
        let device = try open(watch)

        XCTAssertEqual(list(device), [])
        let (status, dives) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertTrue(dives.isEmpty)
    }

    func testSubscribingToAnUnknownPathIsUnsupported() throws {
        let watch = FakeWatch(dives: [])
        watch.unknownPaths = ["/Sync/BusyState"]
        let device = try open(watch)

        let buffer = dc_buffer_new(0)
        defer { dc_buffer_free(buffer) }
        var handle: [UInt8] = [0, 0, 0]
        XCTAssertEqual(suunto_nautic_device_subscribe(device, "/Sync/BusyState", &handle, buffer), DC_STATUS_UNSUPPORTED)
    }

    // MARK: - Waiting for a notification: a quiet watch is no error, a failed read still is

    private static var sinkLines: [(level: String, message: String)] = []

    private func captureSink() {
        Self.sinkLines = []
        set_libdc_log_sink { level, message in
            SuuntoNauticTransportTests.sinkLines.append((String(cString: level!), String(cString: message!)))
        }
        addTeardownBlock { set_libdc_log_sink(nil) }
    }

    private static var receiveErrors: Int {
        sinkLines.filter { $0.level == "ERROR" && $0.message.contains("Failed to receive the packet.") }.count
    }

    private func subscribeToUnsynced(_ device: OpaquePointer) {
        let buffer = dc_buffer_new(0)
        defer { dc_buffer_free(buffer) }
        var handle: [UInt8] = [0, 0, 0]
        XCTAssertEqual(suunto_nautic_device_subscribe(device, "/Logbook/UnsynchronisedLogs", &handle, buffer), DC_STATUS_SUCCESS)
    }

    private func waitForNotification(_ device: OpaquePointer) -> (dc_status_t, [UInt8]) {
        let buffer = dc_buffer_new(0)!
        defer { dc_buffer_free(buffer) }
        var handle: [UInt8] = [0, 0, 0]
        let status = suunto_nautic_device_wait_notification(device, 1000, &handle, buffer)
        return (status, Array(UnsafeBufferPointer(start: dc_buffer_get_data(buffer), count: dc_buffer_get_size(buffer))))
    }

    func testAnIdleWaitTimesOutWithoutAnErrorAndADownloadsUnansweredRequestStillLogsOne() throws {
        let dive = FakeDive(id: 1_789_312_850, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        captureSink()
        let device = try open(watch, logging: true)
        subscribeToUnsynced(device)

        for _ in 0..<5 { XCTAssertEqual(waitForNotification(device).0, DC_STATUS_TIMEOUT) }
        XCTAssertEqual(Self.sinkLines.filter { $0.level == "ERROR" }.map(\.message), [], "a quiet watch is the usual outcome of a wait")

        watch.mutate { $0.unsyncedCount = 1 }
        watch.notify("/Logbook/UnsynchronisedLogs")
        let (status, value) = waitForNotification(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(value, [0x05, 0x00, 0x01, 0x00, 0x00])

        watch.mutate { $0.unansweredSummaryGets = 1 }
        XCTAssertEqual(download(device, id: dive.id).0, DC_STATUS_TIMEOUT)
        XCTAssertEqual(Self.receiveErrors, 1, "the download's timeout is still an error: \(Self.sinkLines)")
    }

    func testALinkLostWhileWaitingIsStillAnError() throws {
        let watch = FakeWatch(dives: [])
        captureSink()
        let device = try open(watch, logging: true)
        subscribeToUnsynced(device)

        watch.dropLink()
        XCTAssertEqual(waitForNotification(device).0, DC_STATUS_IO)
        XCTAssertEqual(Self.receiveErrors, 1)
    }

    func testANotificationCutOffWhileWaitingIsStillAnError() throws {
        let watch = FakeWatch(dives: [])
        captureSink()
        let device = try open(watch, logging: true)
        subscribeToUnsynced(device)

        watch.notifyCutOff("/Logbook/UnsynchronisedLogs")
        XCTAssertEqual(waitForNotification(device).0, DC_STATUS_TIMEOUT)
        XCTAssertEqual(Self.receiveErrors, 1, "a timeout with part of a frame received isn't a quiet watch")
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
        XCTAssertEqual(delivered.first?.data, new[2].blob)
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
            XCTAssertEqual(got.data, fake.blob)
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

    // MARK: - A close mid-download: the iostream answers CANCELLED

    func testCancelledReadMidStreamEndsForeachWithoutRetrying() throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_960_000 + UInt32($0) * 7200, profileBytes: 60_000) }
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        // The newest dive arrives; the close lands part-way through the next one's stream.
        let (status, delivered) = foreach(device) { n in
            if n == 1 { watch.mutate { $0.cancelIOAfterStreamBytes = 5_000 } }
        }
        XCTAssertEqual(status, DC_STATUS_CANCELLED)
        XCTAssertEqual(delivered.map(\.fingerprint), [dives[2].id], "nothing past the cancelled dive")
        // The stream's UNSUBSCRIBE and RELEASE are tried and refused at once; no retry sleep, no new GET.
        XCTAssertEqual(watch.cancelledCalls, [.read, .write, .write], "the first cancelled read ends the dive")
        XCTAssertEqual(watch.streamsServed, 2)
        XCTAssertEqual(watch.getPaths.filter { $0.hasSuffix("/Data") }.count, 2)
        XCTAssertFalse(watch.getPaths.contains { $0.contains("\(dives[0].id)") }, "no request after the cancel")
    }

    func testCancelledWriteBetweenDivesEndsForeach() throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_970_000 + UInt32($0) * 7200, profileBytes: 4000) }
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        let (status, delivered) = foreach(device) { n in
            if n == 1 { watch.mutate { $0.ioCancelled = true } }
        }
        XCTAssertEqual(status, DC_STATUS_CANCELLED)
        XCTAssertEqual(delivered.map(\.fingerprint), [dives[2].id])
        XCTAssertEqual(watch.cancelledCalls, [.write], "the next dive's GET is refused and nothing follows")
        XCTAssertEqual(watch.streamsServed, 1)
    }

    // MARK: - A host stop between dives

    func testCallbackStopIsReportedAsSuccessSoTheRetrieverJudgesItCancelled() throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_980_000 + UInt32($0) * 7200, profileBytes: 4000) }
        let watch = FakeWatch(dives: dives)
        let device = try open(watch)

        let (status, delivered) = foreach(device, stopAtDive: 2)
        XCTAssertEqual(status, DC_STATUS_SUCCESS, "the driver can't tell a callback stop from the end of the logbook")
        XCTAssertEqual(delivered.map(\.fingerprint), [dives[2].id])

        let judged = DiveLogRetriever.downloadStatus(foreach: status, closedMidDownload: false, stoppedByHost: true)
        XCTAssertEqual(judged, DC_STATUS_CANCELLED)
        let outcome = DiveLogRetriever.outcome(status: judged, family: DC_FAMILY_SUUNTO_NAUTIC,
                                               fingerprintMatched: false, hasNewDives: true,
                                               hadStoredFingerprint: true, emptyReadCount: 0)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(outcome.saveFingerprint, "the two older dives are still on the watch")
        XCTAssertTrue(outcome.interrupted)
    }

    func testEmptyLogbookEntryIsDeliveredNotSkipped() throws {
        let older = FakeDive(id: 1_789_900_000, profileBytes: 4000)
        let empty = FakeDive(emptyID: 1_789_907_200)
        let newer = FakeDive(id: 1_789_914_400, profileBytes: 4000)
        let watch = FakeWatch(dives: [older, empty, newer])
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(delivered.map(\.fingerprint), [newer.id, empty.id, older.id], "nothing is skipped")
        XCTAssertEqual(delivered.dropFirst().first?.data, empty.blob, "an empty /Summary and /Data, which the parser rejects")
        XCTAssertTrue(watch.streamedPaths.contains("/Logbook/byId/\(empty.id)/Data"))
    }

    func testEntryListedWithoutASizeFailsForeach() throws {
        let older = FakeDive(id: 1_789_900_000, profileBytes: 4000)
        var unsized = FakeDive(id: 1_789_907_200, profileBytes: 4000)
        unsized.hasSize = false
        let newer = FakeDive(id: 1_789_914_400, profileBytes: 4000)
        let watch = FakeWatch(dives: [older, unsized, newer])
        let device = try open(watch)

        let (status, delivered) = foreach(device)
        XCTAssertEqual(status, DC_STATUS_DATAFORMAT)
        XCTAssertEqual(delivered.map(\.fingerprint), [newer.id], "foreach stops at the entry it can't check")
    }

    func testCompleteDownloadById() throws {
        let dive = FakeDive(id: 1_789_312_843, profileBytes: 4000)
        let watch = FakeWatch(dives: [dive])
        let device = try open(watch)

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamsServed, 1)
    }

    // Fork only: upstream checks the listed size unconditionally, which an unlisted dive (listed 0) would fail.
    func testByIdDownloadOfAnUnlistedDiveSkipsTheSizeCheck() throws {
        let listed = FakeDive(id: 1_789_312_848, profileBytes: 3000)
        let unlisted = FakeDive(id: 1_789_312_849, profileBytes: 4000)
        let watch = FakeWatch(dives: [listed, unlisted])
        watch.unlistedIDs = [unlisted.id]
        let device = try open(watch)
        XCTAssertEqual(list(device), [listed.id])
        let listings = watch.entriesStartAfter.count

        let (status, data) = download(device, id: unlisted.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, unlisted.blob)
        XCTAssertEqual(watch.entriesStartAfter.count, listings + 1, "the listing was read for the dive's size")
        XCTAssertEqual(watch.streamedPaths, ["/Logbook/byId/\(unlisted.id)/Data"])
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
        XCTAssertEqual(dataA, a.blob)

        let (statusB, dataB) = download(device, id: b.id)
        XCTAssertEqual(statusB, DC_STATUS_SUCCESS)
        XCTAssertEqual(dataB, b.blob, "dive B's request must not come back with dive A's profile")
        XCTAssertFalse(dataB.dropFirst(4 + b.summary.count).starts(with: a.decompressed))

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
        XCTAssertEqual(got.map(\.data), newestFirst.map { $0.blob })
        XCTAssertEqual(watch.streamedPaths, newestFirst.map { "/Logbook/byId/\($0.id)/Data" })
        XCTAssertEqual(watch.heldIdHandles, [])
    }

    // MARK: - #29: DEVINFO names the model from /Info's product

    private final class DevinfoEvents {
        var devinfo: dc_event_devinfo_t?
    }

    /// The DEVINFO a download of `watch` reports.
    private func devinfo(of watch: FakeWatch) throws -> dc_event_devinfo_t {
        let device = try open(watch, logging: true)
        let events = DevinfoEvents()
        XCTAssertEqual(dc_device_set_events(device, DC_EVENT_DEVINFO.rawValue, { _, event, data, userdata in
            guard event == DC_EVENT_DEVINFO, let data, let userdata else { return }
            Unmanaged<DevinfoEvents>.fromOpaque(userdata).takeUnretainedValue().devinfo =
                data.assumingMemoryBound(to: dc_event_devinfo_t.self).pointee
        }, Unmanaged.passUnretained(events).toOpaque()), DC_STATUS_SUCCESS)
        XCTAssertEqual(foreach(device).0, DC_STATUS_SUCCESS)
        return try XCTUnwrap(events.devinfo)
    }

    private func oceanOrNautic(_ product: String) -> FakeWatch {
        let watch = FakeWatch(dives: [FakeDive(id: 1_789_100_000, profileBytes: 600, summaryBytes: 100)])
        watch.product = product
        return watch
    }

    func testDevinfoReportsAnOceanAsModel1AndANauticAsModel0() throws {
        captureSink()
        for (product, model) in [("Ocean", UInt32(1)), ("Nautic", 0), ("Nautic S", 0)] {
            let info = try devinfo(of: oceanOrNautic(product))
            XCTAssertEqual(info.model, model, product)
            XCTAssertEqual(info.serial, 0xC300_3306, product)
            XCTAssertEqual(info.firmware, 2 << 16 | 51 << 8 | 28, product)
        }
        XCTAssertEqual(Self.sinkLines.filter { $0.level == "WARN" }.map(\.message), [])
    }

    func testAnUnknownProductIsReportedAsANauticWithAWarning() throws {
        captureSink()
        XCTAssertEqual(try devinfo(of: oceanOrNautic("Race")).model, 0)
        XCTAssertEqual(Self.sinkLines.filter { $0.level == "WARN" }.map { $0.message.components(separatedBy: "(): ").last },
                       ["Unknown product 'Race' in the device info."])
    }

    /// Build 32's log: "Updating stored device from suuntoNautic model 1 to suuntoNautic model 0 for Suunto Ocean". The
    /// Explorer's download stores DEVINFO's model as it comes, and the driver reported 0 for both watches.
    func testTheExplorersDownloadKeepsAStoredOceanAtModel1() throws {
        let suiteName = "com.libdcswift.tests.nautic-model.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = DeviceStorage(userDefaults: defaults)
        let ptr = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        ptr.initialize(to: device_data_t())
        defer { ptr.deallocate() }
        ptr.pointee.have_devinfo = 1

        func download(_ product: String, stored: UInt32, session: Bool = false) throws -> UInt32? {
            storage.storeDevice(uuid: "WATCH", name: "Suunto \(product) Test", family: .suuntoNautic, model: stored)
            ptr.pointee.devinfo = try devinfo(of: oceanOrNautic(product))
            DeviceConfiguration.updateDeviceConfigurationFromHardware(
                deviceAddress: "WATCH", deviceDataPtr: ptr, deviceName: "Suunto \(product) Test", storage: storage,
                requireKnownModel: session)
            return storage.getStoredDevice(uuid: "WATCH")?.model
        }

        XCTAssertEqual(try download("Ocean", stored: 1), 1)
        XCTAssertEqual(try download("Ocean", stored: 0), 1, "an Ocean an earlier build stored as model 0 is put right")
        XCTAssertEqual(try download("Nautic", stored: 0), 0)
        XCTAssertEqual(try download("Ocean", stored: 0, session: true), 1, "a session download puts it right too")
        XCTAssertEqual(try download("Nautic", stored: 0, session: true), 0)
    }

    // MARK: - Full logging

    private static let fullLog = BoundedLogBuffer()
    private static let fullLogClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// What DC Tester's Share log holds after a full-logging download: four dives the size of #29's 1787752091, read 60 bytes
    /// at a time. The fake sends each as 843,681 bytes of heatshrink literals (673,907 compressed on the real watch), so this
    /// logs more than a real download: about 13 MB here, 6.0 MB for the real two-dive capture in the same line format.
    func testAFullLoggingDownloadOfFourRealSizeDivesFitsTheDefaultLogBuffer() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_1787752091", withExtension: "bin"))
        let fixture = [UInt8](try Data(contentsOf: url))
        let summarySize = Int(Self.le32(fixture, 0))
        let summary = Array(fixture[4..<(4 + summarySize)])
        let profile = Array(fixture[(4 + summarySize)...])
        let dives = (0..<4).map { FakeDive(id: 1_787_752_091 + UInt32($0) * 86_400, summary: summary, profile: profile) }
        let watch = FakeWatch(dives: dives)
        watch.maxReadSize = 60

        Self.fullLog.removeAll()
        LibDCLogging.level = .all
        set_libdc_log_sink { level, message in
            let stamp = SuuntoNauticTransportTests.fullLogClock.string(from: Date())
            SuuntoNauticTransportTests.fullLog.append(
                "\(stamp) [libdc \(String(cString: level!))] \(String(cString: message!))")
        }
        defer {
            set_libdc_log_sink(nil)
            LibDCLogging.level = .warning
        }
        let device = try open(watch, logging: true)

        let (status, got) = foreach(device)

        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(got.count, 4)
        let wire = dives.reduce(0) { $0 + $1.compressed.count + $1.summary.count }
        let logged = Self.fullLog.byteCount
        let perByte = Double(logged) / Double(wire)
        print(String(format: "Full log: %d lines, %d bytes for %d bytes on the wire (%.2f per byte); a 673,907-byte dive logs ~%.1f MB",
                     Self.fullLog.lineCount, logged, wire, perByte, perByte * 673_907 / 1_048_576))
        XCTAssertEqual(Self.fullLog.droppedLineCount, 0, "four dives fit the default buffer")
        XCTAssertGreaterThan(Self.fullLog.lines().filter { $0.contains("Read: size=60, data=") }.count, wire / 60 * 9 / 10)
        Self.fullLog.removeAll()
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
                              resume: SuuntoNauticResume? = nil,
                              configure: (inout NauticAutoSync.Configuration) -> Void = { _ in })
        -> (NauticAutoSync, FakeConnector, VirtualClock, EventLog) {
        let connector = FakeConnector(watch: watch, open: { [unowned self] in try self.open(watch, resume: resume) },
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
            XCTAssertEqual(dive.data, Data(fake.blob))
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

    func testAutoSyncCarriesOnFromTheBytesReceivedBeforeADrop() async throws {
        let dives = (0..<3).map { FakeDive(id: 1_789_000_000 + UInt32($0) * 7200, profileBytes: 6000) }
        let watch = FakeWatch(dives: dives)
        let (sync, connector, _, log) = makeAutoSync(watch, resume: SuuntoNauticResume())

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
            XCTAssertEqual(dive.data, Data(fake.blob))
            XCTAssertTrue(dive.isComplete)
        }
        XCTAssertEqual(delivered[1].attempts, 2)
        XCTAssertEqual(connector.connects, 2)
        let kept = 2 * watch.mdsPayloadSize
        XCTAssertTrue(Self.logs(events).contains("Dive \(dives[1].id): carrying on from byte \(kept) of an earlier attempt"))
        XCTAssertEqual(watch.streamedPaths, dives.map { "/Logbook/byId/\($0.id)/Data" },
                       "the rest of the dive the link dropped in comes in pages, not a second stream")
        XCTAssertEqual(watch.dataPageOffsets.first, UInt32(kept))
    }

    func testAutoSyncRetriesADiveThatFailsItsSizeCheck() async throws {
        let dive = FakeDive(id: 1_789_100_000, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.truncateStreamBy = 300
        watch.truncatedStreams = 2 // Auto download's first retry also comes back short
        let (sync, connector, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        let delivered = Self.dives(log.all)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.isComplete, true)
        XCTAssertEqual(delivered.first?.data, Data(dive.blob))
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

    func testAutoSyncGivesUpOnADiveWhoseStreamNeverEndsAndGetsTheNewerOnes() async throws {
        let stuck = FakeDive(id: 1_789_250_000, profileBytes: 6000)
        let newer = FakeDive(id: 1_789_260_000, profileBytes: 600, summaryBytes: 100)
        let watch = FakeWatch(dives: [stuck, newer])
        watch.divesWithoutEndMarker = [stuck.id]
        let (sync, connector, _, log) = makeAutoSync(watch) { $0.retriesPerDive = 1 }

        sync.start()
        await waitFor(log) { !Self.completedSyncs($0).isEmpty }
        await stopAndWait(sync, log)

        XCTAssertEqual(Self.dives(log.all).map(\.id), [newer.id])
        XCTAssertTrue(log.all.contains(.diveFailed(id: stuck.id, reason: "TIMEOUT")))
        XCTAssertEqual(Self.completedSyncs(log.all).first?.failed, [stuck.id])
        XCTAssertEqual(connector.connects, 3, "two attempts on the stuck dive, then a session without it")
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
        // The watch reports busy while the Suunto app syncs it, so the app's session is on the link: the open uses it.
        watch.busy = 1
        watch.appSession = true
        let (sync, _, _, log) = makeAutoSync(watch)

        sync.start()
        await waitFor(log) { $0.contains(.state(.watchBusy)) }
        XCTAssertEqual(watch.hellosReceived, 0, "no hello over the app's session")
        // The open's probe GETs /Logbook/Entries without fetching it; a listing fetches its pages.
        XCTAssertEqual(watch.entriesStartAfter, [], "nothing is listed while the watch is busy")

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
        XCTAssertEqual(watch.sessionlessRequests, 1, "a fresh link leaves the probe unanswered")
        XCTAssertEqual(watch.hellosReceived, 1)
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(device), 0)
    }

    func testTheAppsSessionCountsAsAcknowledged() throws {
        let watch = FakeWatch(dives: [])
        watch.appSession = true
        watch.withholdHelloAck = true
        let device = try open(watch)
        XCTAssertEqual(watch.hellosReceived, 0, "the probe was answered, so there is no hello to go unanswered")
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(device), 1)
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

// MARK: - Sharing the watch with the Suunto app (deepsealabs/libdivecomputer#20 on round 4)

extension SuuntoNauticTransportTests {
    private func subscribe(_ device: OpaquePointer, _ path: String) -> dc_status_t {
        let buffer = dc_buffer_new(0)!
        defer { dc_buffer_free(buffer) }
        var handle: [UInt8] = [0, 0, 0]
        return suunto_nautic_device_subscribe(device, path, &handle, buffer)
    }

    private func cancelOnceSteppedAside(_ device: OpaquePointer) {
        dc_device_set_cancel(device, { userdata in
            suunto_nautic_device_taken_over(OpaquePointer(userdata)) != 0 ? 1 : 0
        }, UnsafeMutableRawPointer(device))
    }

    func testAFreshLinkGetsAHelloAfterTheUnansweredProbe() throws {
        let dive = FakeDive(id: 1_790_000_001, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        let device = try open(watch)
        XCTAssertEqual(watch.sessionlessRequests, 1, "nobody said hello on the link, so the probe goes unanswered")
        XCTAssertEqual(watch.hellosReceived, 1)
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(device), 1)
        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
    }

    func testTheAppsSessionIsUsedWithoutAHello() throws {
        let dive = FakeDive(id: 1_790_000_002, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.appSession = true
        let device = try open(watch)
        XCTAssertEqual(watch.hellosReceived, 0, "a hello would take the Suunto app's session over")
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(device), 1)
        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        let (walk, dives) = foreach(device)
        XCTAssertEqual(walk, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.map(\.data), [dive.blob])
    }

    /// Build 32's 14:14:04: the Suunto app's hello cut a chunk off, and its reply came right behind it.
    func testAnAppHelloThatTearsAChunkStepsAsideAndTheNextConnectionCarriesOn() throws {
        let dive = FakeDive(id: 1_790_000_003, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        watch.appDuringStream = (100, .tornHello)
        let resume = SuuntoNauticResume()
        let log = DriverLog()
        let (opened, first) = try openStatus(watch, resume: resume, log: log)
        XCTAssertEqual(opened, DC_STATUS_SUCCESS)
        let device = try XCTUnwrap(first)
        let releases = watch.releases

        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_IO)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(log.count("Another app is using the watch (13 0)"), 1, "the hello reply is read behind the torn chunk")
        XCTAssertEqual(watch.streamUnsubscribes, [], "no UNSUBSCRIBE into the app's session")
        XCTAssertEqual(watch.releases - releases, 1, "only the /Summary's, before the stream")
        XCTAssertEqual(watch.heldIdHandles, ["/Logbook/byId/\(dive.id)/Data"], "nor a RELEASE of the /Data handle")
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: device), 100 * watch.mdsPayloadSize)
        let gets = watch.getPaths.count
        XCTAssertEqual(download(device, id: dive.id).0, DC_STATUS_IO)
        XCTAssertEqual(watch.getPaths.count, gets, "a device that stepped aside sends nothing more")
        close(device: device)

        watch.reconnect()
        let second = try open(watch, resume: resume)
        XCTAssertEqual(watch.hellosReceived, 1, "the next open uses the app's session")
        let (again, whole) = download(second, id: dive.id)
        XCTAssertEqual(again, DC_STATUS_SUCCESS)
        XCTAssertEqual(whole, dive.blob)
        XCTAssertEqual(watch.streamsServed, 1, "the rest comes in pages")
    }

    /// Build 32's 14:15:29: the app's hello reply arrived whole between two chunks.
    func testAnAppHelloBetweenChunksLeavesTheStreamAlone() throws {
        let dive = FakeDive(id: 1_790_000_004, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        watch.appSession = true
        watch.appDuringStream = (50, .hello)
        let resume = SuuntoNauticResume()
        let device = try open(watch, resume: resume)
        let releases = watch.releases

        XCTAssertEqual(download(device, id: dive.id).0, DC_STATUS_IO)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(watch.streamUnsubscribes, [], "its hello ended our stream")
        XCTAssertEqual(watch.releases - releases, 1)
        XCTAssertEqual(watch.heldIdHandles, ["/Logbook/byId/\(dive.id)/Data"])
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: device), 50 * watch.mdsPayloadSize)
    }

    func testAnAppReplyMidStreamEndsOurStreamFirst() throws {
        let dive = FakeDive(id: 1_790_000_005, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        watch.appSession = true
        watch.appDuringStream = (50, .reply)
        let resume = SuuntoNauticResume()
        let device = try open(watch, resume: resume)

        XCTAssertEqual(download(device, id: dive.id).0, DC_STATUS_IO)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(watch.streamUnsubscribes, [200], "our stream is still ours to stop")
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: device), 50 * watch.mdsPayloadSize)
    }

    func testAppRepliesLeftFromBeforeAreDroppedBeforeADownload() throws {
        let dive = FakeDive(id: 1_790_000_006, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.appSession = true
        let device = try open(watch)

        watch.pushAppReplies(3000)
        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        watch.pushAppReplies(3000)
        let (walk, dives) = foreach(device)
        XCTAssertEqual(walk, DC_STATUS_SUCCESS)
        XCTAssertEqual(dives.count, 1)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 0)
    }

    func testANotificationWaitSkipsAppRepliesAndEndsOnItsHello() throws {
        let watch = FakeWatch(dives: [])
        let log = DriverLog()
        let device = try XCTUnwrap(try openStatus(watch, log: log).1)
        XCTAssertEqual(subscribe(device, "/Logbook/UnsynchronisedLogs"), DC_STATUS_SUCCESS)

        watch.pushAppReplies(3)
        XCTAssertEqual(waitForNotification(device).0, DC_STATUS_TIMEOUT, "the app's replies get in nobody's way")
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 0)

        watch.pushAppReplies(2)
        watch.mutate { $0.unsyncedCount = 1 }
        watch.notify("/Logbook/UnsynchronisedLogs")
        XCTAssertEqual(waitForNotification(device).0, DC_STATUS_SUCCESS, "a push behind the app's replies still arrives")

        watch.pushAppHello()
        XCTAssertEqual(waitForNotification(device).0, DC_STATUS_IO, "its hello ends our session and its subscriptions")
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(log.stepAsideWaits, 0, "a notification wait doesn't wait for the app")
    }

    func testABusyLinkThatGoesQuietOpensOnTheAppsSession() throws {
        let watch = FakeWatch(dives: [])
        watch.appSession = true
        watch.pushAppReplies(5)
        let log = DriverLog()
        let (status, _) = try openStatus(watch, log: log)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(watch.hellosReceived, 0)
        XCTAssertEqual(log.openWaits, 1)
    }

    func testALinkThatStaysBusyFailsTheOpenWithTimeout() throws {
        let watch = FakeWatch(dives: [])
        watch.appBusy = true
        let started = Date()
        let (status, _) = try openStatus(watch)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT, "TIMEOUT from the open means the Suunto app is using the watch")
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "one wait of about 20 s")
        XCTAssertEqual(watch.hellosReceived, 0)
    }

    func testAppTrafficAnsweringOurHelloFailsTheOpenWithoutASecondWait() throws {
        let watch = FakeWatch(dives: [])
        watch.appBusyAfterHello = true
        watch.pushAppReplies(5)
        let log = DriverLog()
        let started = Date()
        let (status, _) = try openStatus(watch, log: log)
        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(watch.hellosReceived, 1)
        XCTAssertEqual(log.openWaits, 1, "the probe's")
        XCTAssertEqual(log.stepAsideWaits, 0)
    }

    func testALateReplyToTheProbeIsOurs() throws {
        let watch = FakeWatch(dives: [])
        watch.answersProbeLate = true
        let (status, device) = try openStatus(watch)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        let opened = try XCTUnwrap(device)
        XCTAssertEqual(suunto_nautic_device_handshake_acknowledged(opened), 1)
        XCTAssertEqual(suunto_nautic_device_taken_over(opened), 0)
    }

    func testALateReplyToARetriedRequestIsOurs() throws {
        let watch = FakeWatch(dives: [])
        let device = try open(watch)
        watch.mutate { $0.lateReplyTo = 0x10 }
        XCTAssertEqual(subscribe(device, "/Logbook/UnsynchronisedLogs"), DC_STATUS_TIMEOUT, "the SUBSCRIBE's reply is late")
        XCTAssertEqual(subscribe(device, "/Logbook/UnsynchronisedLogs"), DC_STATUS_SUCCESS, "and is skipped as ours")
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 0)
    }

    func testACancelDuringAStreamsStepAsideIsCancelled() throws {
        let dive = FakeDive(id: 1_790_000_007, profileBytes: 60_000)
        let watch = FakeWatch(dives: [dive])
        watch.appSession = true
        watch.appDuringStream = (20, .tornHello)
        let resume = SuuntoNauticResume()
        let device = try open(watch, resume: resume)
        cancelOnceSteppedAside(device)

        XCTAssertEqual(download(device, id: dive.id).0, DC_STATUS_CANCELLED)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
        XCTAssertEqual(SuuntoNauticResume.resumableBytes(of: dive.id, on: device), 20 * watch.mdsPayloadSize, "the bytes are kept")
    }

    func testACancelDuringARequestsStepAsideIsCancelled() throws {
        let watch = FakeWatch(dives: [])
        watch.appSession = true
        let device = try open(watch)
        cancelOnceSteppedAside(device)
        watch.pushAppReplies(1)
        let response = dc_buffer_new(0)!
        defer { dc_buffer_free(response) }
        XCTAssertEqual(suunto_nautic_device_request(device, "/Info", response), DC_STATUS_CANCELLED)
        XCTAssertEqual(suunto_nautic_device_taken_over(device), 1)
    }

    func testAStreamLeftOverFromAnEarlierConnectionIsEnded() throws {
        let dive = FakeDive(id: 1_790_000_008, profileBytes: 6000)
        let watch = FakeWatch(dives: [dive])
        watch.refuseStreams = 1
        let device = try open(watch)
        let (status, data) = download(device, id: dive.id)
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(data, dive.blob)
        XCTAssertEqual(watch.streamUnsubscribes, [200, 200], "the left-over stream's, then ours at the end")
        XCTAssertEqual(watch.heldIdHandles, [])
    }
}
