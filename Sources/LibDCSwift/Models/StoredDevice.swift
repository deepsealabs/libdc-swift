import Foundation

extension Notification.Name {
    public static let deviceForgotten = Notification.Name("com.libdc.deviceForgotten")
}

public class StoredDevice: Codable {
   public let uuid: String
   public let name: String
   public let family: DeviceConfiguration.DeviceFamily
   public let model: UInt32
   public let lastConnected: Date
   public var serial: String?  // Hardware serial number for fingerprint tracking
   public var firmware: String?  // Firmware version reported via DC_EVENT_DEVINFO
   /// nil on records stored before cable transports, which are all BLE.
   public let transport: DCTransport?
   /// `DiveComputerLocator.locatorKey` of the last connection: provenance only, never how the record is found.
   public var locatorKey: String?

   public init(uuid: String, name: String, family: DeviceConfiguration.DeviceFamily, model: UInt32, serial: String? = nil, firmware: String? = nil,
               transport: DCTransport? = nil, locatorKey: String? = nil) {
       self.uuid = uuid
       self.name = name
       self.family = family
       self.model = model
       self.lastConnected = Date()
       self.serial = serial
       self.firmware = firmware
       self.transport = transport
       self.locatorKey = locatorKey
   }

   /// `transport`, with a record from before transports read as BLE.
   public var effectiveTransport: DCTransport { transport ?? .ble }

   private enum CodingKeys: String, CodingKey {
       case uuid
       case name
       case family
       case model
       case lastConnected
       case serial
       case firmware
       case transport
       case locatorKey
   }

   public required init(from decoder: Decoder) throws {
       let container = try decoder.container(keyedBy: CodingKeys.self)
       uuid = try container.decode(String.self, forKey: .uuid)
       name = try container.decode(String.self, forKey: .name)
       family = try container.decode(DeviceConfiguration.DeviceFamily.self, forKey: .family)
       model = try container.decode(UInt32.self, forKey: .model)
       lastConnected = try container.decode(Date.self, forKey: .lastConnected)
       serial = try container.decodeIfPresent(String.self, forKey: .serial)  // Optional for backward compatibility
       firmware = try container.decodeIfPresent(String.self, forKey: .firmware)  // Optional for backward compatibility
       transport = try container.decodeIfPresent(DCTransport.self, forKey: .transport)
       locatorKey = try container.decodeIfPresent(String.self, forKey: .locatorKey)
   }

   public func encode(to encoder: Encoder) throws {
       var container = encoder.container(keyedBy: CodingKeys.self)
       try container.encode(uuid, forKey: .uuid)
       try container.encode(name, forKey: .name)
       try container.encode(family, forKey: .family)
       try container.encode(model, forKey: .model)
       try container.encode(lastConnected, forKey: .lastConnected)
       try container.encodeIfPresent(serial, forKey: .serial)
       try container.encodeIfPresent(firmware, forKey: .firmware)
       try container.encodeIfPresent(transport, forKey: .transport)
       try container.encodeIfPresent(locatorKey, forKey: .locatorKey)
   }
}

/// Decodes one array element without throwing, so a record this version can't read (a newer family, say) drops alone.
private struct LossyStoredDevice: Decodable {
   let device: StoredDevice?

   init(from decoder: Decoder) throws {
       do {
           device = try StoredDevice(from: decoder)
       } catch {
           logWarning("Skipping a stored device this version can't read: \(error)")
           device = nil
       }
   }
}

@objc public class DeviceStorage: NSObject {
   public static let shared = DeviceStorage()
   
   private let defaults: UserDefaults
   private let storageKey = "com.libdc.storedDevices"
   private let fingerprints: DeviceFingerprintStorage

   private var storedDevices: [StoredDevice] = []

   /// Test seam: an isolated suite instead of `.standard`.
   init(userDefaults: UserDefaults = .standard, fingerprints: DeviceFingerprintStorage = .shared) {
       self.defaults = userDefaults
       self.fingerprints = fingerprints
       super.init()
       loadDevices()
   }

   // ObjC parity: without this, `[[DeviceStorage alloc] init]` resolves to
   // NSObject's inherited -init instead of Swift's designated initializer.
   private override convenience init() {
       self.init(userDefaults: .standard)
   }
   
   static func decodeDevices(_ data: Data) throws -> [StoredDevice] {
       try JSONDecoder().decode([LossyStoredDevice].self, from: data).compactMap(\.device)
   }

   private func loadDevices() {
       if let data = defaults.data(forKey: storageKey) {
           do {
               let devices = try Self.decodeDevices(data)
               storedDevices = devices
               logDebug("Loaded \(devices.count) devices from UserDefaults")
           } catch {
               logError("Failed to decode stored devices: \(error)")
           }
       } else {
           logDebug("No stored devices data found in UserDefaults")
       }
   }
   
   private func saveDevices() {
       do {
           let data = try JSONEncoder().encode(storedDevices)
           defaults.set(data, forKey: storageKey)
           defaults.synchronize() // Force immediate save
           logDebug("Saved \(storedDevices.count) devices to UserDefaults")
       } catch {
           logError("Failed to save devices: \(error)")
       }
   }
   
   public func storeDevice(uuid: String, name: String, family: DeviceConfiguration.DeviceFamily, model: UInt32, serial: String? = nil,
                           transport: DCTransport? = nil, locatorKey: String? = nil) {
       let device = StoredDevice(uuid: uuid, name: name, family: family, model: model, serial: serial,
                                 transport: transport, locatorKey: locatorKey)
       if let index = storedDevices.firstIndex(where: { $0.uuid == uuid }) {
           // Preserve existing serial/firmware/transport/locator if new ones not provided
           let existing = storedDevices[index]
           let deviceWithSerial = StoredDevice(uuid: uuid, name: name, family: family, model: model, serial: serial ?? existing.serial,
                                               firmware: existing.firmware, transport: transport ?? existing.transport,
                                               locatorKey: locatorKey ?? existing.locatorKey)
           storedDevices[index] = deviceWithSerial
           logDebug("Updated stored device: \(name)")
       } else {
           storedDevices.append(device)
           logDebug("Added new stored device: \(name)")
       }
       saveDevices()

       // Verify storage
       if let stored = getStoredDevice(uuid: uuid) {
           logDebug("Successfully stored device: \(stored.name)")
       } else {
           logError("Failed to store device: \(name)")
       }
   }

   /// Reconciles a stored device whose CBPeripheral UUID has rotated (iOS
   /// can reassign a peripheral's identifier across sessions, e.g. after a
   /// Suunto Nautic re-pairs). When a device is seen by `name` under
   /// `newUUID` but the stored record for that name is under a different
   /// UUID, migrate the record to `newUUID` (preserving family/model/serial)
   /// so auto-reconnect by stored UUID keeps working. The name carries the
   /// device serial, so it identifies one physical device. Returns true if a
   /// record was migrated. Only BLE records move: a cable record of the same
   /// name is a different connection to keep.
   @discardableResult
   public func reconcileUUID(name: String, newUUID: String) -> Bool {
       // Already stored under the current UUID -- nothing to do.
       if storedDevices.contains(where: { $0.uuid == newUUID }) {
           return false
       }
       guard let index = storedDevices.firstIndex(where: { $0.name == name && $0.effectiveTransport == .ble }) else {
           return false
       }
       let old = storedDevices[index]
       storedDevices[index] = StoredDevice(uuid: newUUID, name: old.name, family: old.family, model: old.model, serial: old.serial, firmware: old.firmware,
                                           transport: old.transport, locatorKey: old.locatorKey)
       saveDevices()
       logInfo("Reconciled stored device \(name): UUID \(old.uuid) -> \(newUUID)")
       return true
   }

   /// Updates the serial number for an existing stored device
   public func updateDeviceSerial(uuid: String, serial: String) {
       if let index = storedDevices.firstIndex(where: { $0.uuid == uuid }) {
           storedDevices[index].serial = serial
           saveDevices()
           logDebug("Updated serial for device \(storedDevices[index].name): \(serial)")
       }
   }

   /// Updates the firmware version for an existing stored device
   public func updateDeviceFirmware(uuid: String, firmware: String) {
       if let index = storedDevices.firstIndex(where: { $0.uuid == uuid }) {
           storedDevices[index].firmware = firmware
           saveDevices()
           logDebug("Updated firmware for device \(storedDevices[index].name): \(firmware)")
       }
   }
   
   public func getStoredDevice(uuid: String) -> StoredDevice? {
       return storedDevices.first { $0.uuid == uuid }
   }

   /// The most recently connected record of this computer on any transport; nil for an unknown (empty or all-zero) serial, which many units share.
   public func storedDevice(family: DeviceConfiguration.DeviceFamily, serial: String) -> StoredDevice? {
       guard let wanted = DiveComputerIdentity.normalizedSerial(serial) else { return nil }
       return storedDevices
           .filter { $0.family == family && DiveComputerIdentity.normalizedSerial($0.serial) == wanted }
           .max { $0.lastConnected < $1.lastConnected }
   }
   
   public func removeDevice(uuid: String) {
       // Get device info before removing for fingerprint cleanup
       if let device = storedDevices.first(where: { $0.uuid == uuid }) {
           // Get the device type name for fingerprint lookup
           if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == device.model && $0.family == device.family }),
              let serial = device.serial {
               // Clear the fingerprint for this device
               fingerprints.clearFingerprint(forDeviceType: modelInfo.name, serial: serial)
               logInfo("🗑️ Cleared fingerprint for \(modelInfo.name) (serial: \(serial))")
           } else if device.serial == nil {
               // No serial stored - try to clear fingerprints matching the device type for any serial
               if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == device.model && $0.family == device.family }) {
                   logWarning("⚠️ Device has no serial stored - clearing all fingerprints for \(modelInfo.name)")
                   fingerprints.clearFingerprintsForDeviceType(modelInfo.name)
               } else {
                   logWarning("⚠️ Device has no serial stored and unknown model - fingerprint may not be cleared")
               }
           }
       }

       storedDevices.removeAll { $0.uuid == uuid }
       saveDevices()
       NotificationCenter.default.post(
           name: .deviceForgotten,
           object: nil,
           userInfo: ["deviceUUID": uuid]
       )
   }
   
   public func getLastConnectedDevice() -> StoredDevice? {
       return storedDevices.max(by: { $0.lastConnected < $1.lastConnected })
   }
   
   public func getAllStoredDevices() -> [StoredDevice]? {
       guard let data = defaults.data(forKey: storageKey) else {
           return nil
       }
       
       do {
           return try Self.decodeDevices(data)
       } catch {
           logError("Failed to decode stored devices: \(error)")
           return nil
       }
   }
   
   public func updateStoredDevices(_ devices: [StoredDevice]) {
       storedDevices = devices
       saveDevices()
   }
} 
