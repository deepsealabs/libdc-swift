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
    private let rejectedDivesKey = "RejectedDiveFingerprints"
    private let defaults: UserDefaults
    // Every change is load-modify-save: unserialized, a launch-time migration could write back a list missing a new commit.
    private let lock = NSRecursiveLock()

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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
        var fingerprints = loadFingerprints()
        let normalizedType = normalizeDeviceType(deviceType)
        fingerprints.removeAll {
            normalizeDeviceType($0.deviceType) == normalizedType &&
            $0.serial == serial
        }
        saveFingerprints(fingerprints)
        setRejectedDives([], forDeviceType: deviceType, serial: serial)
        logInfo("🗑️ Cleared fingerprint for \(normalizedType) (\(serial))")
    }

    /// Clears all fingerprints for a specific device type (any serial)
    public func clearFingerprintsForDeviceType(_ deviceType: String) {
        lock.lock(); defer { lock.unlock() }
        var fingerprints = loadFingerprints()
        let normalizedType = normalizeDeviceType(deviceType)
        let countBefore = fingerprints.count
        fingerprints.removeAll {
            normalizeDeviceType($0.deviceType) == normalizedType
        }
        let removed = countBefore - fingerprints.count
        saveFingerprints(fingerprints)
        let prefix = rejectionKeyPrefix(deviceType)
        let rejected = loadRejectedDives()
        let cleared = Set(rejected.keys.filter { $0.hasPrefix(prefix) }.flatMap { key -> [String] in
            [key] + (Self.rejectionIdentityKey(legacyKey: key).map { [$0] } ?? [])
        })
        saveRejectedDives(rejected.filter { !cleared.contains($0.key) })
        logInfo("🗑️ Cleared \(removed) fingerprint(s) for device type: \(normalizedType)")
    }

    /// Clears all stored fingerprints
    public func clearAllFingerprints() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: fingerprintKey)
        defaults.removeObject(forKey: rejectedDivesKey)
        logInfo("🗑️ Cleared all fingerprints")
    }

    // MARK: - Dives the parser rejected

    private func rejectionKeyPrefix(_ deviceType: String) -> String {
        normalizeDeviceType(deviceType) + "|"
    }

    private func loadRejectedDives() -> [String: [Data]] {
        guard let data = defaults.data(forKey: rejectedDivesKey),
              let all = try? JSONDecoder().decode([String: [Data]].self, from: data) else {
            return [:]
        }
        return all
    }

    private func saveRejectedDives(_ all: [String: [Data]]) {
        if all.isEmpty {
            defaults.removeObject(forKey: rejectedDivesKey)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: rejectedDivesKey)
        }
    }

    /// The 1.19 entry's identity key, when its device type names a family and it has a serial.
    private static func rejectionIdentityKey(deviceType: String, serial: String) -> String? {
        guard let family = DeviceCatalog.family(forName: deviceType),
              DiveComputerIdentity.normalizedSerial(serial) != nil else { return nil }
        return DiveComputerIdentity(family: family, model: 0, serial: serial, transport: .ble).storageKey()
    }

    private static func rejectionIdentityKey(legacyKey: String) -> String? {
        guard let bar = legacyKey.lastIndex(of: "|") else { return nil }
        return rejectionIdentityKey(deviceType: String(legacyKey[..<bar]),
                                    serial: String(legacyKey[legacyKey.index(after: bar)...]))
    }

    /// 1.19 entries are "<type>|<serial>"; identity keys hold no "|".
    private static func legacyRejectionKeys(in all: [String: [Data]], of identity: DiveComputerIdentity) -> [String] {
        guard let key = identity.storageKey(), identity.serial != nil else { return [] }
        return all.keys.filter { $0.contains("|") && rejectionIdentityKey(legacyKey: $0) == key }
    }

    /// Dives an earlier download rejected and none has parsed since, under the 1.19 key or the same computer's identity key.
    func rejectedDives(forDeviceType deviceType: String, serial: String) -> Set<Data> {
        lock.lock(); defer { lock.unlock() }
        let all = loadRejectedDives()
        let legacy = rejectionKeyPrefix(deviceType) + serial
        var dives = Set(all[legacy] ?? [])
        if let key = Self.rejectionIdentityKey(legacyKey: legacy) { dives.formUnion(all[key] ?? []) }
        return dives
    }

    /// Writes the 1.19 key, which older versions read, and the identity key derived from it, as clearing and migration derive it.
    func setRejectedDives(_ fingerprints: Set<Data>, forDeviceType deviceType: String, serial: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadRejectedDives()
        let value = fingerprints.isEmpty ? nil : Array(fingerprints)
        let legacy = rejectionKeyPrefix(deviceType) + serial
        all[legacy] = value
        if let key = Self.rejectionIdentityKey(legacyKey: legacy) { all[key] = value }
        saveRejectedDives(all)
    }

    /// The identity's rejected dives, including those under a 1.19 key of its family and serial; none without a key.
    func rejectedDives(for identity: DiveComputerIdentity, standIn: String? = nil) -> Set<Data> {
        guard let key = identity.storageKey(standIn: standIn) else { return [] }
        lock.lock(); defer { lock.unlock() }
        let all = loadRejectedDives()
        var dives = Set(all[key] ?? [])
        for legacy in Self.legacyRejectionKeys(in: all, of: identity) { dives.formUnion(all[legacy] ?? []) }
        return dives
    }

    /// Writes the identity key and any 1.19 key of its family and serial, so either download reads the same set.
    func setRejectedDives(_ fingerprints: Set<Data>, for identity: DiveComputerIdentity, standIn: String? = nil) {
        guard let key = identity.storageKey(standIn: standIn) else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadRejectedDives()
        let value = fingerprints.isEmpty ? nil : Array(fingerprints)
        all[key] = value
        for legacy in Self.legacyRejectionKeys(in: all, of: identity) { all[legacy] = value }
        saveRejectedDives(all)
    }

    /// Copies 1.19 entries with a serial to their identity key, keeping the 1.19 ones; returns how many changed.
    private func migrateRejectedDives() -> Int {
        var all = loadRejectedDives()
        var changed = 0
        for (legacy, dives) in all where legacy.contains("|") {
            guard let key = Self.rejectionIdentityKey(legacyKey: legacy) else { continue }
            let merged = Set(all[key] ?? []).union(dives)
            guard merged != Set(all[key] ?? []) else { continue }
            all[key] = Array(merged)
            changed += 1
        }
        if changed > 0 { saveRejectedDives(all) }
        return changed
    }

    // MARK: - Keyed by identity

    /// The newest fingerprint under the identity's key, else a 1.18 record of its family and serial, so unmigrated stores still stop.
    public func getFingerprint(for identity: DiveComputerIdentity, standIn: String? = nil) -> DeviceFingerprint? {
        guard let key = identity.storageKey(standIn: standIn) else { return nil }
        return loadFingerprints()
            .filter { !$0.fingerprint.isEmpty && belongs($0, to: identity, key: key) }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Replaces this computer's records with one under its key, keeping what a 1.18 reader looks up; no key, no save.
    public func saveFingerprint(_ fingerprint: Data, for identity: DiveComputerIdentity, standIn: String? = nil) {
        guard let key = identity.storageKey(standIn: standIn) else {
            logInfo("No fingerprint saved for \(identity.canonicalName): it reports no serial and has no stand-in")
            return
        }
        lock.lock(); defer { lock.unlock() }
        var fingerprints = loadFingerprints()
        let replaced = fingerprints.filter { belongs($0, to: identity, key: key) }
        fingerprints.removeAll { belongs($0, to: identity, key: key) }
        let deviceType = replaced.max { $0.timestamp < $1.timestamp }?.deviceType ?? identity.canonicalName
        fingerprints.append(DeviceFingerprint(deviceType: deviceType, serial: identity.devinfoSerial,
                                              fingerprint: fingerprint, key: key))
        saveFingerprints(fingerprints)
        logInfo("Saved fingerprint for \(key)")
    }

    /// Stores a fingerprint from a dive the host already has, when none is stored; seed only from a completed download (see Docs/DEVICE_IDENTITY.md).
    @discardableResult
    public func seedFingerprint(identity: DiveComputerIdentity, data: Data, standIn: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty, identity.storageKey(standIn: standIn) != nil,
              getFingerprint(for: identity, standIn: standIn) == nil else { return false }
        saveFingerprint(data, for: identity, standIn: standIn)
        return true
    }

    /// Clears this computer's records, keyed or 1.18.
    public func clearFingerprint(for identity: DiveComputerIdentity, standIn: String? = nil) {
        guard let key = identity.storageKey(standIn: standIn) else { return }
        lock.lock(); defer { lock.unlock() }
        var fingerprints = loadFingerprints()
        fingerprints.removeAll { belongs($0, to: identity, key: key) }
        saveFingerprints(fingerprints)
        setRejectedDives([], for: identity, standIn: standIn)
    }

    func clearFingerprints(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        var fingerprints = loadFingerprints()
        let count = fingerprints.count
        fingerprints.removeAll { $0.key == key }
        if fingerprints.count != count { saveFingerprints(fingerprints) }
        var rejected = loadRejectedDives()
        if rejected.removeValue(forKey: key) != nil { saveRejectedDives(rejected) }
    }

    /// Keys 1.18 records in place, keeping what a 1.18 lookup reads, and copies rejected dives to identity keys; idempotent (see Docs/DEVICE_IDENTITY.md).
    @discardableResult
    public func migrateLegacyKeys(storedDevices: [StoredDevice] = []) -> Int {
        lock.lock(); defer { lock.unlock() }
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
        let rejected = migrateRejectedDives()
        if rejected > 0 {
            logInfo("Keyed \(rejected) device(s)' rejected dives by computer identity")
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