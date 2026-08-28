import SwiftUI
import Charts
import LibDCSwift
import LibDCBridge

/// Raw RPC explorer for a connected Suunto Nautic/Ocean device.
///
/// There is no dive list here on purpose: `dc_device_foreach()` cannot
/// enumerate real dives yet (the `/Logbook/Entries` response format is
/// unknown), so this screen instead exposes the raw request/response
/// primitives directly. See `SuuntoNauticExplorer.swift` and
/// `suunto_nautic.h` in the libdivecomputer submodule for what is/isn't
/// understood about this protocol.
struct ExplorerView: View {
    let devicePtr: UnsafeMutablePointer<device_data_t>
    @ObservedObject var bluetoothManager: CoreBluetoothManager

    @State private var customPath: String = "/System/Mode"
    @State private var logbookID: String = ""
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var lastResponse: Data = Data()
    @State private var lastLabel: String = ""
    @State private var shareItems: [Any]?
    @State private var decodedProfile: SuuntoNauticExplorer.DecodedProfile?
    @State private var diveNotes: String = ""

    private static let commonPaths = [
        "/System/Mode",
        "/Logbook/Entries",
        "/Logbook/UnsynchronisedLogs",
    ]

    var body: some View {
        Form {
            Section("Connected") {
                Text(bluetoothManager.connectedDevice?.name ?? "Suunto Nautic/Ocean")
                    .font(.headline)
            }

            Section("Quick Requests") {
                ForEach(Self.commonPaths, id: \.self) { path in
                    Button {
                        sendRequest(path: path)
                    } label: {
                        Label(path, systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(busy)
                }
            }

            Section("Custom GET Request") {
                TextField("/Some/Path", text: $customPath)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Send") {
                    sendRequest(path: customPath)
                }
                .disabled(busy || customPath.isEmpty)
            }

            Section("Download Dive by Logbook ID") {
                TextField("e.g. 1787752091", text: $logbookID)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Download & Decode") {
                    downloadDive(id: logbookID)
                }
                .disabled(busy || logbookID.isEmpty)
                Text("Downloads and decodes depth, temperature, and tank pressure for this dive. Dive events, GPS, and the exact dive date/time aren't decoded yet — see below for how you can help with those.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let profile = decodedProfile {
                Section("Decoded Profile") {
                    LabeledContent("Dive time", value: formatDuration(profile.divetime))
                    LabeledContent("Max depth", value: String(format: "%.1f m", profile.maxDepth))
                    LabeledContent("Avg depth", value: String(format: "%.1f m", profile.avgDepth))
                    if let tmin = profile.temperatureMinimum, let tmax = profile.temperatureMaximum {
                        LabeledContent("Temperature", value: String(format: "%.1f–%.1f °C", tmin, tmax))
                    }
                    ForEach(profile.tanks, id: \.index) { tank in
                        LabeledContent("Tank \(tank.index)", value: String(format: "%.0f → %.0f bar", tank.beginPressure, tank.endPressure))
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

                Section("Help Map the Remaining Data") {
                    Text("Depth/temperature/tank pressure decode. Dive events (alarms, gas switches, laps) and GPS don't yet — we know which numeric chunk IDs carry them, just not what's inside. If anything notable happened on this dive (alarm, gas switch, lap button, low tank warning), describe it below — pairing your notes (or an official Suunto app export of this same dive, if you can get one) with the raw capture is what will actually crack those.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g. \"hit low-tank alarm around 20 min\"", text: $diveNotes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }

            if busy {
                Section {
                    HStack {
                        ProgressView()
                        Text("Working…")
                    }
                }
            }

            if let statusMessage {
                Section("Status") {
                    Text(statusMessage)
                        .font(.footnote)
                }
            }

            if !lastResponse.isEmpty {
                Section("Last Response — \(lastLabel) (\(lastResponse.count) bytes)") {
                    ScrollView {
                        Text(hexDump(lastResponse))
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)

                    Button("Export Raw Capture") {
                        exportCapture()
                    }
                }
            }
        }
        .navigationTitle("Nautic Explorer")
        .sheet(isPresented: Binding(
            get: { shareItems != nil },
            set: { if !$0 { shareItems = nil } }
        )) {
            ActivityView(activityItems: shareItems ?? [])
        }
    }

    private func sendRequest(path: String) {
        busy = true
        statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try SuuntoNauticExplorer.request(device: devicePtr, path: path)
                DispatchQueue.main.async {
                    lastResponse = data
                    lastLabel = "GET \(path)"
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
        busy = true
        statusMessage = nil
        decodedProfile = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try SuuntoNauticExplorer.download(device: devicePtr, logbookID: id)
                let profile = try? SuuntoNauticExplorer.decode(sbemData: data)
                DispatchQueue.main.async {
                    lastResponse = data
                    lastLabel = "Download #\(id)"
                    decodedProfile = profile
                    if profile != nil {
                        statusMessage = "Decoded logbook entry \(id) (\(data.count) bytes)."
                    } else {
                        statusMessage = "Downloaded \(data.count) bytes for \(id), but decoding failed — still worth exporting."
                    }
                    busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = "Download of \(id) failed: \(error)"
                    busy = false
                }
            }
        }
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

    private func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
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
