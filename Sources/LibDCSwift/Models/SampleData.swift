import Foundation
import Clibdivecomputer
import LibDCBridge

public struct SampleData {
    // Basic dive data
    var time: TimeInterval = 0          // Time in seconds
    var depth: Double = 0               // Depth in meters
    var temperature: Double?            // Temperature in Celsius
    var divetime: TimeInterval = 0      // Total dive time
    var maxDepth: Double = 0           // Maximum depth reached
    var avgDepth: Double = 0           // Average depth
    var lastTemperature: Double = 0    // Last recorded temperature
    var maxTime: TimeInterval = 0  // Track the maximum time
    
    // Temperature tracking
    var tempSurface: Double = 0        // Surface temperature
    var tempMinimum: Double = Double.infinity  // Minimum temperature
    var tempMaximum: Double = -Double.infinity // Maximum temperature
    
    // Tank pressure data
    var pressure: [(tank: Int, value: Double)] = []  // Tank pressure readings
    
    // Profile data
    var profile: [DiveProfilePoint] = []  // Detailed dive profile
    
    // Gas mix data
    var gasmix: Int?                    // Current gas mix index
    var gasMixes: [GasMix] = []         // All gas mixes used
    
    // Environmental data
    var atmospheric: Double = 1.0       // Atmospheric pressure
    var salinity: Double?              // Water salinity
    
    // Tank information
    var tanks: [DiveData.Tank] = []    // Tank information
    
    // Dive mode and model
    var diveMode: DiveData.DiveMode = .openCircuit
    var decoModel: DiveData.DecoModel? // Decompression model
    
    // Location data
    var location: DiveData.Location?    // GPS location if available
    
    // Additional sensor data
    var rbt: UInt32?                    // Remaining bottom time
    var heartbeat: UInt32?              // Heart rate
    var bearing: UInt32?                // Compass bearing
    
    // Rebreather data
    var setpoint: Double?               // Setpoint value
    var ppo2: [(sensor: UInt32, value: Double)] = []  // PPO2 readings
    var cns: Double?                    // CNS percentage
    
    // Events and warnings
    var event: Event?
    
    // Decompression data
    var deco: DecoData?

    // Vendor-specific samples (DC_SAMPLE_VENDOR): (time, vendor type, raw bytes)
    var vendorSamples: [DiveData.VendorSample] = []

    public struct Event {
        let type: parser_sample_event_t  // Event type from libdivecomputer
        let value: UInt32               // Event specific value
        let flags: UInt32               // Event flags (begin/end)
    }
    
    public struct DecoData {
        var type: dc_deco_type_t        // Type of deco stop
        var depth: Double               // Stop depth in meters
        var time: UInt32                // Stop time in seconds
        var tts: UInt32                 // Time to surface
    }
} 