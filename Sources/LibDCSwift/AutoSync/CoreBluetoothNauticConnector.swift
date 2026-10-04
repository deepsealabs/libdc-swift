import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge

/// `NauticSyncConnector` over `CoreBluetoothManager`: finds the stored watch by
/// scanning for the Nautic/Ocean service (and among peripherals the system
/// already holds a link to, since a bonded watch can stop advertising), then
/// opens it through `DeviceConfiguration.openBLEDevice`.
public final class CoreBluetoothNauticConnector: NauticSyncConnector {
    public static let serviceUUID = CBUUID(string: "61353090-8231-49cc-b57a-886370740041")

    public let name: String
    public let family: DeviceConfiguration.DeviceFamily
    public let model: UInt32
    private let manager: CoreBluetoothManager
    private let lock = NSLock()
    private var address: String

    public init(name: String, uuid: String, family: DeviceConfiguration.DeviceFamily = .suuntoNautic, model: UInt32 = 0,
                manager: CoreBluetoothManager = .sharedManager) {
        self.name = name
        self.address = uuid
        self.family = family
        self.model = model
        self.manager = manager
    }

    public convenience init(storedDevice: StoredDevice, manager: CoreBluetoothManager = .sharedManager) {
        self.init(name: storedDevice.name, uuid: storedDevice.uuid, family: storedDevice.family,
                  model: storedDevice.model, manager: manager)
    }

    public var currentAddress: String {
        lock.lock(); defer { lock.unlock() }
        return address
    }

    public func waitUntilPresent(timeout: TimeInterval?) async throws -> Bool {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while !(await MainActor.run { manager.isBluetoothReady }) {
            try Task.checkCancellation()
            if let deadline, Date() > deadline { return false }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        await MainActor.run {
            manager.clearDiscoveredPeripherals()
            manager.startScanning(omitUnsupportedPeripherals: true)
        }
        defer { Task { @MainActor [manager] in manager.stopScanning() } }

        while true {
            try Task.checkCancellation()
            if let found = await MainActor.run(body: { findPeripheral() }) {
                adopt(found)
                return true
            }
            if let deadline, Date() > deadline { return false }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    @MainActor
    private func findPeripheral() -> CBPeripheral? {
        let address = currentAddress
        let connected = manager.centralManager.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        return (manager.discoveredPeripherals + connected).first {
            $0.name == name || $0.identifier.uuidString == address
        }
    }

    /// iOS can rotate a bonded watch's identifier; follow it.
    private func adopt(_ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        lock.lock()
        let changed = address != uuid
        address = uuid
        lock.unlock()
        if changed {
            DeviceStorage.shared.reconcileUUID(name: name, newUUID: uuid)
        }
    }

    public func connect() throws -> NauticSyncLink {
        let address = currentAddress
        guard DeviceConfiguration.openBLEDevice(name: name, deviceAddress: address, forcedModel: (family, model)) else {
            throw NauticAutoSyncError.connectFailed("could not open \(name)")
        }
        // openBLEDevice publishes the pointer with an async hop to main; this read is queued behind it.
        let manager = self.manager
        let devicePtr = DispatchQueue.main.sync { manager.openedDeviceDataPtr }
        guard let devicePtr, let device = devicePtr.pointee.device else {
            DispatchQueue.main.sync { manager.close(clearDevicePtr: true) }
            throw NauticAutoSyncError.connectFailed("\(name) opened without a device")
        }
        return DCDeviceNauticLink(device: device) { _ in
            DispatchQueue.main.sync { manager.close(clearDevicePtr: true) }
        }
    }

    public func simulateDrop() {
        let manager = self.manager
        DispatchQueue.main.async {
            guard let peripheral = manager.peripheral ?? manager.connectedDevice else { return }
            manager.systemDisconnect(peripheral)
        }
    }
}
