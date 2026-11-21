import SwiftUI
import UIKit
import LibDCSwift

/// libdivecomputer's DC_LOGLEVEL_ALL from the next connection on: every byte to and from the watch. Off by default.
enum FullLogging {
    static let key = "dctester.fullLogging"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    static func applySaved() {
        LibDCLogging.level = isOn ? .all : .warning
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        LibDCLogging.level = on ? .all : .warning
        ExplorerLog.shared.append("Full logging \(on ? "ON" : "OFF"), from the next connection")
    }

    static let footer = "Records everything sent to and from the watch, from the next connection on. Logs get big and include the watch's serial number and Bluetooth/Wi-Fi addresses, and your dives with their GPS positions, so share them privately (email) if you prefer."
}

struct FullLoggingToggle: View {
    @AppStorage(FullLogging.key) private var isOn = false

    var body: some View {
        Toggle("Full logging", isOn: Binding(get: { isOn }, set: { FullLogging.set($0) }))
    }
}

/// Every DC Tester log line starts with its local date and time to the millisecond, so a line kept from an earlier
/// session can't pass for one of this run's.
enum LogStamp {
    /// Put before a line DC Tester 32 or before wrote, with the time only, when it's read back.
    static let undated = "undated "

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let pattern = Array("0000-00-00 00:00:00.000".utf8)

    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// `text` as log lines stamped with `date`, one for each of its lines, so a multi-line message has no line without one.
    static func lines(_ text: String, at date: Date) -> [String] {
        let stamp = string(date)
        guard text.contains("\n") else { return ["\(stamp) \(text)"] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { "\(stamp) \($0)" }
    }

    static func isStamped<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        var index = bytes.startIndex
        for expected in pattern {
            guard index != bytes.endIndex else { return false }
            let byte = bytes[index]
            guard expected == UInt8(ascii: "0") ? (0x30...0x39).contains(byte) : byte == expected else { return false }
            index = bytes.index(after: index)
        }
        return true
    }

    /// A line read back from disk: as it is once stamped or marked, else marked undated.
    static func restored(_ line: String) -> String {
        isStamped(line.utf8) || line.hasPrefix(undated) ? line : undated + line
    }

    /// `restored(_:)` for each line of a file, leaving out blank ones.
    static func restored(_ data: Data) -> Data {
        let mark = Data(undated.utf8)
        var out = Data(capacity: data.count + data.count / 16)
        for line in data.split(separator: 0x0A) {
            if !isStamped(line) && !line.starts(with: mark) { out.append(mark) }
            out.append(line)
            out.append(0x0A)
        }
        return out
    }

    /// The first line of a session: the build, and the time zone its lines are in.
    static func sessionStart(at date: Date) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let zone = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        return "===== Session started: DC Tester \(AutoDownloadController.appVersion), LibDCSwift \(libDCSwiftBuildTag), "
            + "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), times in \(zone). Lines above are from earlier sessions. ====="
    }
}

/// The Explorer's connects, commands and results, kept for pasting into a GitHub issue. Safe from any thread: the
/// libdivecomputer sink appends from the download thread, where a full log's many lines a second would swamp main.
final class ExplorerLog: ObservableObject {
    static let shared = ExplorerLog(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])

    /// Main thread; trails appends by up to `publishDelay`.
    @Published private(set) var lineCount = 0

    // A full log's whole copy is on disk in `fullLog`, so memory only keeps a window of it.
    private let buffer = BoundedLogBuffer(maxBytes: 4 * 1024 * 1024)
    private let lock = NSLock()
    private let launched = Date()
    private var sessionMarked = false
    private var lastText: String?
    private var lastDevice: String?
    private var fullLoggingSince: Date?
    private var publishScheduled = false
    private var unwritten: [String] = []
    private var unwrittenFull: [String] = []

    // The file only brings back the last lines after a relaunch; it and `fullLog` are touched on fileQueue only.
    private let fileQueue = DispatchQueue(label: "dctester.explorer-log.file")
    private var handle: FileHandle?
    private var fileBytes = 0
    private var recentlyWritten: [String] = []
    private let fullLog: FullLogStore
    // One share at a time, as each clears the last one's files.
    private let shareQueue = DispatchQueue(label: "dctester.explorer-log.share")
    private let shareDirectory: URL

    private static let restoredLines = 500
    private static let maxFileBytes = 4 * 1024 * 1024
    private static let publishDelay = 0.25
    private let file: URL

    init(directory: URL, shareDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("share-log"),
         fullLogMaxBytes: Int = FullLogStore.defaultMaxBytes, fullLogSegmentBytes: Int = FullLogStore.defaultSegmentBytes) {
        file = directory.appendingPathComponent("explorer.log")
        self.shareDirectory = shareDirectory
        fullLog = FullLogStore(directory: directory.appendingPathComponent("full-log"), maxBytes: fullLogMaxBytes,
                               segmentBytes: fullLogSegmentBytes)
        let restored = Self.lastLines(of: file, count: Self.restoredLines).map(LogStamp.restored)
        buffer.append(contentsOf: restored)
        recentlyWritten = restored
        fileBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        fullLoggingSince = fullLog.meta?.since
        lastDevice = fullLog.meta?.device
        _lineCount = Published(initialValue: buffer.lineCount)
        // Queued first, so it runs before any line of this session reaches the full log.
        fileQueue.async { [fullLog] in fullLog.markUndatedLines() }
    }

    func append(_ text: String) {
        lock.lock()
        appendLocked(text)
        lock.unlock()
    }

    /// A `set_libdc_log_sink` line. Only an ERROR or WARN repeat is left out, as the parser logs one twice on a dive it
    /// rejects (for the date, then the samples); a repeated full logging line is a real event, such as a second read.
    func appendLibdc(level: String, message: String) {
        let text = "[libdc \(level)] \(message)"
        let detail = level == "INFO" || level == "DEBUG" || level == "ALL"
        lock.lock()
        // DC Tester opens contexts at WARNING or ALL only, so a line below WARN comes from a full logging one.
        if detail { markFullLocked() }
        if detail || text != lastText { appendLocked(text) }
        lock.unlock()
    }

    /// Logs a connection starting and names its watch in the header.
    func noteConnection(_ text: String, device: String) {
        lock.lock()
        lastDevice = device
        if fullLoggingSince != nil { fileQueue.async { [self] in fullLog.setDevice(device) } }
        appendLocked(text)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lastText = nil
        fullLoggingSince = nil
        unwritten.removeAll()
        unwrittenFull.removeAll()
        buffer.removeAll()
        fileQueue.async { [self] in
            try? handle?.close()
            handle = nil
            fileBytes = 0
            recentlyWritten.removeAll()
            try? FileManager.default.removeItem(at: file)
            fullLog.removeAll()
            try? FileManager.default.removeItem(at: shareDirectory)
        }
        lock.unlock()
        lineCount = 0
    }

    var usedFullLogging: Bool {
        lock.lock(); defer { lock.unlock() }
        return fullLoggingSince != nil
    }

    /// Writes the lines not on disk yet and waits for them, as the next publish would.
    func flush() {
        lock.lock()
        flushLocked()
        lock.unlock()
        fileQueue.sync {}
    }

    /// The lines kept in memory; for a full log, only its newest (Share log has all of it).
    func text(device: String? = nil) -> String {
        memoryText(device: device, fullLogNote: "Newest lines only: Share log has the whole full log.")
    }

    /// What Share log hands the share sheet, on main: see `makeShareItems(device:)`.
    func shareItems(device: String? = nil, completion: @escaping ([Any]) -> Void) {
        shareQueue.async { [self] in
            let items = makeShareItems(device: device)
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// The text, or once full logging was on, the whole full log from disk, across relaunches: a .zip of a header and the
    /// log's parts, or the parts themselves if the zip can't be made. Blocks on the file queue, so call it off main.
    func makeShareItems(device: String? = nil) -> [Any] {
        lock.lock()
        flushLocked()
        let full = fullLoggingSince != nil
        lock.unlock()
        guard full else { return [text(device: device)] }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: shareDirectory)
        Self.removeOldExports()
        let name = shareName()
        let folder = shareDirectory.appendingPathComponent(name)
        let header = Array(headerLines(device: device).dropLast())
        guard let parts = fileQueue.sync(execute: { fullLog.exportParts(to: folder, header: header) }) else {
            try? fileManager.removeItem(at: folder)
            return [memoryText(device: device, fullLogNote: "The full log couldn't be written out, so newest lines only.")]
        }
        let zip = shareDirectory.appendingPathComponent(name + ".zip")
        guard Self.zip(folder, to: zip) else { return parts }
        try? fileManager.removeItem(at: folder)
        return [zip]
    }

    private func memoryText(device: String?, fullLogNote: String) -> String {
        var header = headerLines(device: device)
        if usedFullLogging { header.insert(fullLogNote, at: header.count - 1) }
        return (header + buffer.lines()).joined(separator: "\n")
    }

    private func headerLines(device: String?) -> [String] {
        lock.lock()
        let since = fullLoggingSince
        let device = device ?? lastDevice
        lock.unlock()
        let versions = "DC Tester \(AutoDownloadController.appVersion), LibDCSwift \(libDCSwiftBuildTag), libdivecomputer \(LibDCLogging.libdivecomputerVersion)"
        return [
            "DC Tester \(AutoDownloadController.appVersion) explorer log",
            since.map { "Full logging ON (DC_LOGLEVEL_ALL) from \(LogStamp.string($0)): \(versions)" }
                ?? "Full logging off: \(versions)",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "Device: \(device ?? "none")",
            "This session started \(LogStamp.string(launched)); each session's first line is \"===== Session started\".",
            ""
        ]
    }

    private func shareName() -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "DC-Tester-\(build)-full-log-\(stamp.string(from: Date()))"
    }

    /// Build 32 left each shared full log in the temporary directory.
    private static func removeOldExports() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("DC-Tester-") && name.contains("-full-log-") && name.hasSuffix(".txt") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// `folder` as a zip at `destination`, the folder at its root. The system zips it, streaming from disk.
    static func zip(_ folder: URL, to destination: URL) -> Bool {
        var coordination: NSError?
        var made = false
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
            try? FileManager.default.removeItem(at: destination)
            made = (try? FileManager.default.moveItem(at: zipped, to: destination)) != nil
                || (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil
        }
        return coordination == nil && made
    }

    private func markFullLocked() {
        guard fullLoggingSince == nil else { return }
        let since = Date()
        fullLoggingSince = since
        // Seeded with the lines before it, so the full log on disk reads as the whole log.
        let seed = buffer.lines()
        let device = lastDevice
        fileQueue.async { [self] in fullLog.start(since: since, device: device, seed: seed) }
    }

    private func appendLocked(_ text: String) {
        lastText = text
        let now = Date()
        if !sessionMarked {
            sessionMarked = true
            addLocked(LogStamp.lines(LogStamp.sessionStart(at: launched), at: now))
        }
        addLocked(LogStamp.lines(text, at: now))
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay) { [self] in publish() }
    }

    private func addLocked(_ lines: [String]) {
        buffer.append(contentsOf: lines)
        unwritten.append(contentsOf: lines)
        if fullLoggingSince != nil { unwrittenFull.append(contentsOf: lines) }
    }

    private func publish() {
        lock.lock()
        publishScheduled = false
        flushLocked()
        lock.unlock()
        lineCount = buffer.lineCount
    }

    // Queued under `lock`, so batches reach the file queue in the order they were appended.
    private func flushLocked() {
        let lines = unwritten
        let full = unwrittenFull
        unwritten.removeAll()
        unwrittenFull.removeAll()
        guard !lines.isEmpty || !full.isEmpty else { return }
        fileQueue.async { [self] in
            if !lines.isEmpty { write(lines) }
            if !full.isEmpty { fullLog.append(full) }
        }
    }

    private func write(_ lines: [String]) {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if handle == nil {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
        }
        guard let handle, (try? handle.write(contentsOf: data)) != nil else { return }
        fileBytes += data.count
        recentlyWritten.append(contentsOf: lines)
        if recentlyWritten.count > Self.restoredLines * 2 {
            recentlyWritten.removeFirst(recentlyWritten.count - Self.restoredLines)
        }
        guard fileBytes > Self.maxFileBytes else { return }
        // Cut back to what a relaunch restores; a full log keeps its whole copy in `fullLog`.
        try? handle.close()
        self.handle = nil
        let kept = Data((recentlyWritten.suffix(Self.restoredLines).joined(separator: "\n") + "\n").utf8)
        try? kept.write(to: file, options: .atomic)
        fileBytes = kept.count
    }

    private static func lastLines(of url: URL, count: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let window: UInt64 = 1024 * 1024
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        // A window that starts mid-file starts mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(count))
    }
}

/// A full log on disk, so a crash, an eviction or a relaunch doesn't lose it. Lines go into segment files of about
/// `segmentBytes`. Past `maxBytes` in all it keeps the segments in its first quarter (the handshake and dive list) and
/// the newest, as `BoundedLogBuffer` does, and counts what it dropped for a marker. Share log hands over every segment.
/// Not thread-safe: `ExplorerLog` uses it on its file queue.
final class FullLogStore {
    struct Meta: Codable {
        var since: Date
        var device: String?
        var droppedLines = 0
        var droppedBytes = 0
        /// nil for a log DC Tester 32 wrote, whose lines have the time only.
        var format: Int?
    }

    /// About 40 Suunto Nautic dives at full logging (about 3 MB each), so a long download fits whole.
    static let defaultMaxBytes = 128 * 1024 * 1024
    static let defaultSegmentBytes = 4 * 1024 * 1024
    private static let format = 1

    private(set) var meta: Meta?
    let maxBytes: Int
    private let headBytes: Int
    private let directory: URL
    private let segmentBytes: Int
    private var segments: [Int] = []
    private var sizes: [Int] = []
    private(set) var byteCount = 0
    private var handle: FileHandle?

    init(directory: URL, maxBytes: Int = FullLogStore.defaultMaxBytes, segmentBytes: Int = FullLogStore.defaultSegmentBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.segmentBytes = max(1, segmentBytes)
        headBytes = maxBytes / 4
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        self.meta = meta
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        segments = names.compactMap(Self.segmentIndex).sorted()
        sizes = segments.map { (try? FileManager.default.attributesOfItem(atPath: segmentURL($0).path)[.size] as? Int) ?? 0 }
        byteCount = sizes.reduce(0, +)
    }

    /// Starts a new full log, replacing any earlier one.
    func start(since: Date, device: String?, seed: [String]) {
        removeAll()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        meta = Meta(since: since, device: device, format: Self.format)
        saveMeta()
        append(seed)
    }

    func append(_ lines: [String]) {
        guard meta != nil, !lines.isEmpty, let handle = openSegment() else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard (try? handle.write(contentsOf: data)) != nil else { return }
        sizes[sizes.count - 1] += data.count
        byteCount += data.count
        dropOverflow()
    }

    func setDevice(_ device: String) {
        guard meta != nil, meta?.device != device else { return }
        meta?.device = device
        saveMeta()
    }

    /// Marks each line of a log DC Tester 32 wrote as undated, once.
    func markUndatedLines() {
        guard var meta, meta.format == nil else { return }
        try? handle?.close()
        handle = nil
        for (position, index) in segments.enumerated() {
            let url = segmentURL(index)
            guard let data = try? Data(contentsOf: url) else { continue }
            let marked = LogStamp.restored(data)
            guard (try? marked.write(to: url, options: .atomic)) != nil else { continue }
            byteCount += marked.count - sizes[position]
            sizes[position] = marked.count
        }
        meta.format = Self.format
        self.meta = meta
        saveMeta()
    }

    /// Writes the log to `folder` as `part-000-header.txt` (`header`, then what the parts are), then a part for each
    /// segment in order, and where the cap dropped some, a part with the marker; joined in name order they're the log.
    /// Closed segments are hard-linked and the open one copied, so it takes no memory. nil when there's no log or a part
    /// can't be written.
    func exportParts(to folder: URL, header: [String]) -> [URL]? {
        guard let meta else { return nil }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder)
        guard (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }

        let head = gap
        let truncated = meta.droppedLines > 0 && head != nil
        let partCount = segments.count + (truncated ? 1 : 0)
        var summary = partCount == 0 ? "Full log: no lines yet."
            : "Full log: \(partCount) part(s) after this header, \(Self.mb(byteCount)), part-001.txt to "
                + String(format: "part-%03d.txt", partCount) + ". Joined in name order they're the whole log (cat part-*.txt)."
        if truncated { summary += " " + marker(meta) + ", at the -truncated part." }
        let headerURL = folder.appendingPathComponent("part-000-header.txt")
        guard fileManager.createFile(atPath: headerURL.path, contents: Data(((header + [summary, ""]).joined(separator: "\n") + "\n").utf8)) else {
            return nil
        }

        var urls = [headerURL]
        for (position, index) in segments.enumerated() {
            if truncated, position == head {
                let url = folder.appendingPathComponent(String(format: "part-%03d-truncated.txt", urls.count))
                guard fileManager.createFile(atPath: url.path, contents: Data((marker(meta) + "\n").utf8)) else { return nil }
                urls.append(url)
            }
            let url = folder.appendingPathComponent(String(format: "part-%03d.txt", urls.count))
            let source = segmentURL(index)
            // Only the last segment is written to again.
            let linked = position < segments.count - 1 && (try? fileManager.linkItem(at: source, to: url)) != nil
            guard linked || (try? fileManager.copyItem(at: source, to: url)) != nil else { return nil }
            urls.append(url)
        }
        return urls
    }

    func removeAll() {
        try? handle?.close()
        handle = nil
        segments.removeAll()
        sizes.removeAll()
        byteCount = 0
        meta = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    private func segmentURL(_ index: Int) -> URL {
        directory.appendingPathComponent(String(format: "segment-%06d.log", index))
    }

    private static func segmentIndex(_ name: String) -> Int? {
        guard name.hasPrefix("segment-"), name.hasSuffix(".log") else { return nil }
        return Int(name.dropFirst("segment-".count).dropLast(".log".count))
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func marker(_ meta: Meta) -> String {
        "[log truncated: \(meta.droppedLines) lines (\(Self.mb(meta.droppedBytes))) dropped here to stay within \(Self.mb(maxBytes))]"
    }

    /// Where segments were dropped: the position of the first one after missing numbers. Build 32's cap left its gap
    /// after the first 8 MiB, so a log it truncated keeps its gap there.
    private var gap: Int? {
        segments.indices.dropFirst().first { segments[$0] != segments[$0 - 1] + 1 }
    }

    /// The segments that are never dropped: those before the gap, else the leading ones within `headBytes`, at least the
    /// first. Drops are taken right after them, so the gap stays where it is.
    private var headCount: Int {
        if let gap { return gap }
        var count = 0
        var bytes = 0
        for size in sizes {
            guard count == 0 || bytes + size <= headBytes else { break }
            bytes += size
            count += 1
        }
        return count
    }

    private func openSegment() -> FileHandle? {
        if let handle, let size = sizes.last, size < segmentBytes { return handle }
        try? handle?.close()
        handle = nil
        // After a relaunch, carry on in the last segment while it has room.
        if let last = segments.last, let size = sizes.last, size < segmentBytes,
           let reopened = try? FileHandle(forWritingTo: segmentURL(last)) {
            _ = try? reopened.seekToEnd()
            handle = reopened
            return reopened
        }
        let next = (segments.last ?? -1) + 1
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: segmentURL(next).path, contents: nil),
              let opened = try? FileHandle(forWritingTo: segmentURL(next)) else { return nil }
        segments.append(next)
        sizes.append(0)
        handle = opened
        return opened
    }

    private func dropOverflow() {
        guard byteCount > maxBytes else { return }
        let head = headCount
        var dropped = false
        // Never the open segment, which is the last.
        while byteCount > maxBytes, segments.count > head + 1 {
            let url = segmentURL(segments.remove(at: head))
            let size = sizes.remove(at: head)
            if let data = try? Data(contentsOf: url) {
                meta?.droppedLines += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            }
            meta?.droppedBytes += size
            byteCount -= size
            try? FileManager.default.removeItem(at: url)
            dropped = true
        }
        if dropped { saveMeta() }
    }

    private func saveMeta() {
        guard let meta, let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
