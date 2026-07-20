import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge

@objc public class DeviceConfiguration: NSObject {

    // openBLEDevice is already a fully blocking call (open_ble_device_with_
    // identification polls internally until success/failure/timeout), but
    // nothing previously stopped two independent callers — e.g. a host app's
    // own connect path and a reactive re-trigger elsewhere — from entering
    // it concurrently and racing on the same underlying CoreBluetooth/
    // libdivecomputer connection state. Guard entry with a hard lock so at
    // most one connection attempt is ever in flight, regardless of who calls
    // it or from which thread.
    private static let connectionLock = NSLock()

    // Helper struct for UI Selection
    public struct ComputerModel: Identifiable, Hashable {
        public let id = UUID()
        public let name: String
        public let family: DeviceFamily
        public let modelID: UInt32
        
        public static func == (lhs: ComputerModel, rhs: ComputerModel) -> Bool {
            return lhs.family == rhs.family && lhs.modelID == rhs.modelID
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(family)
            hasher.combine(modelID)
        }
    }
    
    // List of selectable models for the UI
    public static let supportedModels: [ComputerModel] = [
        // Shearwater computers
        ComputerModel(name: "Shearwater Peregrine", family: .shearwaterPetrel, modelID: 9),
        ComputerModel(name: "Shearwater Peregrine TX", family: .shearwaterPetrel, modelID: 13),
        ComputerModel(name: "Shearwater Petrel", family: .shearwaterPetrel, modelID: 3),
        ComputerModel(name: "Shearwater Petrel 2", family: .shearwaterPetrel, modelID: 3),
        ComputerModel(name: "Shearwater Petrel 3", family: .shearwaterPetrel, modelID: 10),
        ComputerModel(name: "Shearwater Perdix", family: .shearwaterPetrel, modelID: 5),
        ComputerModel(name: "Shearwater Perdix AI", family: .shearwaterPetrel, modelID: 6),
        ComputerModel(name: "Shearwater Perdix 2", family: .shearwaterPetrel, modelID: 11),
        // TODO: the vendored libdivecomputer doesn't have a descriptor table entry for
        // model 14 yet (Perdix 3 support is still in progress upstream), so
        // find_descriptor_by_model will fail and device open/parsing won't work until
        // libdivecomputer/src/descriptor.c picks up a "Shearwater"/"Perdix 3" entry.
        ComputerModel(name: "Shearwater Perdix 3", family: .shearwaterPetrel, modelID: 14),
        ComputerModel(name: "Shearwater Teric", family: .shearwaterPetrel, modelID: 8),
        ComputerModel(name: "Shearwater Tern", family: .shearwaterPetrel, modelID: 12),
        ComputerModel(name: "Shearwater NERD 2", family: .shearwaterPetrel, modelID: 7),
        
        // Suunto computers
        ComputerModel(name: "Suunto EON Steel", family: .suuntoEonSteel, modelID: 0),
        ComputerModel(name: "Suunto EON Core", family: .suuntoEonSteel, modelID: 1),
        ComputerModel(name: "Suunto D5", family: .suuntoEonSteel, modelID: 2),
        ComputerModel(name: "Suunto EON Steel Black", family: .suuntoEonSteel, modelID: 3),
        
        // Scubapro / Uwatec computers
        ComputerModel(name: "Scubapro G2", family: .uwatecSmart, modelID: 0x32),
        ComputerModel(name: "Scubapro G2 TEK", family: .uwatecSmart, modelID: 0x31),
        ComputerModel(name: "Scubapro G2 Console", family: .uwatecSmart, modelID: 0x32),
        ComputerModel(name: "Scubapro G2 HUD", family: .uwatecSmart, modelID: 0x42),
        ComputerModel(name: "Scubapro G3", family: .uwatecSmart, modelID: 0x34),
        ComputerModel(name: "Scubapro Aladin A1", family: .uwatecSmart, modelID: 0x25),
        ComputerModel(name: "Scubapro Aladin A2", family: .uwatecSmart, modelID: 0x28),
        ComputerModel(name: "Scubapro Luna 2.0", family: .uwatecSmart, modelID: 0x51),
        ComputerModel(name: "Scubapro Luna 2.0 AI", family: .uwatecSmart, modelID: 0x50),
        
        // Heinrichs Weikamp computers
        ComputerModel(name: "Heinrichs Weikamp OSTC 3", family: .hwOstc3, modelID: 0x0A),
        ComputerModel(name: "Heinrichs Weikamp OSTC 4", family: .hwOstc3, modelID: 0x3B),
        ComputerModel(name: "Heinrichs Weikamp OSTC Plus", family: .hwOstc3, modelID: 0x13),
        ComputerModel(name: "Heinrichs Weikamp OSTC 2", family: .hwOstc3, modelID: 0x11),
        ComputerModel(name: "Heinrichs Weikamp OSTC Sport", family: .hwOstc3, modelID: 0x12),
        ComputerModel(name: "Heinrichs Weikamp OSTC 2 TR", family: .hwOstc3, modelID: 0x33),
        
        // Oceanic / Aeris / Sherwood / Hollis computers
        ComputerModel(name: "Oceanic Geo 4.0", family: .oceanicAtom2, modelID: 0x4653),
        ComputerModel(name: "Oceanic Veo 4.0", family: .oceanicAtom2, modelID: 0x4654),
        ComputerModel(name: "Oceanic Pro Plus 4", family: .oceanicAtom2, modelID: 0x4656),
        ComputerModel(name: "Oceanic Atom 3.1", family: .oceanicAtom2, modelID: 0x4456),
        ComputerModel(name: "Oceanic Geo Air", family: .oceanicAtom2, modelID: 0x474B),
        ComputerModel(name: "Aqualung i770R", family: .oceanicAtom2, modelID: 0x4651),
        ComputerModel(name: "Aqualung i550C", family: .oceanicAtom2, modelID: 0x4652),
        ComputerModel(name: "Aqualung i300C", family: .oceanicAtom2, modelID: 0x4648),
        ComputerModel(name: "Aqualung i200C", family: .oceanicAtom2, modelID: 0x4649),
        ComputerModel(name: "Sherwood Wisdom 3", family: .oceanicAtom2, modelID: 0x4458),
        ComputerModel(name: "Sherwood Sage", family: .oceanicAtom2, modelID: 0x4647),
        
        // Pelagic Pressure Systems (Oceanic, Aqua Lung, Sherwood, Tusa)
        ComputerModel(name: "Aqualung i330R", family: .pelagicI330R, modelID: 0x4744),
        ComputerModel(name: "Aqualung i330R Console", family: .pelagicI330R, modelID: 0x474D),
        ComputerModel(name: "Apeks DSX", family: .pelagicI330R, modelID: 0x4741),
        
        // Mares computers
        ComputerModel(name: "Mares Icon HD", family: .maresIconHD, modelID: 0x14),
        ComputerModel(name: "Mares Puck Pro", family: .maresIconHD, modelID: 0x18),
        ComputerModel(name: "Mares Smart", family: .maresIconHD, modelID: 0x000010),
        ComputerModel(name: "Mares Quad", family: .maresIconHD, modelID: 0x29),
        ComputerModel(name: "Mares Quad Air", family: .maresIconHD, modelID: 0x23),
        ComputerModel(name: "Mares Smart Air", family: .maresIconHD, modelID: 0x24),
        ComputerModel(name: "Mares Genius", family: .maresIconHD, modelID: 0x1C),
        ComputerModel(name: "Mares Puck 4", family: .maresIconHD, modelID: 0x35),
        
        // DeepSix computers
        ComputerModel(name: "Deep Six Excursion", family: .deepsixExcursion, modelID: 0),
        
        // Deepblu computers
        ComputerModel(name: "Deepblu Cosmiq+", family: .deepbluCosmiq, modelID: 0),
        
        // Oceans computers
        ComputerModel(name: "Oceans S1", family: .oceansS1, modelID: 0),
        
        // McLean computers
        ComputerModel(name: "McLean Extreme", family: .mcleanExtreme, modelID: 0),
        
        // Divesoft computers
        ComputerModel(name: "Divesoft Freedom", family: .divesoftFreedom, modelID: 19),
        ComputerModel(name: "Divesoft Liberty", family: .divesoftFreedom, modelID: 10),
        
        // Cressi computers
        ComputerModel(name: "Cressi Goa", family: .cressiGoa, modelID: 2),
        ComputerModel(name: "Cressi Cartesio", family: .cressiGoa, modelID: 1),
        ComputerModel(name: "Cressi Leonardo 2.0", family: .cressiGoa, modelID: 3),
        ComputerModel(name: "Cressi Donatello", family: .cressiGoa, modelID: 4),
        
        // Dive System / Ratio computers
        ComputerModel(name: "DiveSystem iDive Easy", family: .diveSystem, modelID: 0x09),
        ComputerModel(name: "DiveSystem iDive Free", family: .diveSystem, modelID: 0x08),
        ComputerModel(name: "DiveSystem iDive Deep", family: .diveSystem, modelID: 0x0B),
        ComputerModel(name: "Ratio iDive 2 Easy", family: .diveSystem, modelID: 0x82),
        ComputerModel(name: "Ratio iDive 2 Free", family: .diveSystem, modelID: 0x80),
        ComputerModel(name: "Ratio iDive 2 Deep", family: .diveSystem, modelID: 0x84),
        ComputerModel(name: "Ratio iDive Color Easy", family: .diveSystem, modelID: 0x52),
        ComputerModel(name: "Ratio iDive Color Free", family: .diveSystem, modelID: 0x50),
        ComputerModel(name: "Ratio iDive Color Deep", family: .diveSystem, modelID: 0x54),

        // Seac computers
        ComputerModel(name: "Seac Tablet", family: .seacScreen, modelID: 0x10),

        // Halcyon computers
        ComputerModel(name: "Halcyon Symbios HUD",     family: .halcyonSymbios, modelID: 1),
        ComputerModel(name: "Halcyon Symbios Handset", family: .halcyonSymbios, modelID: 7),
    ]

    /// Represents the family of dive computers that support BLE communication.
    public enum DeviceFamily: String, Codable, CaseIterable {
        case suuntoEonSteel
        case shearwaterPetrel
        case hwOstc3
        case uwatecSmart
        case oceanicAtom2
        case pelagicI330R
        case maresIconHD
        case deepsixExcursion
        case deepbluCosmiq
        case oceansS1
        case mcleanExtreme
        case divesoftFreedom
        case cressiGoa
        case diveSystem
        case seacScreen
        case halcyonSymbios

        /// Converts the Swift enum to libdivecomputer's dc_family_t type
        public var asDCFamily: dc_family_t {
            switch self {
            case .suuntoEonSteel: return DC_FAMILY_SUUNTO_EONSTEEL
            case .shearwaterPetrel: return DC_FAMILY_SHEARWATER_PETREL
            case .hwOstc3: return DC_FAMILY_HW_OSTC3
            case .uwatecSmart: return DC_FAMILY_UWATEC_SMART
            case .oceanicAtom2: return DC_FAMILY_OCEANIC_ATOM2
            case .pelagicI330R: return DC_FAMILY_PELAGIC_I330R
            case .maresIconHD: return DC_FAMILY_MARES_ICONHD
            case .deepsixExcursion: return DC_FAMILY_DEEPSIX_EXCURSION
            case .deepbluCosmiq: return DC_FAMILY_DEEPBLU_COSMIQ
            case .oceansS1: return DC_FAMILY_OCEANS_S1
            case .mcleanExtreme: return DC_FAMILY_MCLEAN_EXTREME
            case .divesoftFreedom: return DC_FAMILY_DIVESOFT_FREEDOM
            case .cressiGoa: return DC_FAMILY_CRESSI_GOA
            case .diveSystem: return DC_FAMILY_DIVESYSTEM_IDIVE
            case .seacScreen: return DC_FAMILY_SEAC_SCREEN
            case .halcyonSymbios: return DC_FAMILY_HALCYON_SYMBIOS
            }
        }

        /// Creates a DeviceFamily instance from libdivecomputer's dc_family_t type
        init?(dcFamily: dc_family_t) {
            switch dcFamily {
            case DC_FAMILY_SUUNTO_EONSTEEL: self = .suuntoEonSteel
            case DC_FAMILY_SHEARWATER_PETREL: self = .shearwaterPetrel
            case DC_FAMILY_HW_OSTC3: self = .hwOstc3
            case DC_FAMILY_UWATEC_SMART: self = .uwatecSmart
            case DC_FAMILY_OCEANIC_ATOM2: self = .oceanicAtom2
            case DC_FAMILY_PELAGIC_I330R: self = .pelagicI330R
            case DC_FAMILY_MARES_ICONHD: self = .maresIconHD
            case DC_FAMILY_DEEPSIX_EXCURSION: self = .deepsixExcursion
            case DC_FAMILY_DEEPBLU_COSMIQ: self = .deepbluCosmiq
            case DC_FAMILY_OCEANS_S1: self = .oceansS1
            case DC_FAMILY_MCLEAN_EXTREME: self = .mcleanExtreme
            case DC_FAMILY_DIVESOFT_FREEDOM: self = .divesoftFreedom
            case DC_FAMILY_CRESSI_GOA: self = .cressiGoa
            case DC_FAMILY_DIVESYSTEM_IDIVE: self = .diveSystem
            case DC_FAMILY_SEAC_SCREEN: self = .seacScreen
            case DC_FAMILY_HALCYON_SYMBIOS: self = .halcyonSymbios
            default: return nil
            }
        }
    }
    
    /// Known BLE service UUIDs for supported dive computers.
    private static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "0000fefb-0000-1000-8000-00805f9b34fb"), // Heinrichs-Weikamp Telit/Stollmann
        CBUUID(string: "2456e1b9-26e2-8f83-e744-f34f01e9d701"), // Heinrichs-Weikamp U-Blox
        CBUUID(string: "544e326b-5b72-c6b0-1c46-41c1bc448118"), // Mares BlueLink Pro
        CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e"), // Nordic Semi UART
        CBUUID(string: "98ae7120-e62e-11e3-badd-0002a5d5c51b"), // Suunto EON Steel/Core
        CBUUID(string: "cb3c4555-d670-4670-bc20-b61dbc851e9a"), // Pelagic i770R/i200C
        CBUUID(string: "ca7b0001-f785-4c38-b599-c7c5fbadb034"), // Pelagic i330R/DSX
        CBUUID(string: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0"), // ScubaPro G2/G3
        CBUUID(string: "fe25c237-0ece-443c-b0aa-e02033e7029d"), // Shearwater Perdix/Teric
        CBUUID(string: "1aa44039-1667-4b29-87cc-dfecaaf31d97"), // Shearwater Perdix 3 (TODO: no libdivecomputer descriptor entry yet, see supportedModels)
        CBUUID(string: "0000fcef-0000-1000-8000-00805f9b34fb"), // Divesoft Freedom
        CBUUID(string: "00000001-8c3b-4f2c-a59e-8c08224f3253"), // Halcyon Symbios
        CBUUID(string: "84968ffe-d26d-478a-b953-5010bcf58bca")  // Seac Screen
    ]
    
    public static func getKnownServiceUUIDs() -> [CBUUID] {
        return knownServiceUUIDs
    }

    /// Attempts to open a BLE connection to a dive computer. Serialized via
    /// connectionLock — see its declaration for why.
    public static func openBLEDevice(
        name: String,
        deviceAddress: String,
        forcedModel: (family: DeviceFamily, model: UInt32)? = nil
    ) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return openBLEDeviceLocked(name: name, deviceAddress: deviceAddress, forcedModel: forcedModel)
    }

    private static func openBLEDeviceLocked(
        name: String,
        deviceAddress: String,
        forcedModel: (family: DeviceFamily, model: UInt32)?
    ) -> Bool {
        logDebug("Attempting to open BLE device: \(name) at address: \(deviceAddress)")

        // Set connecting flag to prevent auto-reconnect during connection attempt
        DispatchQueue.main.async {
            if let manager = CoreBluetoothManager.shared() as? CoreBluetoothManager {
                manager.isConnecting = true
            }
        }

        var deviceData: UnsafeMutablePointer<device_data_t>?
        let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress)

        if let storedDevice = storedDevice {
            logDebug("Found stored device configuration - Family: \(storedDevice.family), Model: \(storedDevice.model)")
        }

        // Determine which configuration to use: Forced > Stored > Auto-detect from name > Default(0)
        let familyToUse: dc_family_t
        let modelToUse: UInt32

        if let forced = forcedModel {
            familyToUse = forced.family.asDCFamily
            modelToUse = forced.model
            logInfo("Using forced configuration: \(forced.family) Model: \(forced.model)")
        } else if let stored = storedDevice {
            familyToUse = stored.family.asDCFamily
            modelToUse = stored.model
        } else if let detected = fromName(name) {
            // Auto-detect from device name BEFORE opening
            familyToUse = detected.family.asDCFamily
            modelToUse = detected.model
            logInfo("Auto-detected configuration from name '\(name)': \(detected.family) Model: \(detected.model)")
        } else {
            familyToUse = DC_FAMILY_NULL
            modelToUse = 0
            logWarning("⚠️ Could not determine device configuration for '\(name)', opening with defaults")
        }

        let status = open_ble_device_with_identification(
            &deviceData,
            name,
            deviceAddress,
            familyToUse,
            modelToUse
        )

        if status == DC_STATUS_SUCCESS, let data = deviceData {
            logDebug("Successfully opened device")
            logDebug("Device data pointer allocated at: \(String(describing: data))")

            // Store the configuration for future connections
            if let forced = forcedModel {
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: name,
                    family: forced.family,
                    model: forced.model
                )
            } else if storedDevice == nil, let detected = fromName(name) {
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: name,
                    family: detected.family,
                    model: detected.model
                )
            }

            DispatchQueue.main.async {
                if let manager = CoreBluetoothManager.shared() as? CoreBluetoothManager {
                    manager.openedDeviceDataPtr = data
                    manager.isConnecting = false // Clear connecting flag on success
                }
            }
            return true
        }

        logError("Failed to open device (status: \(status))")
        // Clear connecting flag on failure
        DispatchQueue.main.async {
            if let manager = CoreBluetoothManager.shared() as? CoreBluetoothManager {
                manager.isConnecting = false
            }
        }
        if let data = deviceData {
            data.deallocate()
        }
        return false
    }
    
    /// Fetches device info (serial, model, firmware) by starting and immediately stopping dive enumeration
    /// This triggers the device to send its devinfo event without downloading any dives
    public static func fetchDeviceInfo(
        deviceDataPtr: UnsafeMutablePointer<device_data_t>,
        completion: @escaping (Bool) -> Void
    ) {
        // Check if we already have device info
        if deviceDataPtr.pointee.have_devinfo != 0 {
            logDebug("Device info already available")
            completion(true)
            return
        }
        
        guard let dcDevice = deviceDataPtr.pointee.device else {
            logError("No device connection found")
            completion(false)
            return
        }
        
        logInfo("📍 Fetching device info...")
        
        // Create a minimal callback that returns 0 immediately to stop enumeration
        // This will trigger the device to send devinfo but won't download any dives
        let minimalCallback: @convention(c) (
            UnsafePointer<UInt8>?,
            UInt32,
            UnsafePointer<UInt8>?,
            UInt32,
            UnsafeMutableRawPointer?
        ) -> Int32 = { _, _, _, _, _ in
            // Return 0 to stop enumeration immediately
            return 0
        }
        
        let retrievalQueue = DispatchQueue(label: "com.libdcswift.deviceinfo", qos: .userInitiated)
        retrievalQueue.async {
            // Call dc_device_foreach with our minimal callback
            // This will trigger DC_EVENT_DEVINFO but stop before downloading any dives
            let status = dc_device_foreach(dcDevice, minimalCallback, nil)
            
            DispatchQueue.main.async {
                if status == DC_STATUS_SUCCESS || status == DC_STATUS_PROTOCOL {
                    // DC_STATUS_PROTOCOL is expected when we return 0 from callback
                    if deviceDataPtr.pointee.have_devinfo != 0 {
                        let serial = String(format: "%08x", deviceDataPtr.pointee.devinfo.serial)
                        let model = deviceDataPtr.pointee.devinfo.model
                        logInfo("✅ Device info fetched - Serial: \(serial), Model: \(model)")
                        completion(true)
                    } else {
                        logWarning("⚠️ Device info not available after enumeration")
                        completion(false)
                    }
                } else {
                    logError("❌ Failed to fetch device info: \(status)")
                    completion(false)
                }
            }
        }
    }
    
    // Updates stored device configuration with actual device info from hardware ID
    public static func updateDeviceConfigurationFromHardware(
        deviceAddress: String,
        deviceDataPtr: UnsafeMutablePointer<device_data_t>,
        deviceName: String
    ) {
        guard deviceDataPtr.pointee.have_devinfo != 0 else {
            logDebug("Device info not yet available for \(deviceName)")
            return
        }
        
        let actualModel = deviceDataPtr.pointee.devinfo.model
        
        if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress) {
            if storedDevice.model != actualModel {
                logInfo("🔄 Updating stored device model from \(storedDevice.model) to actual model \(actualModel) for \(deviceName)")
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: deviceName,
                    family: storedDevice.family,
                    model: actualModel
                )
            }
        } else if let deviceInfo = fromName(deviceName) {
            if deviceInfo.model != actualModel {
                logInfo("🔄 Storing device with actual model \(actualModel) (name suggested \(deviceInfo.model)) for \(deviceName)")
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: deviceName,
                    family: deviceInfo.family,
                    model: actualModel
                )
            }
        }
    }
    
    public static func fromName(_ name: String) -> (family: DeviceFamily, model: UInt32)? {
        // Oceanic/Aqualung/Sherwood devices advertise their serial number as the BLE name
        // (e.g. "FH020399"), which find_descriptor_by_name can't match against a product
        // name. Try the serial-derived model code first.
        if let result = resolveOceanicBLEName(name) {
            return result
        }

        var descriptor: OpaquePointer?
        let rc = find_descriptor_by_name(&descriptor, name)
        if rc == DC_STATUS_SUCCESS, let desc = descriptor {
            let family = dc_descriptor_get_type(desc)
            let model = dc_descriptor_get_model(desc)
            if let deviceFamily = DeviceFamily(dcFamily: family) {
                dc_descriptor_free(desc)
                return (deviceFamily, model)
            }
            dc_descriptor_free(desc)
        }
        return nil
    }

    /// Resolves an Oceanic/Aqualung/Sherwood BLE advertisement name (the device's serial
    /// number, e.g. "FH020399") to a model. The first two characters are ASCII and encode
    /// the model ID as (hi << 8) | lo; the remaining characters are decimal digits.
    private static func resolveOceanicBLEName(_ name: String) -> (family: DeviceFamily, model: UInt32)? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2 else { return nil }

        let hi = scalars[0].value
        let lo = scalars[1].value
        guard (0x20...0x7E).contains(hi), (0x20...0x7E).contains(lo) else { return nil }

        for i in 2..<scalars.count {
            guard (0x30...0x39).contains(scalars[i].value) else { return nil }
        }

        let modelID = UInt32((hi << 8) | lo)
        return supportedModels.first(where: {
            ($0.family == .oceanicAtom2 || $0.family == .pelagicI330R) && $0.modelID == modelID
        }).map { (family: $0.family, model: $0.modelID) }
    }
    
    public static func getDeviceDisplayName(from name: String) -> String {
        if let cString = get_formatted_device_name(name) {
            defer { free(cString) }
            return String(cString: cString)
        }
        return name
    }
    
    private var descriptor: OpaquePointer?
    private static var context: OpaquePointer?
    
    public static func setupContext() {
        if context == nil {
            let rc = dc_context_new(&context)
            if rc != DC_STATUS_SUCCESS {
                logError("Failed to create dive computer context")
            }
        }
    }
    
    public static func cleanupContext() {
        if let ctx = context {
            dc_context_free(ctx)
            context = nil
        }
    }
    
    public static func createParser(family: dc_family_t, model: UInt32, data: Data) -> OpaquePointer? {
        guard let context = context else {
            logError("No dive computer context available")
            return nil
        }
        
        var parser: OpaquePointer?
        let rc = create_parser_for_device(
            &parser,
            context,
            family,
            model,
            [UInt8](data),
            data.count
        )
        if rc != DC_STATUS_SUCCESS {
            logError("Failed to create parser: \(rc)")
            return nil
        }
        return parser
    }
}