import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
import Combine

/// Protocol for implementing persistence of dive data
public protocol DiveDataPersistence: AnyObject {
    func saveDives(_ dives: [DiveData], forDevice deviceId: UUID)
    func loadDives(forDevice deviceId: UUID) -> [DiveData]
    func clearDives(forDevice deviceId: UUID)
}

/// View model for managing dive data and device fingerprints.
/// Handles storage, retrieval, and state management for dive logs and device identification.
public class DiveDataViewModel: ObservableObject {
    @Published public var dives: [DiveData] = []
    @Published public var status: String = ""
    @Published public var progress: DownloadProgress = .notStarted
    @Published public var hasNewDives: Bool = false
    
    /// Key format: "fingerprint_{deviceType}_{serial}"
    private let fingerprintKeyPrefix = "fingerprint_"
    
    /// Represents a stored device fingerprint with associated metadata
    private struct StoredFingerprint: Codable {
        let deviceType: String
        let serial: String
        let fingerprint: Data
        let timestamp: Date
    }
    
    private let fingerprintKey = "DeviceFingerprints"
    private static weak var activeInstance: DiveDataViewModel?
    public weak var persistence: DiveDataPersistence?
    
    public init() {
        DiveDataViewModel.activeInstance = self
        DeviceConfiguration.setupContext()
    }
    
    deinit {
        DeviceConfiguration.cleanupContext()
    }
    
    /// Returns the currently active download instance if one exists
    /// - Returns: Active DiveDataViewModel instance or nil if no active download
    public static func getActiveDownloadInstance() -> DiveDataViewModel? {
        return activeInstance
    }
    
    /// Loads all stored device fingerprints from persistent storage
    /// - Returns: Array of StoredFingerprint objects, or empty array if none found
    private func loadStoredFingerprints() -> [StoredFingerprint] {
        guard let data = UserDefaults.standard.data(forKey: fingerprintKey),
              let fingerprints = try? JSONDecoder().decode([StoredFingerprint].self, from: data) else {
            return []
        }
        return fingerprints
    }
    
    /// Saves fingerprints to persistent storage
    /// - Parameter fingerprints: Array of StoredFingerprint objects to save
    private func saveStoredFingerprints(_ fingerprints: [StoredFingerprint]) {
        if let data = try? JSONEncoder().encode(fingerprints) {
            UserDefaults.standard.set(data, forKey: fingerprintKey)
        }
    }
    
    /// Normalizes a device type string for consistent comparison
    /// Uses libdivecomputer's descriptor system and filter matching
    /// - Parameter deviceType: The device type string to normalize
    /// - Returns: Normalized device type string
    private func normalizeDeviceType(_ deviceType: String) -> String {
        // Try to find matching descriptor using libdivecomputer's filter system
        var descriptor: OpaquePointer?
        let status = find_descriptor_by_name(&descriptor, deviceType)
        
        if status == DC_STATUS_SUCCESS,
           let desc = descriptor,
           let vendor = dc_descriptor_get_vendor(desc),
           let product = dc_descriptor_get_product(desc) {
            let normalizedName = "\(String(cString: vendor)) \(String(cString: product))" // Use vendor and product name from descriptor
            dc_descriptor_free(desc)
            return normalizedName
        }
        
        // If no match found, return original name
        return deviceType
    }
    
    /// Retrieves stored fingerprint for a specific device
    /// - Parameters:
    ///   - deviceType: Type/model of the device
    ///   - serial: Serial number of the device
    /// - Returns: Stored fingerprint data if found, nil otherwise
    public func getFingerprint(forDeviceType deviceType: String, serial: String) -> Data? {
        DeviceFingerprintStorage.shared.getFingerprint(
            forDeviceType: deviceType, 
            serial: serial
        )?.fingerprint
    }
    
    /// Saves a new fingerprint for a device
    /// - Parameters:
    ///   - fingerprint: The fingerprint data to save
    ///   - deviceType: Type/model of the device
    ///   - serial: Serial number of the device
    public func saveFingerprint(_ fingerprint: Data, deviceType: String, serial: String) {
        guard !fingerprint.isEmpty else {
            logWarning("⚠️ Attempted to save empty fingerprint - ignoring")
            return
        }
        
        DeviceFingerprintStorage.shared.saveFingerprint(
            fingerprint,
            deviceType: deviceType,
            serial: serial
        )
        objectWillChange.send()
    }
    
    /// Clears the stored fingerprint for a specific device
    /// - Parameters:
    ///   - deviceType: Type/model of the device
    ///   - serial: Serial number of the device
    public func clearFingerprint(forDeviceType deviceType: String, serial: String) {
        DeviceFingerprintStorage.shared.clearFingerprint(
            forDeviceType: deviceType,
            serial: serial
        )
        objectWillChange.send()
    }
    
    /// Removes all stored fingerprints from persistent storage
    public func clearAllFingerprints() {
        DeviceFingerprintStorage.shared.clearAllFingerprints()
        objectWillChange.send()
    }
    
    public func getFingerprintInfo(forDeviceType type: String, serial: String) -> Date? {
        DeviceFingerprintStorage.shared.getFingerprint(
            forDeviceType: type,
            serial: serial
        )?.timestamp
    }
    
    // Add this to your existing DownloadProgress enum if not already present
    public enum DownloadProgress: Equatable {
        case notStarted
        case inProgress(_ count: Int)
        case completed
        case cancelled
        case failed(_ message: String)
        case noNewDives
        /// Every dive this session parsed to an empty record (no samples, no
        /// duration) and was skipped -- typically a contended BLE stream on
        /// the Suunto NG family (the official Suunto app still holds the
        /// link). Distinct from noNewDives: the fingerprint was NOT advanced,
        /// so the caller should prompt a retry rather than report success.
        case emptyRead

        public var description: String {
            switch self {
            case .notStarted: return "Not started"
            case .inProgress(let count): return "Downloaded \(count) dives..."
            case .completed: return "Download completed"
            case .cancelled: return "Download cancelled"
            case .failed(let error): return "Error: \(error)"
            case .noNewDives: return "No new dives found"
            case .emptyRead: return "Download returned no dive data"
            }
        }
        
        public static func == (lhs: DownloadProgress, rhs: DownloadProgress) -> Bool {
            switch (lhs, rhs) {
            case (.notStarted, .notStarted):
                return true
            case (.completed, .completed):
                return true
            case (.cancelled, .cancelled):
                return true
            case (.noNewDives, .noNewDives):
                return true
            case (.emptyRead, .emptyRead):
                return true
            case let (.inProgress(count1), .inProgress(count2)):
                return count1 == count2
            case let (.failed(message1), .failed(message2)):
                return message1 == message2
            default:
                return false
            }
        }
    }
    
    public func addDive(number: Int, year: Int, month: Int, day: Int, 
                       hour: Int, minute: Int, second: Int,
                       maxDepth: Double, temperature: Double) {
        let components = DateComponents(year: year, month: month, day: day,
                                     hour: hour, minute: minute, second: second)
        if let date = Calendar.current.date(from: components) {
            let dive = DiveData(
                number: number,
                datetime: date,
                maxDepth: maxDepth,
                avgDepth: maxDepth * 0.6,
                divetime: 0,
                temperature: temperature,
                profile: [],
                tankPressure: [],
                gasMix: nil,
                gasMixCount: nil,
                gasMixes: nil,
                salinity: nil,
                atmospheric: 1.0,
                surfaceTemperature: nil,
                minTemperature: nil,
                maxTemperature: nil,
                tankCount: nil,
                tanks: nil,
                diveMode: .openCircuit,
                decoModel: nil,
                location: nil,
                rbt: nil,
                heartbeat: nil,
                bearing: nil,
                setpoint: nil,
                ppo2Readings: [],
                cns: nil,
                decoStop: nil
            )
            DispatchQueue.main.async {
                self.dives.append(dive)
                if case .inProgress = self.progress {
                    self.progress = .inProgress(self.dives.count)
                }
            }
        }
    }
    
    public func updateStatus(_ newStatus: String) {
        DispatchQueue.main.async {
            self.status = newStatus
        }
    }
    
    public func updateProgress(_ progress: DownloadProgress) {
        DispatchQueue.main.async {
            self.progress = progress
        }
    }
    
    public func updateProgress(count: Int) {
        DispatchQueue.main.async {
            // Don't show dive number during download since dives arrive newest-first
            // and we renumber them after download (oldest = #1)
            self.status = "Downloading dive \(count)..."
            self.progress = .inProgress(count)
        }
    }
    
    public func setError(_ message: String) {
        DispatchQueue.main.async {
            self.progress = .failed(message)
        }
    }
    
    public func clear() {
        DispatchQueue.main.async {
            self.dives.removeAll()
            self.hasNewDives = false
            self.resetProgress()
        }
    }
    
    public func setDetailedError(_ message: String, status: dc_status_t) {
        DispatchQueue.main.async {
            let statusDescription = switch status {
            case DC_STATUS_SUCCESS:
                "Operation completed successfully"
            case DC_STATUS_DONE:
                "Operation completed"
            case DC_STATUS_UNSUPPORTED:
                "This operation is not supported by your device"
            case DC_STATUS_INVALIDARGS:
                "Invalid parameters were provided"
            case DC_STATUS_NOMEMORY:
                "Insufficient memory to complete operation"
            case DC_STATUS_NODEVICE:
                "Device not found or disconnected"
            case DC_STATUS_NOACCESS:
                "Access to device was denied"
            case DC_STATUS_IO:
                """
                Connection lost. Please ensure:
                • Device is within range
                • Device is turned on
                • Battery level is sufficient
                """
            case DC_STATUS_TIMEOUT:
                "Device took too long to respond. Try again"
            case DC_STATUS_PROTOCOL:
                "Device communication error. Try turning device off and on"
            case DC_STATUS_DATAFORMAT:
                "Received invalid data from device"
            case DC_STATUS_CANCELLED:
                "Download was cancelled"
            default:
                "Unknown error occurred (Code: \(status))"
            }
            
            // Only show the original message if it provides additional context
            let errorMessage = if message == "Download incomplete" {
                statusDescription
            } else {
                "\(message)\n\n\(statusDescription)"
            }
            
            self.progress = .failed(errorMessage)
        }
    }
    
    public func appendDives(_ newDives: [DiveData]) {
        DispatchQueue.main.async {
            if !newDives.isEmpty {
                self.hasNewDives = true
            }
            self.dives.append(contentsOf: newDives)
            if case .inProgress = self.progress {
                self.updateProgress(count: self.dives.count)
            }
        }
    }

    /// Finalizes dive numbering after download completes.
    /// Sorts dives by date (oldest first) and assigns sequential numbers starting from 1.
    /// Call this after all dives have been downloaded.
    public func finalizeDiveNumbering() {
        DispatchQueue.main.async {
            guard !self.dives.isEmpty else { return }

            // Sort by datetime (oldest first)
            self.dives.sort { $0.datetime < $1.datetime }

            // Renumber starting from 1
            for i in 0..<self.dives.count {
                self.dives[i].number = i + 1
            }

            logInfo("📋 Finalized dive numbering: \(self.dives.count) dives (oldest=#1, newest=#\(self.dives.count))")
        }
    }
    
    func forgetDevice(deviceType: String, serial: String) {
        if var storedDevices = DeviceStorage.shared.getAllStoredDevices() {
            storedDevices.removeAll { device in
                device.name == deviceType 
            }
            DeviceStorage.shared.updateStoredDevices(storedDevices)
        }
        clearFingerprint(forDeviceType: deviceType, serial: serial)
        objectWillChange.send() 
        logInfo("🗑️ Cleared fingerprint for \(normalizeDeviceType(deviceType)) (\(serial))")
    }
    
    public func isDownloadOnlyNewDivesEnabled(forDeviceType deviceType: String, serial: String) -> Bool {
        let fingerprints = loadStoredFingerprints()
        if let storedFingerprint = fingerprints.first(where: { $0.deviceType == deviceType && $0.serial == serial }),
           !storedFingerprint.fingerprint.isEmpty {
            logInfo("🔍 Download only new dives is enabled for \(deviceType) (\(serial))")
            logInfo("📍 Current stored fingerprint: \(storedFingerprint.fingerprint.hexString)")
            return true
        }
        logInfo("🔍 Download only new dives is disabled for \(deviceType) (\(serial))")
        return false
    }
    
    public func resetProgress() {
        DispatchQueue.main.async {
            self.progress = .notStarted
            self.status = ""
        }
    }
}

/// Extension to convert Data to hexadecimal string representation
extension Data {
    public var hexString: String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
