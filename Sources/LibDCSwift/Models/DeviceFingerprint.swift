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
    /// `DiveComputerIdentity.storageKey`; nil on a record a 1.18 download saved that nothing has migrated.
    public let key: String?
    
    public init(deviceType: String, serial: String, fingerprint: Data) {
        self.init(deviceType: deviceType, serial: serial, fingerprint: fingerprint, key: nil)
    }

    init(deviceType: String, serial: String, fingerprint: Data, key: String?) {
        self.id = UUID()
        self.deviceType = deviceType
        self.serial = serial
        self.fingerprint = fingerprint
        self.timestamp = Date()
        self.key = key
    }

    private init(_ record: DeviceFingerprint, key: String) {
        id = record.id
        deviceType = record.deviceType
        serial = record.serial
        fingerprint = record.fingerprint
        timestamp = record.timestamp
        self.key = key
    }

    func keyed(_ key: String) -> DeviceFingerprint { DeviceFingerprint(self, key: key) }
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
        // A migrated record keeps its key when a 1.18-style save replaces it.
        let key = fingerprints.first {
            normalizeDeviceType($0.deviceType) == normalizedType && $0.serial == serial && $0.key != nil
        }?.key
        
        // Remove existing fingerprints for this device
        fingerprints.removeAll { 
            normalizeDeviceType($0.deviceType) == normalizedType && 
            $0.serial == serial 
        }
        
        let newFingerprint = DeviceFingerprint(
            deviceType: deviceType,
            serial: serial,
            fingerprint: fingerprint,
            key: key
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

    // MARK: - Keyed by identity

    /// The newest fingerprint for this computer: under its identity's key, else a 1.18 record of the same family and serial, so an unmigrated store never forces a full download.
    public func getFingerprint(for identity: DiveComputerIdentity, standIn: String? = nil) -> DeviceFingerprint? {
        guard let key = identity.storageKey(standIn: standIn) else { return nil }
        return loadFingerprints()
            .filter { !$0.fingerprint.isEmpty && belongs($0, to: identity, key: key) }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Replaces this computer's records, keyed or 1.18, with one under its identity's key, keeping the deviceType and serial a 1.18 reader looks up. Saves nothing when the identity has no key.
    public func saveFingerprint(_ fingerprint: Data, for identity: DiveComputerIdentity, standIn: String? = nil) {
        guard let key = identity.storageKey(standIn: standIn) else {
            logInfo("No fingerprint saved for \(identity.canonicalName): it reports no serial and has no stand-in")
            return
        }
        var fingerprints = loadFingerprints()
        let replaced = fingerprints.filter { belongs($0, to: identity, key: key) }
        fingerprints.removeAll { belongs($0, to: identity, key: key) }
        let deviceType = replaced.max { $0.timestamp < $1.timestamp }?.deviceType ?? identity.canonicalName
        fingerprints.append(DeviceFingerprint(deviceType: deviceType, serial: identity.devinfoSerial,
                                              fingerprint: fingerprint, key: key))
        saveFingerprints(fingerprints)
        logInfo("Saved fingerprint for \(key)")
    }

    /// Stores a fingerprint from a dive the host already has (another device downloaded it, say) when none is stored for this computer, so the first download here stops there; seed only from a completed download, since older dives are never offered again.
    @discardableResult
    public func seedFingerprint(identity: DiveComputerIdentity, data: Data, standIn: String? = nil) -> Bool {
        guard !data.isEmpty, identity.storageKey(standIn: standIn) != nil,
              getFingerprint(for: identity, standIn: standIn) == nil else { return false }
        saveFingerprint(data, for: identity, standIn: standIn)
        return true
    }

    /// Clears this computer's records, keyed or 1.18.
    public func clearFingerprint(for identity: DiveComputerIdentity, standIn: String? = nil) {
        guard let key = identity.storageKey(standIn: standIn) else { return }
        var fingerprints = loadFingerprints()
        fingerprints.removeAll { belongs($0, to: identity, key: key) }
        saveFingerprints(fingerprints)
    }

    func clearFingerprints(forKey key: String) {
        var fingerprints = loadFingerprints()
        let count = fingerprints.count
        fingerprints.removeAll { $0.key == key }
        if fingerprints.count != count { saveFingerprints(fingerprints) }
    }

    /// Keys 1.18 records in place, keeping deviceType and serial for 1.18 lookups; a serial-0 record needs exactly one serial-0 BLE device of its family in `storedDevices` (its UUID stands in), and an unkeyed record is still found. Safe to run every launch.
    @discardableResult
    public func migrateLegacyKeys(storedDevices: [StoredDevice] = []) -> Int {
        var fingerprints = loadFingerprints()
        var keyed = 0
        for index in fingerprints.indices where fingerprints[index].key == nil {
            let record = fingerprints[index]
            guard let key = Self.legacyKey(record, storedDevices: storedDevices) else { continue }
            fingerprints[index] = record.keyed(key)
            keyed += 1
        }
        if keyed > 0 {
            saveFingerprints(fingerprints)
            logInfo("Keyed \(keyed) fingerprint(s) by computer identity")
        }
        return keyed
    }

    private static func legacyKey(_ record: DeviceFingerprint, storedDevices: [StoredDevice]) -> String? {
        guard let family = DeviceCatalog.family(forName: record.deviceType) else { return nil }
        if DiveComputerIdentity.normalizedSerial(record.serial) != nil {
            return DiveComputerIdentity(family: family, model: 0, serial: record.serial, transport: .ble).storageKey()
        }
        let candidates = storedDevices.filter {
            $0.family == family && $0.effectiveTransport == .ble && $0.serial != nil
                && DiveComputerIdentity.normalizedSerial($0.serial) == nil
        }
        guard candidates.count == 1, let device = candidates.first else { return nil }
        return device.fingerprintStorageKey
    }

    /// Under `key`, or a 1.18 record of the identity's family and serial.
    private func belongs(_ record: DeviceFingerprint, to identity: DiveComputerIdentity, key: String) -> Bool {
        if let recordKey = record.key { return recordKey == key }
        guard let serial = identity.serial, record.serial.lowercased() == serial else { return false }
        return DeviceCatalog.family(forName: record.deviceType) == identity.family
    }
} 