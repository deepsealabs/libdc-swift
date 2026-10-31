import SwiftUI
import LibDCSwift

@main
struct DCTesterApp: App {
    // Created at launch so a background relaunch through BLE state restoration resumes auto download.
    @StateObject private var autoDownload = AutoDownloadController()

    init() {
        // libdivecomputer's ERROR/WARN/INFO lines into Share log, so a tester's log says why a
        // download failed (e.g. "Invalid logbook end pointer"), not just the status code.
        set_libdc_log_sink { level, message in
            let line = "[libdc \(level.map { String(cString: $0) } ?? "?")] \(message.map { String(cString: $0) } ?? "")"
            DispatchQueue.main.async { ExplorerLog.shared.append(line) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(autoDownload)
        }
    }
}
