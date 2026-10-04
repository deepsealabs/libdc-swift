import SwiftUI
import CoreBluetooth
import LibDCSwift
import LibDCBridge
import Clibdivecomputer

struct ContentView: View {
    @StateObject private var bluetoothManager = CoreBluetoothManager.sharedManager
    @EnvironmentObject private var autoDownload: AutoDownloadController
    @State private var showAutoDownload = false

    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var connectedPeripheralID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                experimentalBanner

                List {
                    autoDownloadSection

                    Section {
                        if bluetoothManager.discoveredPeripherals.isEmpty {
                            Text(bluetoothManager.isScanning ? "Scanning…" : "No devices found yet.")
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
            .navigationDestination(isPresented: explorerBinding) {
                if let devicePtr = bluetoothManager.openedDeviceDataPtr {
                    DeviceExplorerView(devicePtr: devicePtr, bluetoothManager: bluetoothManager)
                }
            }
            .navigationDestination(isPresented: $showAutoDownload) {
                AutoDownloadView(controller: autoDownload)
            }
            .onChange(of: autoDownload.deviceName) { name in
                // Turning it on from the device screen pops that screen; land on the live log instead.
                if name != nil {
                    connectedPeripheralID = nil
                    showAutoDownload = true
                }
            }
        }
    }

    private var explorerBinding: Binding<Bool> {
        Binding(
            get: { connectedPeripheralID != nil && bluetoothManager.hasValidDeviceDataPtr() && !autoDownload.isActive },
            set: { if !$0 { connectedPeripheralID = nil } }
        )
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
                showAutoDownload = true
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
            if isConnecting && connectedPeripheralID == peripheral.identifier {
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
        connectedPeripheralID = peripheral.identifier

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
            let success = DeviceConfiguration.openBLEDevice(
                name: name,
                deviceAddress: address,
                forcedModel: forcedModel
            )

            DispatchQueue.main.async {
                isConnecting = false
                if !success {
                    connectError = "Failed to connect/handshake with \(name). For a Suunto Nautic/Ocean this can mean the EVA handshake needs updating for this unit (see suunto_nautic.h)."
                    connectedPeripheralID = nil
                }
            }
        }
    }
}
