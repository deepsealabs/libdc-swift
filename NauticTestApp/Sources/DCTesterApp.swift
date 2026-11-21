import SwiftUI
import LibDCSwift

@main
struct DCTesterApp: App {
    // Created at launch so a background relaunch through BLE state restoration resumes auto download.
    @StateObject private var autoDownload = AutoDownloadController()

    init() {
        FullLogging.applySaved()
        // libdivecomputer's lines into Share log, so a tester's log says why a download failed (e.g. "Invalid logbook
        // end pointer"), not just the status code; at full logging, every byte too. Appended here, on the download's thread.
        set_libdc_log_sink { level, message in
            let line = "[libdc \(level.map { String(cString: $0) } ?? "?")] \(message.map { String(cString: $0) } ?? "")"
            // The parser runs twice on a dive it rejects (for the date, then the samples), so its line comes twice.
            ExplorerLog.shared.appendUnlessRepeated(line)
        }
        // LibDCSwift's own lines too, such as which dive a parser line was about, and what was skipped.
        Logger.shared.onLog = { event in
            let level: String
            switch event.level {
            case .debug:
                guard FullLogging.isOn else { return }
                level = "DEBUG"
            case .info: level = "INFO"
            case .warning: level = "WARN"
            case .error: level = "ERROR"
            }
            ExplorerLog.shared.append("[LibDCSwift \(level)] \(event.message)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(autoDownload)
        }
    }
}
