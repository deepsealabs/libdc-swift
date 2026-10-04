import SwiftUI
import UIKit
import LibDCSwift

/// Owns the one `NauticAutoSync` DC Tester runs, its live log and the dives it pulled. Main thread only.
final class AutoDownloadController: ObservableObject, NauticAutoSyncDelegate {
    struct LogLine: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    struct Dive: Identifiable {
        var id: UInt32 { logbookID }
        let logbookID: UInt32
        let data: Data
        let isComplete: Bool
        let attempts: Int
        let profile: SuuntoNauticExplorer.DecodedProfile?
    }

    @Published private(set) var deviceName: String?
    @Published private(set) var state: NauticAutoSync.State = .stopped
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var dives: [Dive] = []
    /// Set when a connect timed out; cleared once the watch is connected again.
    @Published private(set) var unreachableHint: String?

    private var autoSync: NauticAutoSync?
    private let defaults = UserDefaults.standard
    private static let enabledKey = "dctester.autoDownload.device"
    private static let maxLines = 3000
    private let logFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("auto-download.log")

    init() {
        if let saved = try? String(contentsOf: logFile, encoding: .utf8) {
            log = saved.split(separator: "\n").suffix(500).map { LogLine(date: .distantPast, text: String($0)) }
        }
        // Resume after a relaunch (including a background relaunch through BLE state restoration).
        if let name = defaults.string(forKey: Self.enabledKey), let device = Self.storedDevice(named: name) {
            start(device)
        }
    }

    var isActive: Bool { deviceName != nil }

    func isEnabled(for device: StoredDevice) -> Bool { deviceName == device.name }

    static var nauticDevices: [StoredDevice] {
        (DeviceStorage.shared.getAllStoredDevices() ?? []).filter { $0.family == .suuntoNautic }
    }

    static func storedDevice(named name: String) -> StoredDevice? {
        nauticDevices.first { $0.name == name }
    }

    func setEnabled(_ enabled: Bool, for device: StoredDevice) {
        if enabled {
            start(device)
        } else if deviceName == device.name {
            stop()
        }
    }

    private func start(_ device: StoredDevice) {
        autoSync?.stop()
        // The auto-download session needs the link to itself; close() cancels the old link after a delay, so let that land first.
        let manager = CoreBluetoothManager.sharedManager
        let closedManualSession = manager.openedDeviceDataPtr != nil
        if closedManualSession {
            manager.close(clearDevicePtr: true)
        }

        let sync = NauticAutoSync(deviceKey: device.name, connector: CoreBluetoothNauticConnector(storedDevice: device))
        sync.delegate = self
        sync.onDive = { _ in }
        autoSync = sync
        deviceName = device.name
        defaults.set(device.name, forKey: Self.enabledKey)
        append("Auto download ON for \(device.name) (DC Tester \(Self.appVersion), LibDCSwift \(libDCSwiftBuildTag))")
        if closedManualSession {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak sync] in sync?.start() }
        } else {
            sync.start()
        }
    }

    func stop() {
        autoSync?.stop()
        autoSync = nil
        if let deviceName { append("Auto download OFF for \(deviceName)") }
        deviceName = nil
        state = .stopped
        defaults.removeObject(forKey: Self.enabledKey)
    }

    func syncNow() {
        append("Sync now requested")
        autoSync?.syncNow()
    }

    func simulateDrop() {
        autoSync?.simulateDrop()
    }

    func markExistingAsSynced() {
        append("Skip dives already on the watch requested")
        autoSync?.markExistingAsSynced()
    }

    func resetSynced() {
        append("Forget downloaded dives requested")
        autoSync?.resetSynced()
    }

    func clearLog() {
        log.removeAll()
        try? FileManager.default.removeItem(at: logFile)
    }

    /// Plain text for pasting into a GitHub issue.
    var logText: String {
        let header = [
            "DC Tester \(Self.appVersion) auto download log",
            "LibDCSwift \(libDCSwiftBuildTag)",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "Watch: \(deviceName ?? "none")",
            "State: \(Self.describe(state))",
            "Downloaded this session: \(dives.count) (\(dives.filter { !$0.isComplete }.count) incomplete)",
            ""
        ]
        return (header + log.map(\.text)).joined(separator: "\n")
    }

    func autoSync(_ sender: NauticAutoSync, didEmit event: NauticAutoSync.Event) {
        guard sender === autoSync else { return }
        switch event {
        case .state(let newState):
            state = newState
            switch newState {
            case .listing, .downloading, .watching, .watchBusy, .stopped: unreachableHint = nil
            default: break
            }
            append("State: \(Self.describe(newState))")
        case .log(let message):
            append(message)
        case .dive(let dive):
            let profile = try? SuuntoNauticExplorer.decode(sbemData: dive.data, logbookID: dive.id)
            dives.insert(Dive(logbookID: dive.id, data: dive.data, isComplete: dive.isComplete,
                              attempts: dive.attempts, profile: profile), at: 0)
            let summary = profile.map { String(format: "%.1f m, %@", $0.maxDepth, Self.duration($0.divetime)) } ?? "not decodable"
            append("Downloaded dive \(dive.id) (\(dive.data.count) bytes, \(dive.isComplete ? "complete" : "INCOMPLETE"), attempt \(dive.attempts)): \(summary)")
        case .diveFailed(let id, let reason):
            append("Dive \(id) failed: \(reason)")
        case .watchUnreachable:
            unreachableHint = "Watch not reachable. It may be asleep: press a button on the watch."
        case .syncCompleted(let summary):
            append("Sync done: \(summary.downloaded.count) new of \(summary.listed) on the watch" +
                   (summary.failed.isEmpty ? "" : ", failed: \(summary.failed.map(String.init).joined(separator: ", "))"))
        }
    }

    private func append(_ text: String) {
        let stamp = Self.timestamp.string(from: Date())
        let line = "\(stamp) \(text)"
        log.append(LogLine(date: Date(), text: line))
        if log.count > Self.maxLines { log.removeFirst(log.count - Self.maxLines) }
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    static func describe(_ state: NauticAutoSync.State) -> String {
        switch state {
        case .stopped: return "off"
        case .waitingForDevice: return "scanning for the watch"
        case .connecting(let attempt): return attempt > 1 ? "connecting (attempt \(attempt))" : "connecting"
        case .listing: return "listing dives"
        case .downloading(let index, let total, let id): return "downloading \(index) of \(total) (dive \(id))"
        case .watching: return "connected, waiting for new dives"
        case .watchBusy: return "connected, watch busy"
        case .reconnecting(let attempt, let delay): return "reconnecting (attempt \(attempt), in \(Int(delay)) s)"
        case .coolingDown(let until): return "paused after repeated failures, retrying at \(until.formatted(date: .omitted, time: .shortened))"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Toggle row for a stored watch, used on the device list and the device screen.
struct AutoDownloadToggle: View {
    let device: StoredDevice
    @ObservedObject var controller: AutoDownloadController

    var body: some View {
        Toggle(isOn: Binding(
            get: { controller.isEnabled(for: device) },
            set: { controller.setEnabled($0, for: device) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto download").font(.headline)
                Text(controller.isEnabled(for: device)
                     ? controller.unreachableHint ?? AutoDownloadController.describe(controller.state).capitalizingFirstLetter
                     : device.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct AutoDownloadView: View {
    @ObservedObject var controller: AutoDownloadController
    @State private var shareItems: [Any]?
    @State private var autoScroll = true

    var body: some View {
        Form {
            Section("Status") {
                Text(AutoDownloadController.describe(controller.state).capitalizingFirstLetter)
                    .font(.headline)
                if let hint = controller.unreachableHint {
                    Label(hint, systemImage: "hand.tap")
                        .font(.callout)
                        .foregroundColor(.orange)
                }
                if let name = controller.deviceName {
                    LabeledContent("Watch", value: name)
                }
                Button {
                    shareItems = [controller.logText]
                } label: {
                    Label("Share log", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = controller.logText
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                }
            }

            Section {
                Button("Sync now") { controller.syncNow() }
                Button("Simulate link drop") { controller.simulateDrop() }
                Button("Skip dives already on the watch") { controller.markExistingAsSynced() }
                Button("Forget downloaded dives", role: .destructive) { controller.resetSynced() }
            } header: {
                Text("Actions")
            } footer: {
                Text("Simulate link drop cuts the Bluetooth link the way walking out of range would, to check that the download reconnects and carries on. Forget downloaded dives makes the next sync download every dive on the watch again.")
            }
            .disabled(!controller.isActive)

            if !controller.dives.isEmpty {
                Section("Downloaded (\(controller.dives.count))") {
                    ForEach(controller.dives) { dive in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Date(timeIntervalSince1970: TimeInterval(dive.logbookID))
                                    .formatted(date: .abbreviated, time: .shortened))
                                Text("\(dive.data.count) bytes\(dive.attempts > 1 ? ", \(dive.attempts) attempts" : "")")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if let profile = dive.profile {
                                Text(String(format: "%.1f m  %@", profile.maxDepth, AutoDownloadController.duration(profile.divetime)))
                                    .font(.caption)
                            }
                            if !dive.isComplete {
                                Text("incomplete").font(.caption).foregroundColor(.orange)
                            }
                        }
                        .contextMenu {
                            Button("Export raw capture") { shareItems = [rawFile(dive)].compactMap { $0 } }
                        }
                    }
                }
            }

            Section {
                Toggle("Follow new lines", isOn: $autoScroll)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(controller.log) { line in
                                Text(line.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                    }
                    .frame(height: 320)
                    .onChange(of: controller.log.count) { _ in
                        if autoScroll, let last = controller.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Button("Clear log", role: .destructive) { controller.clearLog() }
            } header: {
                Text("Live log")
            }
        }
        .navigationTitle("Auto Download")
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(activityItems: shareItems ?? [])
        }
    }

    private func rawFile(_ dive: AutoDownloadController.Dive) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suunto_nautic_Auto.\(dive.logbookID).bin")
        return (try? dive.data.write(to: url)) != nil ? url : nil
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
