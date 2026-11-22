import SwiftUI
import CoreBluetooth
import LibDCSwift
import LibDCBridge
import Clibdivecomputer

struct ContentView: View {
    private enum Screen: Hashable {
        case explorer
        case autoDownload
    }

    @StateObject private var bluetoothManager = CoreBluetoothManager.sharedManager
    @EnvironmentObject private var autoDownload: AutoDownloadController
    // One path: a pop and a push on two isPresented destinations in the same update draw a blank page.
    @State private var path: [Screen] = []

    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var connectingPeripheralID: UUID?
    // Set only once an open succeeds: before that, the manager may still hold another watch's device.
    @State private var explorerDeviceName: String?
    @State private var shareItems: [Any]?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                experimentalBanner

                List {
                    autoDownloadSection

                    Section {
                        if bluetoothManager.discoveredPeripherals.isEmpty {
                            Text(bluetoothManager.isScanning
                                 ? "Scanning… A watch that has been idle for a while may need a button press before it shows up."
                                 : "No devices found yet.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(bluetoothManager.discoveredPeripherals, id: \.identifier) { peripheral in
                            deviceRow(peripheral)
                        }
                    } header: {
                        Text("Discovered Devices")
                    } footer: {
                        Text(autoDownload.isActive
                             ? "Turn auto download off to connect manually; it holds the Bluetooth link while it runs."
                             : "Looking for BLE service 61353090-8231-49cc-b57a-886370740041 (Suunto Nautic/Ocean) alongside every other dive computer this package recognizes.")
                    }

                    if let connectError {
                        Section {
                            Text(connectError)
                                .foregroundColor(.red)
                                .font(.footnote)
                        }
                    }

                    logSection
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("DC Tester")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bluetoothManager.isScanning ? "Stop" : "Scan") {
                        if bluetoothManager.isScanning {
                            bluetoothManager.stopScanning()
                        } else {
                            connectError = nil
                            bluetoothManager.clearDiscoveredPeripherals()
                            bluetoothManager.startScanning(omitUnsupportedPeripherals: false)
                        }
                    }
                }
            }
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .explorer:
                    if let devicePtr = bluetoothManager.openedDeviceDataPtr, let explorerDeviceName {
                        DeviceExplorerView(devicePtr: devicePtr, deviceName: explorerDeviceName, bluetoothManager: bluetoothManager)
                    }
                case .autoDownload:
                    AutoDownloadView(controller: autoDownload)
                }
            }
            .onChange(of: autoDownload.deviceName) { name in
                // Turning it on from the device screen closes that device; swap the screen for the live log in one write.
                if name != nil { path = [.autoDownload] }
            }
            .onChange(of: bluetoothManager.hasValidDeviceDataPtr()) { open in
                // A closed device (e.g. a lost link) pops its screen; auto download's handoff is handled above.
                if !open && !autoDownload.isActive { path.removeAll { $0 == .explorer } }
            }
            .onChange(of: path) { path in
                if !path.contains(.explorer) { explorerDeviceName = nil }
            }
            .onChange(of: bluetoothManager.hasLostLink) { lost in
                // The device screen closes the device and pops back here; say why and what to do.
                if lost && !autoDownload.isActive {
                    connectError = "Link to \(explorerDeviceName ?? "the dive computer") lost. Tap Connect to reconnect."
                }
            }
            .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
                ShareSheet(activityItems: shareItems ?? [])
            }
        }
    }

    // Reachable without a connection: auto download's libdivecomputer lines land in this log too.
    private var logSection: some View {
        Section {
            FullLoggingToggle()
            Button {
                ExplorerLog.shared.shareItems { shareItems = $0 }
            } label: {
                Label("Share log", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Log")
        } footer: {
            Text(FullLogging.footer)
        }
    }

    @ViewBuilder
    private var autoDownloadSection: some View {
        Section {
            let devices = AutoDownloadController.nauticDevices
            if devices.isEmpty {
                Text("Connect to your Suunto Nautic/Ocean once (Scan, then Connect). It then shows up here with an Auto download switch.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(devices, id: \.name) { device in
                AutoDownloadToggle(device: device, controller: autoDownload)
            }
            Button {
                path = [.autoDownload]
            } label: {
                Label("Live log and actions", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("Auto download")
        } footer: {
            Text("Keeps looking for the watch, downloads only dives it hasn't got yet, and reconnects by itself if the link drops. Works with the app in the background.")
        }
    }

    private var experimentalBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EXPERIMENTAL")
                .font(.caption).bold()
                .foregroundColor(.orange)
            Text("A tester for dive computers this package supports. The Suunto Nautic/Ocean explorer is the most complete: connect, list dives, download by logbook ID, and decode the full profile (depth, temperature, tank pressure, events, GPS, deco, battery, IMU). Raw capture exports you send back help extend support to more devices.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private func deviceRow(_ peripheral: CBPeripheral) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(peripheral.name ?? "Unknown Device")
                    .font(.headline)
                Text(peripheral.identifier.uuidString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isConnecting && connectingPeripheralID == peripheral.identifier {
                ProgressView()
            } else {
                Button("Connect") {
                    connect(to: peripheral)
                }
                .disabled(isConnecting || autoDownload.isActive)
            }
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        guard let name = peripheral.name else { return }
        let address = peripheral.identifier.uuidString

        isConnecting = true
        connectError = nil
        connectingPeripheralID = peripheral.identifier
        ExplorerLog.shared.noteConnection("Connecting to \(name)", device: name)

        // openBLEDevice is blocking (it polls internally until the
        // libdivecomputer handshake succeeds/fails/times out) - keep it
        // off the main thread, matching the pattern used elsewhere in
        // this package (see Examples/DeviceRow.swift).
        DispatchQueue.global(qos: .userInitiated).async {
            // Detect the family from the advertised name so any supported device
            // opens correctly. Fall back to Suunto Nautic (the family with the
            // richest explorer) when detection can't identify it.
            var dcFamily = DC_FAMILY_NULL
            var dcModel: UInt32 = 0
            let detected = get_device_info_from_name(name, &dcFamily, &dcModel) == DC_STATUS_SUCCESS
                ? DeviceConfiguration.DeviceFamily(dcFamily: dcFamily).map { ($0, dcModel) }
                : nil
            let forcedModel = detected ?? (.suuntoNautic, UInt32(0))
            let status = DeviceConfiguration.openBLEDeviceStatus(
                name: name,
                deviceAddress: address,
                forcedModel: forcedModel
            )
            // The Nautic driver's open fails with TIMEOUT only after waiting for the Suunto app to finish with the watch.
            let suuntoAppBusy = status == DC_STATUS_TIMEOUT && forcedModel.0 == .suuntoNautic

            DispatchQueue.main.async {
                isConnecting = false
                connectingPeripheralID = nil
                if status == DC_STATUS_SUCCESS {
                    explorerDeviceName = name
                    if bluetoothManager.hasValidDeviceDataPtr() && !autoDownload.isActive {
                        path = [.explorer]
                    }
                } else if suuntoAppBusy {
                    connectError = "The Suunto app is syncing \(name). Try again once it's done."
                    ExplorerLog.shared.append("Connect to \(name) failed: the Suunto app is using the watch")
                } else {
                    connectError = "Couldn't connect to \(name). Check it's awake (press a button) and in range, then try again."
                    ExplorerLog.shared.append("Connect to \(name) failed")
                }
            }
        }
    }
}
