import Foundation

/// Log lines kept within a byte budget, safe to use from any thread. Once over budget it keeps the first `headBytes` of
/// lines (a download's handshake and dive list) and the newest ones, and drops from between them, where `lines()` and
/// `text()` put a marker that says how much went.
///
/// Sized for a full-logging download (`LibDCLogging.level` `.all`), about 4.3 bytes of log per byte of dive data at
/// 60-byte reads: a real two-dive Suunto Nautic download (1.44 MB of dive data) is 6.0 MB as "HH:mm:ss.SSS [libdc LEVEL]
/// file:line function(): message" lines, about 3 MB a dive. The 32 MiB default holds a full download of about ten.
public final class BoundedLogBuffer: @unchecked Sendable {
    public static let defaultMaxBytes = 32 * 1024 * 1024

    /// The budget: the UTF-8 bytes of the kept lines, a newline each.
    public let maxBytes: Int
    /// How much of the budget the first lines keep once it's reached.
    public let headBytes: Int

    private let lock = NSLock()
    private var head: [String] = []
    private var headSize = 0
    private var headFull = false
    private var tail: [String] = []
    private var tailStart = 0
    private var tailSize = 0
    private var droppedLines = 0
    private var droppedBytes = 0

    /// `headBytes` defaults to a quarter of `maxBytes`; 0 keeps only the newest lines.
    public init(maxBytes: Int = BoundedLogBuffer.defaultMaxBytes, headBytes: Int? = nil) {
        self.maxBytes = max(1, maxBytes)
        self.headBytes = min(self.maxBytes, max(0, headBytes ?? maxBytes / 4))
    }

    public func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(line)
    }

    public func append<S: Sequence>(contentsOf lines: S) where S.Element == String {
        lock.lock(); defer { lock.unlock() }
        for line in lines { appendLocked(line) }
    }

    /// The kept lines, with the marker between the first ones and the newest once any were dropped.
    public func lines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var result = head
        if let marker = markerLocked() { result.append(marker) }
        result.append(contentsOf: tail[tailStart...])
        return result
    }

    /// `lines()`, one per line.
    public func text() -> String {
        lines().joined(separator: "\n")
    }

    /// Kept lines, not counting the marker.
    public var lineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return head.count + tail.count - tailStart
    }

    /// Kept bytes, not counting the marker.
    public var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return headSize + tailSize
    }

    public var droppedLineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedLines
    }

    public var droppedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedBytes
    }

    /// The marker `lines()` would put in, or nil while nothing was dropped.
    public var truncationMarker: String? {
        lock.lock(); defer { lock.unlock() }
        return markerLocked()
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        head.removeAll()
        tail.removeAll()
        headSize = 0
        tailSize = 0
        tailStart = 0
        headFull = false
        droppedLines = 0
        droppedBytes = 0
    }

    private static func size(_ line: String) -> Int { line.utf8.count + 1 }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func markerLocked() -> String? {
        guard droppedLines > 0 else { return nil }
        return "[log truncated: \(droppedLines) lines (\(Self.megabytes(droppedBytes))) dropped here to stay within \(Self.megabytes(maxBytes))]"
    }

    private func appendLocked(_ line: String) {
        let size = Self.size(line)
        if !headFull && headSize + size <= headBytes {
            head.append(line)
            headSize += size
            return
        }
        headFull = true
        tail.append(line)
        tailSize += size
        // The newest line stays even when it alone is over budget.
        while headSize + tailSize > maxBytes && tail.count - tailStart > 1 {
            let dropped = Self.size(tail[tailStart])
            tail[tailStart] = ""
            tailStart += 1
            tailSize -= dropped
            droppedLines += 1
            droppedBytes += dropped
        }
        // Compacted in bulk so dropping stays O(1) a line.
        if tailStart >= 4096 && tailStart * 2 >= tail.count {
            tail.removeFirst(tailStart)
            tailStart = 0
        }
    }
}
