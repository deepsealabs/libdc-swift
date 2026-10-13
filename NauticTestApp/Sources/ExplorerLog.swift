import SwiftUI
import UIKit
import LibDCSwift

/// The Explorer's connects, commands and results, kept for pasting into a GitHub issue. Main thread only.
final class ExplorerLog: ObservableObject {
    static let shared = ExplorerLog()

    @Published private(set) var lines: [String] = []

    private static let maxLines = 3000
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("explorer.log")
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        if let saved = try? String(contentsOf: file, encoding: .utf8) {
            lines = saved.split(separator: "\n").suffix(500).map(String.init)
        }
    }

    func append(_ text: String) {
        let line = "\(Self.timestamp.string(from: Date())) \(text)"
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: file)
    }

    func text(device: String?) -> String {
        let header = [
            "DC Tester \(AutoDownloadController.appVersion) explorer log",
            "LibDCSwift \(libDCSwiftBuildTag)",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "Device: \(device ?? "none")",
            ""
        ]
        return (header + lines).joined(separator: "\n")
    }
}
