import Foundation

public enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    public var prefix: String {
        switch self {
        case .debug: return "🔍 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARN"
        case .error: return "❌ ERROR"
        }
    }
}

/// A single log event, forwarded to `Logger.onLog` so a host app can relay it to an external
/// system (e.g. Sentry breadcrumbs/events). libdc-swift never transmits anything itself.
public struct LogEvent {
    public let level: LogLevel
    public let message: String
    public let category: String   // originating source file, e.g. "BLEManager.swift"
    public let function: String
    public let timestamp: Date
}

public enum PacketDirection: String {
    case inbound
    case outbound
}

/// A single raw BLE packet, forwarded to `Logger.onPacket` when `shouldShowRawData` is enabled.
/// Distinct from `LogEvent` (human-readable log lines) — this carries the actual bytes so a host
/// app can build real packet-level diagnostics (e.g. attach a capture to a bug report) rather than
/// scraping byte counts out of a formatted message string.
public struct PacketEvent {
    public let direction: PacketDirection
    public let data: Data
    public let characteristicUUID: String
    public let timestamp: Date

    /// Uppercase hex, space-separated, wrapped to 16 bytes per line.
    public var hexDump: String {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 16).map { start in
            bytes[start..<min(start + 16, bytes.count)]
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }
}

public class Logger {
    public static let shared = Logger()
    private var isEnabled = true
    private var minLevel: LogLevel = .debug

    /// Optional sink invoked for every log event. Set this once from the host app to forward
    /// diagnostics to its own telemetry. The closure may be called from background threads, so the
    /// handler must be thread-safe. libdc-swift performs no network/telemetry of its own.
    public var onLog: ((LogEvent) -> Void)?
    /// Optional sink invoked for every raw BLE packet, but only while `shouldShowRawData` is true —
    /// packet capture is opt-in so the byte-level path costs nothing when a host app isn't actively
    /// diagnosing a device. Set this from the host app to build a local packet-trace buffer for a
    /// "send diagnostics" action. May be called from background threads.
    public var onPacket: ((PacketEvent) -> Void)?
    public var shouldShowRawData = false  // Toggle for full hex dumps / onPacket callbacks
    private var dataCounter = 0  // Track number of data packets
    private var totalBytesReceived = 0  // Track total bytes
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    public var minimumLogLevel: LogLevel {
        get { minLevel }
        set { minLevel = newValue }
    }
    
    public func setMinLevel(_ level: LogLevel) {
        minLevel = level
    }
    
    private init() {
        isEnabled = true
        minLevel = .debug
    }
    
    public func log(_ message: String, level: LogLevel = .debug, file: String = #file, function: String = #function) {
        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        let fileName = (file as NSString).lastPathComponent

        // Always print the message during debugging
        print("\(level.prefix) [\(timestamp)] [\(fileName)] \(message)")

        // Forward to the host app's sink (e.g. Sentry) if one is registered.
        onLog?(LogEvent(level: level, message: message, category: fileName, function: function, timestamp: now))
    }
    
    /// Called from `CoreBluetoothManager` for every inbound (`didUpdateValueFor`) and outbound
    /// (`write`) BLE transfer. Byte-count bookkeeping always happens; the `onPacket` callback only
    /// fires while `shouldShowRawData` is on, so a host app pays nothing for this path until it
    /// explicitly opts in (e.g. right before a user taps "send diagnostic logs").
    public func logPacket(direction: PacketDirection, data: Data, characteristicUUID: String) {
        dataCounter += 1
        totalBytesReceived += data.count
        guard shouldShowRawData else { return }
        onPacket?(PacketEvent(direction: direction, data: data, characteristicUUID: characteristicUUID, timestamp: Date()))
    }

    public func setShowRawData(_ show: Bool) {
        shouldShowRawData = show
    }
    
    public func resetDataCounters() {
        dataCounter = 0
        totalBytesReceived = 0
    }

}

// Global convenience functions
public func logDebug(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .debug, file: file, function: function)
}

public func logInfo(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .info, file: file, function: function)
}

public func logWarning(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .warning, file: file, function: function)
}

public func logError(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .error, file: file, function: function)
} 