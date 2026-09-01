import SwiftUI
import CoreBluetooth
import LibDCSwift

struct ContentView: View {
    @StateObject private var bluetoothManager = CoreBluetoothManager.sharedManager

    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var connectedPeripheralID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                experimentalBanner

                List {
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
                        Text("Looking for BLE service 61353090-8231-49cc-b57a-886370740041 (Suunto Nautic/Ocean) alongside every other dive computer this package recognizes.")
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
        }
    }

    private var explorerBinding: Binding<Bool> {
        Binding(
            get: { connectedPeripheralID != nil && bluetoothManager.hasValidDeviceDataPtr() },
            set: { if !$0 { connectedPeripheralID = nil } }
        )
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
                .disabled(isConnecting)
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
            let forcedModel: (DeviceConfiguration.DeviceFamily, UInt32) = (.suuntoNautic, 0)
            let success = DeviceConfiguration.openBLEDevice(
                name: name,
                deviceAddress: address,
                forcedModel: forcedModel
            )

            DispatchQueue.main.async {
                isConnecting = false
                if !success {
                    connectError = "Failed to connect/handshake with \(name). This may mean the EVA handshake payload needs updating for this unit — see suunto_nautic.h."
                    connectedPeripheralID = nil
                }
            }
        }
    }
}
