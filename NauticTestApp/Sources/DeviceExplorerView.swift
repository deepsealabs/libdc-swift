import SwiftUI
import Charts
import LibDCSwift
import LibDCBridge
import Clibdivecomputer

/// Per-device explorer/tester screen, dispatched by the connected device
/// family. Every family shares the generic flow — download dives through the
/// standard `DiveLogRetriever` (dc_device_foreach) and inspect the decoded
/// `DiveData` — while a family that also has a low-level transport worth
/// probing (currently only Suunto Nautic/Ocean) adds its own advanced panel.
struct DeviceExplorerView: View {
    let devicePtr: UnsafeMutablePointer<device_data_t>
    @ObservedObject var bluetoothManager: CoreBluetoothManager
    @StateObject private var viewModel = DiveDataViewModel()

    @State private var family: DeviceConfiguration.DeviceFamily?
    @State private var busy = false
    @State private var statusMessage: String?

    // Suunto Nautic advanced panel state.
    @State private var customPath: String = "/System/Mode"
    @State private var logbookID: String = ""
    @State private var lastResponse: Data = Data()
    @State private var lastLabel: String = ""
    @State private var shareItems: [Any]?
    @State private var decodedProfile: SuuntoNauticExplorer.DecodedProfile?
    @State private var diveNotes: String = ""
    @State private var diveIDs: [UInt32] = []

    private var isNautic: Bool { family == .suuntoNautic }

    private static let commonPaths = [
        "/System/Mode",
        "/Logbook/Entries",
        "/Logbook/UnsynchronisedLogs",
    ]

    var body: some View {
        Form {
            Section("Connected") {
                Text(bluetoothManager.connectedDevice?.name ?? "Dive computer")
                    .font(.headline)
                LabeledContent("Family", value: familyLabel)
            }

            // Generic flow: works for any connected family.
            Section {
                Button {
                    downloadAllDives()
                } label: {
                    Label("Download Dives", systemImage: "square.and.arrow.down")
                }
                .disabled(busy)

                ForEach(Array(viewModel.dives.enumerated()), id: \.offset) { _, dive in
                    NavigationLink {
                        DiveDetailView(dive: dive)
                    } label: {
                        HStack {
                            Text(dive.datetime.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(String(format: "%.1f m", dive.maxDepth))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                if viewModel.dives.isEmpty {
                    Text("Tap Download Dives to enumerate and decode every dive through the standard pipeline.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Text("Dives")
            } footer: {
                Text("Uses dc_device_foreach and the generic parser, so this works for every family this package supports.")
            }

            if isNautic {
                nauticPanel
            }

            if busy {
                Section {
                    HStack { ProgressView(); Text("Working…") }
                }
            }

            if let statusMessage {
                Section("Status") {
                    Text(statusMessage).font(.footnote)
                }
            }
        }
        .navigationTitle("Device Explorer")
        .onAppear(perform: detectFamily)
        .sheet(isPresented: Binding(
            get: { shareItems != nil },
            set: { if !$0 { shareItems = nil } }
        )) {
            ActivityView(activityItems: shareItems ?? [])
        }
    }

    private var familyLabel: String {
        guard let family else { return "detecting…" }
        return isNautic ? "Suunto Nautic/Ocean" : "\(family)"
    }

    // MARK: - Suunto Nautic advanced panel (RPC transport exploration)

    @ViewBuilder
    private var nauticPanel: some View {
        Section("Nautic: Dives by Logbook ID") {
            Button {
                listDives()
            } label: {
                Label("List Dives (RPC)", systemImage: "arrow.clockwise")
            }
            .disabled(busy)

            ForEach(diveIDs, id: \.self) { id in
                Button {
                    logbookID = String(id)
                    downloadDive(id: String(id))
                } label: {
                    HStack {
                        Text(formatDiveDate(id))
                        Spacer()
                        Text(String(id)).font(.caption).foregroundColor(.secondary)
                    }
                }
                .disabled(busy)
            }
        }

        Section("Nautic: Quick Requests") {
            ForEach(Self.commonPaths, id: \.self) { path in
                Button {
                    sendRequest(path: path)
                } label: {
                    Label(path, systemImage: "arrow.up.arrow.down")
                }
                .disabled(busy)
            }
        }

        Section {
            Button {
                captureRaw(path: "/Logbook/Entries")
            } label: {
                Label("Capture raw /Logbook/Entries", systemImage: "ladybug")
            }
            .disabled(busy)
        } header: {
            Text("Nautic: Diagnostics")
        } footer: {
            Text("Fetches the raw /Logbook/Entries frame without decoding it, then use Export Raw Capture below and send us the file. Captures the exact bytes even when listing errors out.")
        }

        Section {
            TextField("/Some/Path", text: $customPath)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Send") { sendRequest(path: customPath) }
                .disabled(busy || customPath.isEmpty)
            Button("Capture raw (this path)") { captureRaw(path: customPath) }
                .disabled(busy || customPath.isEmpty)
        } header: {
            Text("Nautic: Custom GET Request")
        } footer: {
            Text("\"Send\" does a plain GET. \"Capture raw\" does the full fetch and exports the bytes, for probing resources like /Mem/Logbook/Entries.")
        }

        Section("Nautic: Download & Decode by ID") {
            TextField("e.g. 1787752091", text: $logbookID)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Download & Decode") { downloadDive(id: logbookID) }
                .disabled(busy || logbookID.isEmpty)
        }

        if let profile = decodedProfile {
            nauticDecodedProfile(profile)
        }

        if !lastResponse.isEmpty {
            Section("Last Response — \(lastLabel) (\(lastResponse.count) bytes)") {
                ScrollView {
                    Text(hexDump(lastResponse, maxBytes: Self.hexPreviewLimit))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)

                if lastResponse.count > Self.hexPreviewLimit {
                    Text("Showing the first \(Self.hexPreviewLimit) of \(lastResponse.count) bytes. Export the raw capture for the rest.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button("Export Raw Capture") { exportCapture() }
            }
        }
    }

    @ViewBuilder
    private func nauticDecodedProfile(_ profile: SuuntoNauticExplorer.DecodedProfile) -> some View {
        Section("Decoded Profile") {
            if let start = profile.startDate {
                LabeledContent("Date", value: start.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Dive time", value: formatDuration(profile.divetime))
            LabeledContent("Max depth", value: String(format: "%.1f m", profile.maxDepth))
            LabeledContent("Avg depth", value: String(format: "%.1f m", profile.avgDepth))
            if let low = profile.gradientFactorLow, let high = profile.gradientFactorHigh {
                LabeledContent("Gradient factors", value: "\(low)/\(high)")
            }
            ForEach(profile.tanks, id: \.index) { tank in
                LabeledContent("Tank \(tank.index)", value: String(format: "%.0f → %.0f bar", tank.beginPressure, tank.endPressure))
            }
        }

        if !profile.events.isEmpty {
            Section("Dive Events (\(profile.events.count))") {
                ForEach(Array(profile.events.enumerated()), id: \.offset) { _, event in
                    HStack {
                        Text(event.label)
                        Spacer()
                        Text(formatDuration(event.time)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }

        if !profile.depthProfile.isEmpty {
            Section("Depth Profile") {
                Chart(profile.depthProfile, id: \.time) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value("Depth", sample.depth))
                }
                .chartYScale(domain: .automatic(reversed: true))
                .frame(height: 180)
            }
        }
    }

    // MARK: - Generic download

    private func downloadAllDives() {
        guard let peripheral = bluetoothManager.connectedDevice else {
            statusMessage = "No connected device."
            return
        }
        busy = true
        statusMessage = "Downloading dives…"
        DiveLogRetriever.retrieveDiveLogs(
            from: devicePtr,
            device: peripheral,
            viewModel: viewModel,
            bluetoothManager: bluetoothManager
        ) { success in
            DispatchQueue.main.async {
                busy = false
                statusMessage = success
                    ? "Downloaded \(viewModel.dives.count) dive(s)."
                    : "Download failed: \(viewModel.status)"
            }
        }
    }

    private func detectFamily() {
        guard family == nil, let name = bluetoothManager.connectedDevice?.name else { return }
        var dcFamily = DC_FAMILY_NULL
        var dcModel: UInt32 = 0
        if get_device_info_from_name(name, &dcFamily, &dcModel) == DC_STATUS_SUCCESS {
            family = DeviceConfiguration.DeviceFamily(dcFamily: dcFamily)
        }
    }

    // MARK: - Suunto Nautic RPC primitives (transport is Suunto-specific)

    private func listDives() {
        busy = true; statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ids = try SuuntoNauticExplorer.listDives(device: devicePtr)
                DispatchQueue.main.async {
                    diveIDs = ids
                    statusMessage = "Found \(ids.count) dive(s)."
                    busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = "Listing dives failed: \(error)"
                    busy = false
                }
            }
        }
    }

    private func formatDiveDate(_ id: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(id))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func captureRaw(path: String) {
        busy = true; statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try SuuntoNauticExplorer.fetchRaw(device: devicePtr, path: path)
                DispatchQueue.main.async {
                    lastResponse = data
                    lastLabel = "RAW \(path)"
                    statusMessage = "Captured \(data.count) raw bytes for \(path). Tap Export Raw Capture below and send us the file."
                    busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = "Raw capture for \(path) failed: \(error)"
                    busy = false
                }
            }
        }
    }

    private func sendRequest(path: String) {
        let needsFetch = path == "/Logbook/Entries" || path == "/Logbook/UnsynchronisedLogs"
        busy = true; statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = needsFetch
                    ? try SuuntoNauticExplorer.fetch(device: devicePtr, path: path)
                    : try SuuntoNauticExplorer.request(device: devicePtr, path: path)
                DispatchQueue.main.async {
                    lastResponse = data
                    lastLabel = "\(needsFetch ? "FETCH" : "GET") \(path)"
                    statusMessage = "Received \(data.count) bytes for \(path)."
                    busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = "Request for \(path) failed: \(error)"
                    busy = false
                }
            }
        }
    }

    private func downloadDive(id: String) {
        busy = true; statusMessage = nil; decodedProfile = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try SuuntoNauticExplorer.download(device: devicePtr, logbookID: id)
                let profile = try? SuuntoNauticExplorer.decode(sbemData: data, logbookID: UInt32(id))
                DispatchQueue.main.async {
                    lastResponse = data
                    lastLabel = "Download #\(id)"
                    decodedProfile = profile
                    statusMessage = profile != nil
                        ? "Decoded logbook entry \(id) (\(data.count) bytes)."
                        : "Downloaded \(data.count) bytes for \(id), but decoding failed — still worth exporting."
                    busy = false
                }
            } catch {
                let msg = describeDownloadFailure(id: id, error: error)
                DispatchQueue.main.async {
                    statusMessage = msg
                    busy = false
                }
            }
        }
    }

    private func describeDownloadFailure(id: String, error: Error) -> String {
        var statusText = "\(error)"
        if case SuuntoNauticExplorer.ExplorerError.requestFailed(let st) = error {
            statusText = "status \(st.rawValue)"
        }
        func probe(_ name: String) -> String {
            let path = "/Logbook/byId/\(id)/\(name)"
            if let data = try? SuuntoNauticExplorer.fetch(device: devicePtr, path: path), !data.isEmpty {
                return "\(name): \(data.count) B"
            }
            return "\(name): unavailable"
        }
        let summary = probe("Summary")
        let descriptors = probe("Descriptors")
        let dataGone = statusText.contains("-9") || statusText.contains("-8")
        let lead = dataGone
            ? "Dive #\(id): raw profile (/Data) unavailable (\(statusText)). If this is an older dive, its raw data has been overwritten on the watch and is no longer downloadable over Bluetooth — only the most recent dives stay available."
            : "Download of \(id) failed: \(statusText)."
        return "\(lead)\nPer-resource: /Data unavailable, \(summary), \(descriptors)."
    }

    private func exportCapture() {
        let base = "suunto_nautic_\(lastLabel.replacingOccurrences(of: "/", with: "_"))"
        let binURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).bin")
        do {
            try lastResponse.write(to: binURL)
        } catch {
            statusMessage = "Failed to write export file: \(error)"
            return
        }

        var items: [Any] = [binURL]
        if !diveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(base)_notes.txt")
            let contents = "Notes for \(lastLabel):\n\(diveNotes)\n"
            if (try? contents.write(to: notesURL, atomically: true, encoding: .utf8)) != nil {
                items.append(notesURL)
            }
        }
        shareItems = items
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let hexPreviewLimit = 2048

    private func hexDump(_ data: Data, maxBytes: Int = .max) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data.prefix(maxBytes))
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset..<end]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            let offsetStr = String(format: "%04X", offset)
            lines.append("\(offsetStr)  \(hex.padding(toLength: 47, withPad: " ", startingAt: 0))  \(ascii)")
            offset = end
        }
        return lines.joined(separator: "\n")
    }
}

/// Generic decoded-dive detail, driven entirely by the standard `DiveData`
/// the generic parser produces, so it renders for any device family.
private struct DiveDetailView: View {
    let dive: DiveData

    var body: some View {
        Form {
            Section("Summary") {
                LabeledContent("Date", value: dive.datetime.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Dive time", value: formatDuration(dive.divetime))
                LabeledContent("Max depth", value: String(format: "%.1f m", dive.maxDepth))
                LabeledContent("Avg depth", value: String(format: "%.1f m", dive.avgDepth))
                if let tmin = dive.minTemperature, let tmax = dive.maxTemperature {
                    LabeledContent("Temperature", value: String(format: "%.1f–%.1f °C", tmin, tmax))
                }
                if let deco = dive.decoModel, let low = deco.gfLow, let high = deco.gfHigh {
                    LabeledContent("Gradient factors", value: "\(low)/\(high)")
                }
            }

            if let tanks = dive.tanks, !tanks.isEmpty {
                Section("Tanks") {
                    ForEach(Array(tanks.enumerated()), id: \.offset) { idx, tank in
                        LabeledContent("Tank \(idx)", value: String(format: "%.0f → %.0f bar", tank.beginPressure, tank.endPressure))
                    }
                }
            }

            if let gases = dive.gasMixes, !gases.isEmpty {
                Section("Gas Mixes") {
                    ForEach(Array(gases.enumerated()), id: \.offset) { idx, gas in
                        let o2 = Int((gas.oxygen * 100).rounded()), he = Int((gas.helium * 100).rounded())
                        LabeledContent("Gas \(idx + 1)", value: he > 0 ? "O₂ \(o2)% / He \(he)%" : "O₂ \(o2)%")
                    }
                }
            }

            let events = diveEvents
            if !events.isEmpty {
                Section("Dive Events (\(events.count))") {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        HStack {
                            Text(e.label)
                            Spacer()
                            Text(formatDuration(e.time)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }

            if !dive.profile.isEmpty {
                Section("Depth Profile") {
                    Chart(Array(dive.profile.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.time), y: .value("Depth", point.depth))
                    }
                    .chartYScale(domain: .automatic(reversed: true))
                    .frame(height: 180)
                }
            }

            if !vendorKindCounts.isEmpty {
                Section("Vendor Samples") {
                    ForEach(vendorKindCounts, id: \.kind) { row in
                        LabeledContent("Kind \(row.kind)", value: "\(row.count)")
                    }
                    Text("Non-standard series delivered through the generic DC_SAMPLE_VENDOR channel.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(dive.datetime.formatted(date: .abbreviated, time: .shortened))
    }

    private var diveEvents: [(time: TimeInterval, label: String)] {
        dive.profile.flatMap { point in
            point.events.map { (point.time, String(describing: $0)) }
        }
    }

    private var vendorKindCounts: [(kind: UInt8, count: Int)] {
        Dictionary(grouping: dive.vendorSamples.compactMap { $0.data.first }, by: { $0 })
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.kind < $1.kind }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#if os(iOS)
import UIKit

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
