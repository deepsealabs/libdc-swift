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

/// The Explorer's connects, commands and results, kept for pasting into a GitHub issue. Safe from any thread: the
/// libdivecomputer sink appends from the download thread, where a full log's many lines a second would swamp main.
final class ExplorerLog: ObservableObject {
    static let shared = ExplorerLog(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])

    /// Main thread; trails appends by up to `publishDelay`.
    @Published private(set) var lineCount = 0

    // A full log's whole copy is on disk in `fullLog`, so memory only keeps a window of it.
    private let buffer = BoundedLogBuffer(maxBytes: 4 * 1024 * 1024)
    private let lock = NSLock()
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

    private static let restoredLines = 500
    private static let maxFileBytes = 4 * 1024 * 1024
    private static let publishDelay = 0.25
    private let file: URL
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(directory: URL) {
        file = directory.appendingPathComponent("explorer.log")
        fullLog = FullLogStore(directory: directory.appendingPathComponent("full-log"))
        let restored = Self.lastLines(of: file, count: Self.restoredLines)
        buffer.append(contentsOf: restored)
        recentlyWritten = restored
        fileBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        fullLoggingSince = fullLog.meta?.since
        lastDevice = fullLog.meta?.device
        _lineCount = Published(initialValue: buffer.lineCount)
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
        }
        lock.unlock()
        lineCount = 0
    }

    var usedFullLogging: Bool {
        lock.lock(); defer { lock.unlock() }
        return fullLoggingSince != nil
    }

    /// The lines kept in memory; for a full log, only its newest (Share log has all of it).
    func text(device: String? = nil) -> String {
        memoryText(device: device, fullLogNote: "Newest lines only: Share log has the whole full log.")
    }

    /// What Share log hands the share sheet, on main: the text, or once full logging was on, the full log as a .txt file.
    func shareItems(device: String? = nil, completion: @escaping ([Any]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let item = shareItem(device: device)
            DispatchQueue.main.async { completion([item]) }
        }
    }

    /// Blocks on the file queue, so call it off main. A full log comes from disk, all of it, across relaunches.
    func shareItem(device: String? = nil) -> Any {
        lock.lock()
        flushLocked()
        let full = fullLoggingSince != nil
        lock.unlock()
        guard full else { return text(device: device) }
        let header = headerLines(device: device).joined(separator: "\n") + "\n"
        let url = shareURL()
        let exported = fileQueue.sync { fullLog.export(to: url, header: header) }
        return exported ? url : memoryText(device: device, fullLogNote: "The full log file couldn't be written, so newest lines only.")
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
            since.map { "Full logging ON (DC_LOGLEVEL_ALL) from \(Self.dateTime.string(from: $0)): \(versions)" }
                ?? "Full logging off: \(versions)",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "Device: \(device ?? "none")",
            ""
        ]
    }

    private func shareURL() -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("DC-Tester-\(build)-full-log-\(stamp.string(from: Date())).txt")
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
        let line = "\(Self.timestamp.string(from: Date())) \(text)"
        buffer.append(line)
        unwritten.append(line)
        if fullLoggingSince != nil { unwrittenFull.append(line) }
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay) { [self] in publish() }
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

/// A full log on disk, so a crash, an eviction or a relaunch doesn't lose it. Lines go into segment files; past
/// `maxBytes` it keeps the first quarter's segments (the handshake and dive list) and the newest, as `BoundedLogBuffer`
/// does, with a marker where it dropped some. Not thread-safe: `ExplorerLog` uses it on its file queue.
final class FullLogStore {
    struct Meta: Codable {
        var since: Date
        var device: String?
        var droppedLines = 0
        var droppedBytes = 0
    }

    private(set) var meta: Meta?
    let maxBytes: Int
    private let directory: URL
    private let segmentBytes: Int
    private let maxSegments: Int
    private let headSegments: Int
    private var segments: [Int] = []
    private var handle: FileHandle?
    private var currentBytes = 0

    init(directory: URL, maxBytes: Int = BoundedLogBuffer.defaultMaxBytes, segmentBytes: Int = 4 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.segmentBytes = max(1, segmentBytes)
        maxSegments = max(2, maxBytes / self.segmentBytes)
        headSegments = maxSegments / 4
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        self.meta = meta
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        segments = names.compactMap(Self.segmentIndex).sorted()
        if let last = segments.last {
            currentBytes = (try? FileManager.default.attributesOfItem(atPath: segmentURL(last).path)[.size] as? Int) ?? 0
        }
    }

    /// Starts a new full log, replacing any earlier one.
    func start(since: Date, device: String?, seed: [String]) {
        removeAll()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        meta = Meta(since: since, device: device)
        saveMeta()
        append(seed)
    }

    func append(_ lines: [String]) {
        guard meta != nil, !lines.isEmpty, let handle = openSegment() else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard (try? handle.write(contentsOf: data)) != nil else { return }
        currentBytes += data.count
    }

    func setDevice(_ device: String) {
        guard meta != nil, meta?.device != device else { return }
        meta?.device = device
        saveMeta()
    }

    /// Writes `header`, then the kept lines, to `url`.
    func export(to url: URL, header: String) -> Bool {
        guard let meta,
              FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)),
              let out = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? out.close() }
        do {
            _ = try out.seekToEnd()
            for (position, index) in segments.enumerated() {
                if position == headSegments, meta.droppedLines > 0 {
                    try out.write(contentsOf: Data((marker(meta) + "\n").utf8))
                }
                guard let data = try? Data(contentsOf: segmentURL(index), options: .mappedIfSafe) else { continue }
                try out.write(contentsOf: data)
            }
            return true
        } catch {
            return false
        }
    }

    func removeAll() {
        try? handle?.close()
        handle = nil
        segments.removeAll()
        currentBytes = 0
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

    private func marker(_ meta: Meta) -> String {
        let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return "[log truncated: \(meta.droppedLines) lines (\(mb(meta.droppedBytes))) dropped here to stay within \(mb(maxBytes))]"
    }

    private func openSegment() -> FileHandle? {
        if let handle, currentBytes < segmentBytes { return handle }
        try? handle?.close()
        handle = nil
        // After a relaunch, carry on in the last segment while it has room.
        if let last = segments.last, currentBytes < segmentBytes,
           let reopened = try? FileHandle(forWritingTo: segmentURL(last)) {
            _ = try? reopened.seekToEnd()
            handle = reopened
            return reopened
        }
        let next = (segments.last ?? -1) + 1
        guard FileManager.default.createFile(atPath: segmentURL(next).path, contents: nil) else { return nil }
        segments.append(next)
        currentBytes = 0
        dropOverflow()
        handle = try? FileHandle(forWritingTo: segmentURL(next))
        return handle
    }

    private func dropOverflow() {
        guard segments.count > maxSegments else { return }
        while segments.count > maxSegments {
            let url = segmentURL(segments.remove(at: headSegments))
            if let data = try? Data(contentsOf: url) {
                meta?.droppedLines += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                meta?.droppedBytes += data.count
            }
            try? FileManager.default.removeItem(at: url)
        }
        saveMeta()
    }

    private func saveMeta() {
        guard let meta, let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
