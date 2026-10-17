import Foundation
import Clibdivecomputer
import LibDCBridge

/// Represents a stored device fingerprint with associated metadata
public struct DeviceFingerprint: Codable, Identifiable {
    public let id: UUID
    public let deviceType: String
    public let serial: String
    public let fingerprint: Data
    public let timestamp: Date
    
    public init(deviceType: String, serial: String, fingerprint: Data) {
        self.id = UUID()
        self.deviceType = deviceType
        self.serial = serial
        self.fingerprint = fingerprint
        self.timestamp = Date()
    }
}

/// Manages persistent storage of device fingerprints
public class DeviceFingerprintStorage {
    public static let shared = DeviceFingerprintStorage()
    private let fingerprintKey = "DeviceFingerprints"
    private let defaults: UserDefaults

    /// Test seam: an isolated suite instead of `.standard`.
    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }
    
    /// Normalizes a device type string for consistent comparison
    /// Since we now use stored device configuration, this just does simple case-insensitive matching
    /// - Parameter deviceType: The device type string to normalize
    /// - Returns: Normalized device type string (lowercased and trimmed)
    private func normalizeDeviceType(_ deviceType: String) -> String {
        return deviceType.lowercased().trimmingCharacters(in: .whitespaces)
    }
    
    /// Loads all stored device fingerprints from persistent storage
    /// - Returns: Array of DeviceFingerprint objects
    public func loadFingerprints() -> [DeviceFingerprint] {
        guard let data = defaults.data(forKey: fingerprintKey),
              let fingerprints = try? JSONDecoder().decode([DeviceFingerprint].self, from: data) else {
            return []
        }
        return fingerprints
    }
    
    /// Saves fingerprints to persistent storage
    /// - Parameter fingerprints: Array of DeviceFingerprint objects to save
    public func saveFingerprints(_ fingerprints: [DeviceFingerprint]) {
        if let data = try? JSONEncoder().encode(fingerprints) {
            defaults.set(data, forKey: fingerprintKey)
        }
    }
    
    /// Gets fingerprint for specific device
    /// - Parameters:
    ///   - deviceType: Type/model of the device
    ///   - serial: Serial number of the device
    /// - Returns: Matching DeviceFingerprint if found
    public func getFingerprint(forDeviceType deviceType: String, serial: String) -> DeviceFingerprint? {
        let fingerprints = loadFingerprints()
        let normalizedType = normalizeDeviceType(deviceType)
        let matches = fingerprints.filter { 
            normalizeDeviceType($0.deviceType) == normalizedType && 
            $0.serial == serial 
        }
        
        let found = matches
            .filter { !$0.fingerprint.isEmpty }
            .sorted { $0.timestamp > $1.timestamp }
            .first
            
        if found != nil {
            logInfo("✅ Found stored fingerprint")
        }
        
        return found
    }
    
    /// Saves new fingerprint for device
    /// - Parameters:
    ///   - fingerprint: Fingerprint data to save
    ///   - deviceType: Type/model of device
    ///   - serial: Serial number of device
    public func saveFingerprint(_ fingerprint: Data, deviceType: String, serial: String) {
        var fingerprints = loadFingerprints()
        let normalizedType = normalizeDeviceType(deviceType)
        
        // Remove existing fingerprints for this device
        fingerprints.removeAll { 
            normalizeDeviceType($0.deviceType) == normalizedType && 
            $0.serial == serial 
        }
        
        let newFingerprint = DeviceFingerprint(
            deviceType: deviceType,
            serial: serial,
            fingerprint: fingerprint
        )
        
        fingerprints.append(newFingerprint)
        saveFingerprints(fingerprints)
        logInfo("✅ Saved fingerprint for \(normalizedType) (\(serial))")
    }
    
    /// Clears fingerprint for specific device
    public func clearFingerprint(forDeviceType deviceType: String, serial: String) {
        var fingerprints = loadFingerprints()
        let normalizedType = normalizeDeviceType(deviceType)
        fingerprints.removeAll {
            normalizeDeviceType($0.deviceType) == normalizedType &&
            $0.serial == serial
        }
        saveFingerprints(fingerprints)
        logInfo("🗑️ Cleared fingerprint for \(normalizedType) (\(serial))")
    }

    /// Clears all fingerprints for a specific device type (any serial)
    public func clearFingerprintsForDeviceType(_ deviceType: String) {
        var fingerprints = loadFingerprints()
        let normalizedType = normalizeDeviceType(deviceType)
        let countBefore = fingerprints.count
        fingerprints.removeAll {
            normalizeDeviceType($0.deviceType) == normalizedType
        }
        let removed = countBefore - fingerprints.count
        saveFingerprints(fingerprints)
        logInfo("🗑️ Cleared \(removed) fingerprint(s) for device type: \(normalizedType)")
    }

    /// Clears all stored fingerprints
    public func clearAllFingerprints() {
        defaults.removeObject(forKey: fingerprintKey)
        logInfo("🗑️ Cleared all fingerprints")
    }
} 