import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
import LibDCBridge.CoreBluetoothManagerProtocol
import Combine

/// Represents a BLE serial service with its identifying information
@objc(SerialService)
class SerialService: NSObject {
    @objc let uuid: String
    @objc let vendor: String
    @objc let product: String
    
    @objc init(uuid: String, vendor: String, product: String) {
        self.uuid = uuid
        self.vendor = vendor
        self.product = product
        super.init()
    }
}

/// Extension to check if a CBUUID is a standard Bluetooth service UUID
extension CBUUID {
    var isStandardBluetooth: Bool {
        return self.data.count == 2
    }
}

/// Central manager for handling BLE communications with dive computers.
/// Manages device discovery, connection, and data transfer with BLE dive computers.
@objc(CoreBluetoothManager)
public class CoreBluetoothManager: NSObject, CoreBluetoothManagerProtocol, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Singleton
    private static let sharedInstance = CoreBluetoothManager()
    
    @objc public static func shared() -> Any! {
        return sharedInstance
    }
    
    public static var sharedManager: CoreBluetoothManager {
        return sharedInstance
    }
    
    // MARK: - Published Properties
    @Published public var centralManager: CBCentralManager! // Core Bluetooth central manager instance
    @Published public var peripheral: CBPeripheral? // Currently selected peripheral device
    @Published public var discoveredPeripherals: [CBPeripheral] = [] // List of discovered BLE peripherals
    @Published public var isPeripheralReady = false // Indicates if peripheral is ready for communication
    @Published @objc dynamic public var connectedDevice: CBPeripheral? // Currently connected peripheral device
    @Published public var isScanning = false // Indicates if currently scanning for devices
    @Published public var isRetrievingLogs = false { // Indicates if currently retrieving dive logs
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var currentRetrievalDevice: CBPeripheral? { // Device currently being used for log retrieval
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var isDisconnecting = false // Indicates if currently disconnecting from device
    @Published public var isBluetoothReady = false // Indicates if Bluetooth is ready for use
    @Published public var isConnecting = false // Indicates if a connection attempt is in progress (prevents auto-reconnect)
    @Published private var deviceDataPtrChanged = false

    // MARK: - Private Properties
    @objc private var timeout: Int = -1 // default to no timeout
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    // Queue of raw BLE notification payloads, one entry per didUpdateValueFor
    // call. shearwater_common_slip_read (libdivecomputer) strips a fixed
    // 2-byte header from every dc_iostream_read() call on the assumption
    // that each call returns exactly one physical BLE notification. This
    // used to be a flat `Data` buffer that readDataPartial drained by byte
    // count regardless of where notification boundaries actually fell —
    // when two notifications arrived close together, both landed in the
    // buffer before being drained and got coalesced into one returned
    // chunk, so only 2 header bytes were stripped instead of 2-per-
    // notification. The stray header bytes then got counted as SLIP
    // payload, corrupting the declared-length-vs-actual-length check and
    // producing "Invalid packet header" (shearwater_common.c:428) on any
    // manifest/dive-data response that spans more than one BLE notification.
    private var receivedPackets: [Data] = []
    private let queue = DispatchQueue(label: "com.blemanager.queue")
    private let dataAvailableSemaphore = DispatchSemaphore(value: 0) // Signals when new data arrives
    private let writeReadySemaphore = DispatchSemaphore(value: 0) // Signals when peripheral can accept a no-response write
    private let writeConfirmSemaphore = DispatchSemaphore(value: 0) // Signals when a with-response write completes
    private var lastWriteError: Error? // Result of the most recent with-response write
    private var _deviceDataPtr: UnsafeMutablePointer<device_data_t>?
    private var connectionCompletion: ((Bool) -> Void)?
    private var totalBytesReceived: Int = 0
    private var lastDataReceived: Date?
    private var averageTransferRate: Double = 0
    private var preferredService: CBService?
    private var pendingOperations: [() -> Void] = []
    /// All characteristics of the preferred service, keyed by lowercased UUID string.
    /// Used by `readCharacteristic(byUUID:timeout:)` to service BLE characteristic-read ioctls
    /// (e.g. Cressi reads serial/model/firmware via DC_IOCTL_BLE_CHARACTERISTIC_READ).
    private var characteristicsByUUID: [String: CBCharacteristic] = [:]
    /// Result slot for an in-flight explicit characteristic read; accessed under `queue`.
    private var ioctlReadValue: Data?
    /// Lowercased UUID of the characteristic an explicit read is currently awaiting; accessed under `queue`.
    private var ioctlReadCharUUID: String?
    /// Nordic UART serial service. Cressi advertises both this and its own vendor service,
    /// but libdivecomputer requires the vendor service, so this must never win preferred-service selection.
    private let nordicUARTServiceUUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    
    // MARK: - Public Properties
    public var openedDeviceDataPtr: UnsafeMutablePointer<device_data_t>? { // Public access to device data pointer with change notification
        get {
            _deviceDataPtr
        }
        set {
            objectWillChange.send()
            _deviceDataPtr = newValue
        }
    }
    
    /// Checks if there is a valid device data pointer
    /// - Returns: True if device data pointer exists
    public func hasValidDeviceDataPtr() -> Bool {
        return openedDeviceDataPtr != nil
    }
    
    // MARK: - Serial Services
    /// Known BLE serial services for supported dive computers
    @objc private let knownSerialServices: [SerialService] = [
        SerialService(uuid: "0000fefb-0000-1000-8000-00805f9b34fb", vendor: "Heinrichs-Weikamp", product: "Telit/Stollmann"),
        SerialService(uuid: "2456e1b9-26e2-8f83-e744-f34f01e9d701", vendor: "Heinrichs-Weikamp", product: "U-Blox"),
        SerialService(uuid: "544e326b-5b72-c6b0-1c46-41c1bc448118", vendor: "Mares", product: "BlueLink Pro"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e", vendor: "Nordic Semi", product: "UART"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dc10b8", vendor: "Cressi", product: "Goa"),
        SerialService(uuid: "98ae7120-e62e-11e3-badd-0002a5d5c51b", vendor: "Suunto", product: "EON Steel/Core"),
        SerialService(uuid: "cb3c4555-d670-4670-bc20-b61dbc851e9a", vendor: "Pelagic", product: "i770R/i200C"),
        SerialService(uuid: "ca7b0001-f785-4c38-b599-c7c5fbadb034", vendor: "Pelagic", product: "i330R/DSX"),
        SerialService(uuid: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0", vendor: "ScubaPro", product: "G2/G3"),
        SerialService(uuid: "fe25c237-0ece-443c-b0aa-e02033e7029d", vendor: "Shearwater", product: "Perdix/Teric"),
        // TODO: discoverable over BLE, but device open will fail — see the matching TODO
        // in DeviceConfiguration.supportedModels (no libdivecomputer descriptor entry yet).
        SerialService(uuid: "1aa44039-1667-4b29-87cc-dfecaaf31d97", vendor: "Shearwater", product: "Perdix 3"),
        SerialService(uuid: "0000fcef-0000-1000-8000-00805f9b34fb", vendor: "Divesoft", product: "Freedom"),
        SerialService(uuid: "00000001-8c3b-4f2c-a59e-8c08224f3253", vendor: "Halcyon", product: "Symbios"),
        SerialService(uuid: "84968ffe-d26d-478a-b953-5010bcf58bca", vendor: "Seac", product: "Screen")
    ]
    
    /// Service UUIDs to exclude from discovery
    private let excludedServices: Set<String> = [
        "00001530-1212-efde-1523-785feabcd123", // Nordic Upgrade
        "9e5d1e47-5c13-43a0-8635-82ad38a1386f", // Broadcom Upgrade #1
        "a86abc2d-d44c-442e-99f7-80059a873e36"  // Broadcom Upgrade #2
    ]
    
    // MARK: - Initialization
    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Service Discovery
    @objc(getPeripheralReadyState)
    public func getPeripheralReadyState() -> Bool {
        return self.isPeripheralReady
    }
    
    @objc(discoverServices)
    public func discoverServices() -> Bool {
        guard let peripheral = self.peripheral else {
            logError("No peripheral available for service discovery")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state: \(peripheral.state.rawValue)")
            return false
        }
        
        peripheral.discoverServices(nil)
        
        // Wait for characteristics with timeout
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while writeCharacteristic == nil || notifyCharacteristic == nil {
            if Date() > timeout {
                logError("Timeout waiting for service discovery")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        
        return writeCharacteristic != nil && notifyCharacteristic != nil
    }
    
    @objc(enableNotifications)
    public func enableNotifications() -> Bool {
        guard let notifyCharacteristic = self.notifyCharacteristic,
              let peripheral = self.peripheral else {
            logError("Missing characteristic or peripheral for notifications")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state for notifications: \(peripheral.state.rawValue)")
            return false
        }
        
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        
        // Wait for notifications to be enabled with timeout
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while !notifyCharacteristic.isNotifying {
            if Date() > timeout {
                logError("Timeout waiting for notifications to enable")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        
        return notifyCharacteristic.isNotifying
    }
    
    @objc public func write(_ data: Data!) -> Bool {
        guard let peripheral = self.peripheral,
              let characteristic = self.writeCharacteristic else { return false }
        // Choose the write type from the characteristic's properties rather than always using
        // .withoutResponse. A characteristic that only supports Write (with response) silently
        // drops .withoutResponse writes on CoreBluetooth. Prefer .withoutResponse when available
        // (preserves behavior for devices that work today), else fall back to .withResponse.
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        Logger.shared.logPacket(direction: .outbound, data: data, characteristicUUID: characteristic.uuid.uuidString)

        // Per-write deadline from the backend-requested timeout (falls back to 3s).
        let timeoutMs = self.timeout > 0 ? self.timeout : 3000

        if writeType == .withoutResponse {
            // Don't overrun CoreBluetooth's transmit queue: wait until it can accept a
            // no-response write, otherwise the write is silently dropped during bursts.
            if !peripheral.canSendWriteWithoutResponse {
                drainSemaphore(writeReadySemaphore)
                if writeReadySemaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
                    logWarning("Write blocked waiting for canSendWriteWithoutResponse")
                    return false
                }
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            return true
        } else {
            // With-response write: wait for the didWriteValueFor confirmation.
            drainSemaphore(writeConfirmSemaphore)
            lastWriteError = nil
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            if writeConfirmSemaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
                logWarning("Write withResponse timed out")
                return false
            }
            if let error = lastWriteError {
                logError("Write withResponse failed: \(error.localizedDescription)")
                return false
            }
            return true
        }
    }

    /// Drains any pending signals from a semaphore so the next wait reflects only new events.
    private func drainSemaphore(_ semaphore: DispatchSemaphore) {
        while semaphore.wait(timeout: .now()) == .success { }
    }
    
    /// Sets the per-read timeout (milliseconds) requested by the libdivecomputer backend.
    /// A non-positive value means "no timeout was set"; `readDataPartial` then uses its default.
    @objc public func setReadTimeout(_ milliseconds: Int32) {
        self.timeout = Int(milliseconds)
    }

    @objc public func readDataPartial(_ requested: Int32) -> Data? {
        let requestedInt = Int(requested)
        let startTime = Date()
        // Honor the timeout the backend requested via dc_iostream_set_timeout; fall back to 3s
        // when unset (timeout < 0). Previously this was hardcoded to 3s, ignoring the backend.
        let timeout: TimeInterval = self.timeout > 0 ? Double(self.timeout) / 1000.0 : 3.0

        while Date().timeIntervalSince(startTime) < timeout {
            var outData: Data?

            queue.sync {
                // One queued notification per call, never merged — see the
                // receivedPackets declaration for why this matters. A packet
                // larger than requested (shouldn't happen in practice; real
                // notifications are far smaller than the BLE_MTU_MAX request
                // size) is split, with the remainder pushed back to the
                // front of the queue rather than dropped.
                if !receivedPackets.isEmpty {
                    let packet = receivedPackets.removeFirst()
                    if packet.count > requestedInt {
                        outData = packet.prefix(requestedInt)
                        receivedPackets.insert(packet.suffix(from: requestedInt), at: 0)
                    } else {
                        outData = packet
                    }
                }
            }

            if let data = outData {
                return data
            }

            // Wait for data - use semaphore with short timeout, fall back to brief sleep
            let result = dataAvailableSemaphore.wait(timeout: .now() + .milliseconds(50))
            if result == .timedOut {
                // Brief sleep as fallback to avoid tight spin loop
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        return nil
    }
    
    // MARK: - Device Management
    @objc public func close(clearDevicePtr: Bool = false) {
        isDisconnecting = true
        // isPeripheralReady/connectedDevice are NOT published here when there's
        // an actual peripheral to disconnect — didDisconnectPeripheral is the
        // only truthful confirmation that CoreBluetooth has actually torn the
        // link down (cancelPeripheralConnection just requests it; the callback
        // fires later, asynchronously). Publishing "disconnected" eagerly —
        // even at the same moment cancelPeripheralConnection is called — let a
        // caller observing connectedDevice start a new connection attempt
        // while CoreBluetooth still considered the old one live (confirmed on
        // device: still raced). The only case this function publishes
        // directly is "there was no peripheral to disconnect", where no
        // didDisconnectPeripheral callback will ever arrive.
        queue.sync {
            if !receivedPackets.isEmpty {
                receivedPackets.removeAll()
            }
            characteristicsByUUID.removeAll()
            ioctlReadValue = nil
            ioctlReadCharUUID = nil
        }

        // Drain and signal semaphore to unblock any waiting reads and clear stale signals
        while dataAvailableSemaphore.wait(timeout: .now()) == .success {
            // Drain any accumulated signals
        }
        dataAvailableSemaphore.signal() // Signal once to unblock any waiting read

        var needsShutdownSettleDelay = false
        if clearDevicePtr {
            if let devicePtr = self.openedDeviceDataPtr {
                if devicePtr.pointee.device != nil {
                    dc_device_close(devicePtr.pointee.device)
                    needsShutdownSettleDelay = true
                }
                devicePtr.deallocate()
                self.openedDeviceDataPtr = nil
            }
        }

        if let peripheral = self.peripheral {
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.peripheral = nil
            if needsShutdownSettleDelay {
                // dc_device_close (above) sends a protocol-level shutdown command
                // (e.g. Shearwater's "exit command mode" packet) over a writeValue
                // that completes asynchronously on the BLE stack. Without a settle
                // delay, cancelPeripheralConnection tears down the link before
                // that write flushes, and the dive computer never sees the
                // shutdown — it stays stuck on "Sending Dive" / "WAIT CMD" until
                // it times out on its own. close() isn't guaranteed to run off
                // the main thread (a caller may invoke it directly from a
                // SwiftUI action), so this can't be a blocking sleep here.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                    self.centralManager.cancelPeripheralConnection(peripheral)
                    // didDisconnectPeripheral publishes isPeripheralReady/connectedDevice
                    // once CoreBluetooth actually confirms the teardown.
                }
            } else {
                centralManager.cancelPeripheralConnection(peripheral)
                // didDisconnectPeripheral publishes isPeripheralReady/connectedDevice
                // once CoreBluetooth actually confirms the teardown.
            }
        } else {
            // Nothing to disconnect, but observers waiting on these properties
            // still need the signal.
            DispatchQueue.main.async {
                self.isPeripheralReady = false
                self.connectedDevice = nil
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isDisconnecting = false
        }
    }
    
    public func startScanning(omitUnsupportedPeripherals: Bool = true) {
        centralManager.scanForPeripherals(
            withServices: omitUnsupportedPeripherals ? knownSerialServices.map { CBUUID(string: $0.uuid) } : nil,
            options: nil)
        isScanning = true
    }
    
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    @objc public func connect(toDevice address: String!) -> Bool {
        guard let uuid = UUID(uuidString: address),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return false
        }
        
        // connect(toDevice:) is called from openBLEDevice, which every call site
        // dispatches off the main thread (it's a blocking call awaiting CB
        // callbacks). `peripheral` is @Published, so assigning it here directly
        // triggers "Updating ObservedObject from background threads" — hop to
        // main for the mutation, everything else can stay off-thread.
        if Thread.isMainThread {
            self.peripheral = peripheral
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.peripheral = peripheral
            }
        }
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        return true  // Return immediately, connection status will be handled by delegate
    }
    
    public func connectToStoredDevice(_ uuid: String) -> Bool {
        guard let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid) else {
            return false
        }
        
        return DeviceConfiguration.openBLEDevice(
            name: storedDevice.name,
            deviceAddress: storedDevice.uuid
        )
    }
    
    // MARK: - State Management
    public func clearRetrievalState() {
        DispatchQueue.main.async { [weak self] in
            self?.isRetrievingLogs = false
            self?.currentRetrievalDevice = nil
        }
    }
    
    public func setBackgroundMode(_ enabled: Bool) {
        if enabled {
            // Set connection parameters for background operation
            if let peripheral = peripheral {
                // For iOS/macOS, we can only ensure the connection stays alive
                // by maintaining the peripheral reference and keeping the central manager active
                
                #if os(iOS)
                // On iOS, we can request background execution time
                var backgroundTask: UIBackgroundTaskIdentifier = .invalid
                backgroundTask = UIApplication.shared.beginBackgroundTask { [backgroundTask] in
                    // Cleanup callback
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                
                // Store the task identifier for later cleanup
                currentBackgroundTask = backgroundTask
                #endif
            }
        } else {
            #if os(iOS)
            // Clean up any background tasks when disabling background mode
            if let peripheral = peripheral {
                if let task = currentBackgroundTask, task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    currentBackgroundTask = nil
                }
            }
            #endif
        }
    }

    // track background tasks
    #if os(iOS)
    private var currentBackgroundTask: UIBackgroundTaskIdentifier?
    #endif

    public func systemDisconnect(_ peripheral: CBPeripheral) {
        logInfo("Performing system-level disconnect for \(peripheral.name ?? "Unknown Device")")
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.peripheral = nil
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    public func clearDiscoveredPeripherals() {
        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
        }
    }
    
    public func addDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            if !self.discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredPeripherals.append(peripheral)
            }
        }
    }

    public func queueOperation(_ operation: @escaping () -> Void) {
        if isBluetoothReady {
            operation()
        } else {
            pendingOperations.append(operation)
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logInfo("Bluetooth is powered on")
            isBluetoothReady = true
            pendingOperations.forEach { $0() }
            pendingOperations.removeAll()
        case .poweredOff:
            logWarning("Bluetooth is powered off")
            isBluetoothReady = false
        case .resetting:
            logWarning("Bluetooth is resetting")
            isBluetoothReady = false
        case .unauthorized:
            logError("Bluetooth is unauthorized")
            isBluetoothReady = false
        case .unsupported:
            logError("Bluetooth is unsupported")
            isBluetoothReady = false
        case .unknown:
            logWarning("Bluetooth state is unknown")
            isBluetoothReady = false
        @unknown default:
            logWarning("Unknown Bluetooth state")
            isBluetoothReady = false
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logInfo("Successfully connected to \(peripheral.name ?? "Unknown Device")")
        peripheral.delegate = self
        DispatchQueue.main.async {
            self.isPeripheralReady = true
            self.connectedDevice = peripheral
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("Failed to connect to \(peripheral.name ?? "Unknown Device"): \(error?.localizedDescription ?? "No error description")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logInfo("Disconnected from \(peripheral.name ?? "unknown device")")
        if let error = error {
            logError("Disconnect error: \(error.localizedDescription)")
        }
        
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil

            // No auto-reconnect: a mid-session disconnect just surfaces as a
            // failure (via DiveLogRetriever's IO/protocol error path, or the
            // host app's own connect timeout) and drives the UI to a clean
            // retry state. This used to silently reopen the device here, but
            // that raced against the host app's own connection flow — two
            // independent callers (the host app's connect path, and this
            // handler) could both call openBLEDevice for the same peripheral
            // within milliseconds of each other, each allocating/writing to
            // the shared device_data_t. No amount of flag-gating closed that
            // window cleanly. Fail cleanly on disconnect instead, and let the
            // user (or the host app's own retry UI) initiate the next
            // attempt — Shearwater's BLE stack in particular won't reliably
            // accept a second connection attempt within one "session" anyway.
            if !self.isDisconnecting && !self.isRetrievingLogs && !self.isConnecting {
                logInfo("Unexpected disconnect from \(peripheral.name ?? "device") — not auto-reconnecting")
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name != nil {
            // Add the peripheral if:
            // 1. It's a stored device
            // 2. It's a supported device
            // 3. We haven't already added it
            if DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) != nil ||
               DeviceConfiguration.fromName(peripheral.name ?? "") != nil {
                addDiscoveredPeripheral(peripheral)
            }
        }
    }

    // MARK: - CBPeripheral Methods
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logError("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            logWarning("No services found")
            return
        }
        
        // Reset stale state unconditionally, before scanning services. If a reconnect's
        // service discovery finds no recognized service (e.g. a failed retry before the
        // device is advertising), leaving the previous connection's characteristics in
        // place would let a later write/subscribe use a characteristic object that
        // belongs to a dead peripheral.
        preferredService = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        queue.sync { characteristicsByUUID.removeAll() }

        // Choose the preferred service across all matches before binding characteristics.
        // A vendor-specific service always wins over the generic Nordic UART service:
        // Cressi advertises both Nordic UART (…CA9E) and its own service (…10B8), and
        // libdivecomputer requires the vendor service.
        var chosen: CBService?
        var chosenIsNordic = false
        for service in services {
            if isExcludedService(service.uuid) {
                continue
            }

            if let knownService = isKnownSerialService(service.uuid) {
                let isNordic = knownService.uuid.lowercased() == nordicUARTServiceUUID
                if chosen == nil || (chosenIsNordic && !isNordic) {
                    chosen = service
                    chosenIsNordic = isNordic
                }
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }

        if let chosen = chosen {
            preferredService = chosen
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logError("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else {
            logWarning("No characteristics found for service: \(service.uuid)")
            return
        }
        
        // When a known serial service was identified, only bind streaming characteristics
        // from that preferred service (avoids grabbing Nordic UART characteristics on Cressi,
        // which exposes both services). If no known service matched, fall back to scanning all.
        if let preferred = preferredService, service != preferred {
            return
        }

        for characteristic in characteristics {
            queue.sync {
                characteristicsByUUID[characteristic.uuid.uuidString.lowercased()] = characteristic
            }

            if isWriteCharacteristic(characteristic) {
                writeCharacteristic = characteristic
            }

            if isReadCharacteristic(characteristic) {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error receiving data: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            return
        }

        Logger.shared.logPacket(direction: .inbound, data: data, characteristicUUID: characteristic.uuid.uuidString)

        var handledAsIoctlRead = false
        queue.sync {
            // Route the value of an explicitly requested characteristic read (e.g. the Cressi
            // serial/model/firmware characteristics) to the ioctl slot instead of the SLIP stream.
            if let want = ioctlReadCharUUID,
               characteristic.uuid.uuidString.lowercased() == want {
                ioctlReadValue = data
                handledAsIoctlRead = true
            } else {
                // Queue as its own entry — see receivedPackets' declaration for why
                // this must not be merged with any other pending notification.
                receivedPackets.append(data)
            }
        }

        if handledAsIoctlRead {
            return
        }

        // Signal that data is available - wake up any waiting read
        dataAvailableSemaphore.signal()

        updateTransferStats(data.count)
    }

    /// Synchronously reads a single characteristic value by UUID. Used by `ble_ioctl`
    /// to service DC_IOCTL_BLE_CHARACTERISTIC_READ (Cressi serial/model/firmware reads).
    /// Mirrors the RunLoop-polling pattern used by `discoverServices`.
    /// - Returns: the characteristic value, or nil on timeout / not-found / not-connected.
    @objc(readCharacteristicByUUID:timeout:)
    public func readCharacteristic(byUUID uuidString: String, timeout seconds: Double) -> Data? {
        guard let peripheral = self.peripheral, peripheral.state == .connected else {
            logError("No connected peripheral for characteristic read")
            return nil
        }

        let key = uuidString.lowercased()
        guard let characteristic = queue.sync(execute: { characteristicsByUUID[key] }) else {
            logError("Characteristic \(uuidString) not found in preferred service")
            return nil
        }

        queue.sync {
            ioctlReadValue = nil
            ioctlReadCharUUID = key
        }
        peripheral.readValue(for: characteristic)

        let deadline = Date(timeIntervalSinceNow: seconds)
        while true {
            var result: Data?
            queue.sync { result = ioctlReadValue }
            if let result = result {
                queue.sync { ioctlReadValue = nil; ioctlReadCharUUID = nil }
                return result
            }
            if Date() > deadline {
                queue.sync { ioctlReadCharUUID = nil }
                logError("Timeout reading characteristic \(uuidString)")
                return nil
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        lastWriteError = error
        if let error = error {
            logError("Error writing to characteristic: \(error.localizedDescription)")
        }
        writeConfirmSemaphore.signal()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeReadySemaphore.signal()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error changing notification state: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers
    private func updateTransferStats(_ newBytes: Int) {
        totalBytesReceived += newBytes
        
        if let last = lastDataReceived {
            let interval = Date().timeIntervalSince(last)
            if interval > 0 {
                let currentRate = Double(newBytes) / interval
                averageTransferRate = (averageTransferRate * 0.7) + (currentRate * 0.3)
            }
        }
        
        lastDataReceived = Date()
    }
    
    private func isKnownSerialService(_ uuid: CBUUID) -> SerialService? {
        return knownSerialServices.first { service in
            uuid.uuidString.lowercased() == service.uuid.lowercased()
        }
    }
    
    private func isExcludedService(_ uuid: CBUUID) -> Bool {
        return excludedServices.contains(uuid.uuidString.lowercased())
    }
    
    private func isWriteCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.write) ||
               characteristic.properties.contains(.writeWithoutResponse)
    }
    
    private func isReadCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.notify) ||
               characteristic.properties.contains(.indicate)
    }

    @objc public func close() {
        close(clearDevicePtr: false)
    }
}

// MARK: - Extensions
extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
