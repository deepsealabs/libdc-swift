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

    static let footer = "Records everything sent to and from the watch, from the next connection on. Logs get big and include the watch's serial number and dive data, so share them privately (email) if you prefer."
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
    static let shared = ExplorerLog()

    /// Main thread; trails appends by up to `publishDelay`.
    @Published private(set) var lineCount = 0

    private let buffer = BoundedLogBuffer()
    private let lock = NSLock()
    private var lastText: String?
    private var lastDevice: String?
    private var fullLoggingSince: Date?
    private var publishScheduled = false
    private var unwritten: [String] = []

    // The file only brings back the last lines after a relaunch; touched on fileQueue only.
    private let fileQueue = DispatchQueue(label: "dctester.explorer-log.file")
    private var handle: FileHandle?
    private var fileBytes = 0
    private var recentlyWritten: [String] = []

    private static let restoredLines = 500
    private static let maxFileBytes = 4 * 1024 * 1024
    private static let publishDelay = 0.25
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("explorer.log")
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let restored = Self.lastLines(of: file, count: Self.restoredLines)
        buffer.append(contentsOf: restored)
        recentlyWritten = restored
        fileBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        _lineCount = Published(initialValue: buffer.lineCount)
    }

    func append(_ text: String) {
        lock.lock()
        appendLocked(text)
        lock.unlock()
    }

    /// Leaves out a line the same as the one just before it.
    func appendUnlessRepeated(_ text: String) {
        lock.lock()
        if text != lastText { appendLocked(text) }
        lock.unlock()
    }

    /// Logs a connection starting; one that starts at full logging marks the log as a full one.
    func noteConnection(_ text: String, device: String) {
        let full = LibDCLogging.level.rawValue >= LibDCLogLevel.debug.rawValue
        lock.lock()
        lastDevice = device
        if full && fullLoggingSince == nil { fullLoggingSince = Date() }
        appendLocked(full ? "\(text) (full logging)" : text)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lastText = nil
        fullLoggingSince = nil
        unwritten.removeAll()
        buffer.removeAll()
        lock.unlock()
        lineCount = 0
        fileQueue.async { [self] in
            try? handle?.close()
            handle = nil
            fileBytes = 0
            recentlyWritten.removeAll()
            try? FileManager.default.removeItem(at: file)
        }
    }

    var usedFullLogging: Bool {
        lock.lock(); defer { lock.unlock() }
        return fullLoggingSince != nil
    }

    func text(device: String? = nil) -> String {
        lock.lock()
        let since = fullLoggingSince
        let device = device ?? lastDevice
        lock.unlock()
        let versions = "DC Tester \(AutoDownloadController.appVersion), LibDCSwift \(libDCSwiftBuildTag), libdivecomputer \(LibDCLogging.libdivecomputerVersion)"
        let header = [
            "DC Tester \(AutoDownloadController.appVersion) explorer log",
            since.map { "Full logging was ON (DC_LOGLEVEL_ALL) from \(Self.timestamp.string(from: $0)): \(versions)" }
                ?? "Full logging off: \(versions)",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "Device: \(device ?? "none")",
            ""
        ]
        return (header + buffer.lines()).joined(separator: "\n")
    }

    /// What Share log hands the share sheet, on main: the text, or a .txt file once full logging made it big.
    func shareItems(device: String? = nil, completion: @escaping ([Any]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let text = text(device: device)
            let item: Any = usedFullLogging ? (shareFile(text) ?? text) : text
            DispatchQueue.main.async { completion([item]) }
        }
    }

    private func shareFile(_ text: String) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DC-Tester-\(build)-full-log-\(stamp.string(from: Date())).txt")
        return (try? Data(text.utf8).write(to: url)) != nil ? url : nil
    }

    private func appendLocked(_ text: String) {
        lastText = text
        let line = "\(Self.timestamp.string(from: Date())) \(text)"
        buffer.append(line)
        unwritten.append(line)
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay) { [self] in publish() }
    }

    private func publish() {
        lock.lock()
        publishScheduled = false
        let lines = unwritten
        unwritten.removeAll()
        lock.unlock()
        lineCount = buffer.lineCount
        guard !lines.isEmpty else { return }
        fileQueue.async { [self] in write(lines) }
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
        // Cut back to what a relaunch restores, so a full log can't grow the file without bound.
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
