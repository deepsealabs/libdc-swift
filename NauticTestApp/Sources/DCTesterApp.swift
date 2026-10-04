import SwiftUI
import LibDCSwift

@main
struct DCTesterApp: App {
    // Created at launch so a background relaunch through BLE state restoration resumes auto download.
    @StateObject private var autoDownload = AutoDownloadController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(autoDownload)
        }
    }
}
