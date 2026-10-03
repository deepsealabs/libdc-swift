import Foundation
import Clibdivecomputer
import LibDCBridge
import SwiftUI

public enum DiveEvent: Hashable {
    case ascent
    case violation
    case decoStop
    case gasChange
    case bookmark
    case safetyStop(mandatory: Bool)
    case ceiling
    case po2
    case deepStop
    
    public var color: Color {
        switch self {
        case .ascent: return .red  // Warning color for ascent rate
        case .violation: return .red  // Warning color for violations
        case .decoStop: return .orange  // Important but not critical
        case .gasChange: return .blue  // Informational
        case .bookmark: return .yellow  // User marker
        case .safetyStop: return .green  // Good practice
        case .ceiling: return .red  // Warning color for ceiling violations
        case .po2: return .red  // Warning color for PPO2
        case .deepStop: return .purple  // Distinct from regular stops
        }
    }
    
    public var description: String {
        switch self {
        case .ascent: return "Ascent Rate Warning"
        case .violation: return "Violation"
        case .decoStop: return "Deco Stop Required"
        case .gasChange: return "Gas Mix Changed"
        case .bookmark: return "Bookmark"
        case .safetyStop(let mandatory): 
            return mandatory ? "Mandatory Safety Stop" : "Safety Stop"
        case .ceiling: return "Ceiling Violation"
        case .po2: return "PPO2 Warning"
        case .deepStop: return "Deep Stop"
        }
    }
    
    public var icon: String {
        switch self {
        case .ascent: return "exclamationmark.triangle"
        case .violation: return "exclamationmark.circle"
        case .decoStop: return "arrow.down.circle"
        case .gasChange: return "bubble.right"
        case .bookmark: return "bookmark"
        case .safetyStop: return "checkmark.circle"
        case .ceiling: return "arrow.up.circle"
        case .po2: return "aqi.high"
        case .deepStop: return "arrow.down.circle.fill"
        }
    }
}

/// An event exactly as libdivecomputer reported it through `DC_SAMPLE_EVENT`.
///
/// `DiveEvent` is a lossy, payload-free summary kept for compatibility; this
/// carries the full payload (type, value, flags) and covers every event type,
/// including ones `DiveEvent` has no case for.
public struct RawDiveEvent: Hashable {
    /// libdivecomputer's `parser_sample_event_t`, as a Swift enum.
    public enum EventType: Hashable {
        case none
        case decoStop
        case rbt
        case ascent
        case ceiling
        case workload
        case transmitter
        case violation
        case bookmark
        case surface
        case safetyStop
        case gasChange
        case safetyStopVoluntary
        case safetyStopMandatory
        case deepStop
        case ceilingSafetyStop
        /// Also libdivecomputer's `SAMPLE_EVENT_UNKNOWN`, which aliases `SAMPLE_EVENT_FLOOR`.
        case floor
        case diveTime
        case maxDepth
        case olf
        case po2
        case airTime
        case rgbm
        case heading
        case tissueLevel
        case gasChange2
        /// A type newer than this build knows about.
        case unknown(UInt32)

        public init(rawValue: UInt32) {
            switch rawValue {
            case SAMPLE_EVENT_NONE.rawValue: self = .none
            case SAMPLE_EVENT_DECOSTOP.rawValue: self = .decoStop
            case SAMPLE_EVENT_RBT.rawValue: self = .rbt
            case SAMPLE_EVENT_ASCENT.rawValue: self = .ascent
            case SAMPLE_EVENT_CEILING.rawValue: self = .ceiling
            case SAMPLE_EVENT_WORKLOAD.rawValue: self = .workload
            case SAMPLE_EVENT_TRANSMITTER.rawValue: self = .transmitter
            case SAMPLE_EVENT_VIOLATION.rawValue: self = .violation
            case SAMPLE_EVENT_BOOKMARK.rawValue: self = .bookmark
            case SAMPLE_EVENT_SURFACE.rawValue: self = .surface
            case SAMPLE_EVENT_SAFETYSTOP.rawValue: self = .safetyStop
            case SAMPLE_EVENT_GASCHANGE.rawValue: self = .gasChange
            case SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY.rawValue: self = .safetyStopVoluntary
            case SAMPLE_EVENT_SAFETYSTOP_MANDATORY.rawValue: self = .safetyStopMandatory
            case SAMPLE_EVENT_DEEPSTOP.rawValue: self = .deepStop
            case SAMPLE_EVENT_CEILING_SAFETYSTOP.rawValue: self = .ceilingSafetyStop
            case SAMPLE_EVENT_FLOOR.rawValue: self = .floor
            case SAMPLE_EVENT_DIVETIME.rawValue: self = .diveTime
            case SAMPLE_EVENT_MAXDEPTH.rawValue: self = .maxDepth
            case SAMPLE_EVENT_OLF.rawValue: self = .olf
            case SAMPLE_EVENT_PO2.rawValue: self = .po2
            case SAMPLE_EVENT_AIRTIME.rawValue: self = .airTime
            case SAMPLE_EVENT_RGBM.rawValue: self = .rgbm
            case SAMPLE_EVENT_HEADING.rawValue: self = .heading
            case SAMPLE_EVENT_TISSUELEVEL.rawValue: self = .tissueLevel
            case SAMPLE_EVENT_GASCHANGE2.rawValue: self = .gasChange2
            default: self = .unknown(rawValue)
            }
        }
    }

    /// Whether the event marks the start or end of a condition (`SAMPLE_FLAGS_BEGIN`/`END`).
    public enum Phase: Hashable {
        case none
        case begin
        case end
    }

    /// Raw `parser_sample_event_t` value.
    public let rawType: UInt32
    /// Type-specific payload; meaning varies by event type and vendor.
    public let value: UInt32
    /// Raw `parser_sample_flags_t` bits.
    public let flags: UInt32
    /// The event's own `time` field (seconds); only a few drivers set it, most leave 0.
    public let timeOffset: UInt32

    public var type: EventType { EventType(rawValue: rawType) }

    public var phase: Phase {
        if flags & SAMPLE_FLAGS_BEGIN.rawValue != 0 { return .begin }
        if flags & SAMPLE_FLAGS_END.rawValue != 0 { return .end }
        return .none
    }

    /// The compatibility `DiveEvent` for this type, or nil when it has no case.
    public var legacyEvent: DiveEvent? {
        switch type {
        case .ascent: return .ascent
        case .violation: return .violation
        case .decoStop: return .decoStop
        case .gasChange, .gasChange2: return .gasChange
        case .bookmark: return .bookmark
        case .safetyStop, .safetyStopVoluntary: return .safetyStop(mandatory: false)
        case .safetyStopMandatory: return .safetyStop(mandatory: true)
        case .ceiling: return .ceiling
        case .po2: return .po2
        case .deepStop: return .deepStop
        default: return nil
        }
    }

    public init(rawType: UInt32, value: UInt32, flags: UInt32, timeOffset: UInt32 = 0) {
        self.rawType = rawType
        self.value = value
        self.flags = flags
        self.timeOffset = timeOffset
    }
}

/// What a `DC_SAMPLE_DECO` sample describes (libdivecomputer's `dc_deco_type_t`).
public enum DecoKind: Hashable {
    case ndl
    case safetyStop
    case decoStop
    case deepStop

    public init?(rawValue: UInt32) {
        switch rawValue {
        case DC_DECO_NDL.rawValue: self = .ndl
        case DC_DECO_SAFETYSTOP.rawValue: self = .safetyStop
        case DC_DECO_DECOSTOP.rawValue: self = .decoStop
        case DC_DECO_DEEPSTOP.rawValue: self = .deepStop
        default: return nil
        }
    }
}

public struct DiveProfilePoint {
    public let time: TimeInterval
    public let depth: Double
    public let temperature: Double?
    public let pressure: Double?  // Primary (lowest-index) tank; convenience for single-tank dives
    public let tankPressures: [Int: Double]  // Live pressure (bar) per tank index; holds every transmitter of the sample
    public let po2: Double?  // Oxygen partial pressure
    // No dive computer reports inert-gas partial pressures; the parser never sets
    // these. Derive them from the gas mix instead.
    public let pn2: Double?
    public let phe: Double?
    public let events: [DiveEvent]
    /// Every `DC_SAMPLE_EVENT` reported in this sample, with its payload.
    public let rawEvents: [RawDiveEvent]

    // Deco data: only set on samples where the computer reported DC_SAMPLE_DECO.
    public let decoKind: DecoKind?    // What the deco sample describes
    public let ndl: UInt32?           // No-decompression limit (seconds); set when decoKind == .ndl
    public let decoStop: Double?      // Stop depth (meters); set for safety, deco and deep stops
    public let decoTime: UInt32?      // Stop time (seconds); set for safety, deco and deep stops
    public let tts: UInt32?           // Time to surface (seconds)

    // Gas data
    public let currentGas: Int?       // Current gas mix index
    public let cns: Double?           // CNS oxygen tracking (percentage)

    // Sensor data
    public let rbt: UInt32?           // Remaining bottom time (minutes)
    public let heartbeat: UInt32?     // Heart rate (bpm)
    public let bearing: UInt32?       // Compass heading (degrees)
    public let setpoint: Double?      // CCR setpoint

    public init(
        time: TimeInterval,
        depth: Double,
        temperature: Double? = nil,
        pressure: Double? = nil,
        tankPressures: [Int: Double] = [:],
        po2: Double? = nil,
        pn2: Double? = nil,
        phe: Double? = nil,
        events: [DiveEvent] = [],
        rawEvents: [RawDiveEvent] = [],
        decoKind: DecoKind? = nil,
        ndl: UInt32? = nil,
        decoStop: Double? = nil,
        decoTime: UInt32? = nil,
        tts: UInt32? = nil,
        currentGas: Int? = nil,
        cns: Double? = nil,
        rbt: UInt32? = nil,
        heartbeat: UInt32? = nil,
        bearing: UInt32? = nil,
        setpoint: Double? = nil
    ) {
        self.time = time
        self.depth = depth
        self.temperature = temperature
        self.pressure = pressure
        self.tankPressures = tankPressures
        self.po2 = po2
        self.pn2 = pn2
        self.phe = phe
        self.events = events
        self.rawEvents = rawEvents
        self.decoKind = decoKind
        self.ndl = ndl
        self.decoStop = decoStop
        self.decoTime = decoTime
        self.tts = tts
        self.currentGas = currentGas
        self.cns = cns
        self.rbt = rbt
        self.heartbeat = heartbeat
        self.bearing = bearing
        self.setpoint = setpoint
    }
}

public struct GasMix {
    public let helium: Double
    public let oxygen: Double
    public let nitrogen: Double
    public let usage: dc_usage_t
    
    public init(helium: Double, oxygen: Double, nitrogen: Double, usage: dc_usage_t) {
        self.helium = helium
        self.oxygen = oxygen
        self.nitrogen = nitrogen
        self.usage = usage
    }
}

public struct TankInfo {
    public let gasMix: Int  // Index to gas mix
    public let type: dc_tankvolume_t
    public let volume: Double
    public let workPressure: Double
    public let beginPressure: Double
    public let endPressure: Double
    public let usage: dc_usage_t
    
    public init(gasMix: Int, type: dc_tankvolume_t, volume: Double, workPressure: Double, 
               beginPressure: Double, endPressure: Double, usage: dc_usage_t) {
        self.gasMix = gasMix
        self.type = type
        self.volume = volume
        self.workPressure = workPressure
        self.beginPressure = beginPressure
        self.endPressure = endPressure
        self.usage = usage
    }
}

public struct DecoModel {
    public enum DecoType {
        case none
        case buhlmann
        case vpm
        case rgbm
        case dciem
        
        public var description: String {
            switch self {
            case .none: return "None"
            case .buhlmann: return "Bühlmann"
            case .vpm: return "VPM"
            case .rgbm: return "RGBM"
            case .dciem: return "DCIEM"
            }
        }
    }
    
    public let type: DecoType
    public let conservatism: Int
    public let gfLow: UInt32?
    public let gfHigh: UInt32?
    
    public var description: String {
        switch type {
        case .buhlmann:
            if let low = gfLow, let high = gfHigh {
                return "Bühlmann GF \(low)/\(high)"
            }
            return "Bühlmann"
        case .none:
            return "None"
        default:
            if conservatism != 0 {
                return "\(type.description) (\(conservatism))"
            } else {
                return type.description
            }
        }
    }
}

public struct Location {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    
    public init(latitude: Double, longitude: Double, altitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct DiveData: Identifiable {
    public let id = UUID()
    public var number: Int  // Mutable to allow renumbering after download (oldest = 1)
    public let datetime: Date
    
    // Basic dive data
    public var maxDepth: Double
    public var avgDepth: Double
    public var divetime: TimeInterval
    public var temperature: Double
    
    // Profile data
    public var profile: [DiveProfilePoint] 
    
    // Tank and gas data
    public var tankPressure: [Double]
    public var gasMix: Int?
    public var gasMixCount: Int?
    public var gasMixes: [GasMix]?
    
    // Environmental data
    public var salinity: Double?
    public var atmospheric: Double?
    public var surfaceTemperature: Double?
    public var minTemperature: Double?
    public var maxTemperature: Double?
    
    // Tank information
    public var tankCount: Int?
    public var tanks: [Tank]?
    
    // Dive mode and model
    public var diveMode: DiveMode?
    public var decoModel: DecoModel?
    
    // Location data
    public var location: Location?
    
    // Additional sensor data
    public var rbt: UInt32?
    public var heartbeat: UInt32?
    public var bearing: UInt32?
    
    // Rebreather data
    public var setpoint: Double?
    public var ppo2Readings: [(sensor: UInt32, value: Double)]
    public var cns: Double?
    
    // Decompression data
    public var decoStop: DecoStop?

    // Raw fingerprint bytes identifying the specific dive on the computer,
    // returned by dc_device_foreach's per-dive callback.
    public var fingerprint: Data?

    // Vendor-specific per-sample data that libdivecomputer has no dedicated
    // sample type for, delivered through DC_SAMPLE_VENDOR. Each entry is the
    // raw record the driver emitted (a vendor `type` tag plus opaque bytes) at
    // a given sample time; consumers that understand a given vendor/type decode
    // it themselves. Kept generic so any driver using the vendor channel
    // (e.g. Suunto Nautic battery/IMU/GPS-accuracy/gradient-factors) flows
    // through the standard pipeline instead of a family-specific bypass.
    public var vendorSamples: [VendorSample]

    public struct Tank {
        public var volume: Double
        public var workingPressure: Double
        public var beginPressure: Double
        public var endPressure: Double
        public var gasMix: Int
        public var usage: Usage
        
        public enum Usage {
            case none
            case oxygen
            case diluent
            case sidemount
        }
        
        public init(volume: Double, workingPressure: Double, beginPressure: Double, endPressure: Double, gasMix: Int, usage: Usage) {
            self.volume = volume
            self.workingPressure = workingPressure
            self.beginPressure = beginPressure
            self.endPressure = endPressure
            self.gasMix = gasMix
            self.usage = usage
        }
    }
    
    /// A DC_SAMPLE_VENDOR record: an opaque vendor-tagged payload at a sample
    /// time. `type` is libdivecomputer's `parser_sample_vendor_t` value
    /// (e.g. SAMPLE_VENDOR_SUUNTO_NAUTIC); `data` is the raw bytes.
    public struct VendorSample {
        public let time: TimeInterval
        public let type: UInt32
        public let data: Data

        public init(time: TimeInterval, type: UInt32, data: Data) {
            self.time = time
            self.type = type
            self.data = data
        }
    }

    public struct DecoStop {
        public var depth: Double
        public var time: TimeInterval
        public var type: Int

        public init(depth: Double, time: TimeInterval, type: Int) {
            self.depth = depth
            self.time = time
            self.type = type
        }
    }
    
    public struct Location {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
        
        public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }
    }
    
    public enum DiveMode {
        case freedive
        case gauge
        case openCircuit
        case closedCircuit
        case semiClosedCircuit
        
        public var description: String {
            switch self {
            case .freedive: return "Freedive"
            case .gauge: return "Gauge"
            case .openCircuit: return "Open Circuit"
            case .closedCircuit: return "Closed Circuit"
            case .semiClosedCircuit: return "Semi-Closed Circuit"
            }
        }
    }
    
    public struct DecoModel {
        public var type: DecoType
        public var conservatism: Int
        public var gfLow: UInt32?
        public var gfHigh: UInt32?
        
        public enum DecoType {
            case none
            case buhlmann
            case vpm
            case rgbm
            case dciem
            
            public var description: String {
                switch self {
                case .none: return "None"
                case .buhlmann: return "Bühlmann"
                case .vpm: return "VPM"
                case .rgbm: return "RGBM"
                case .dciem: return "DCIEM"
                }
            }
        }
        
        public init(type: DecoType, conservatism: Int, gfLow: UInt32? = nil, gfHigh: UInt32? = nil) {
            self.type = type
            self.conservatism = conservatism
            self.gfLow = gfLow
            self.gfHigh = gfHigh
        }
        
        public var description: String {
            switch type {
            case .buhlmann:
                if let low = gfLow, let high = gfHigh {
                    return "Bühlmann GF \(low)/\(high)"
                }
                return "Bühlmann"
            case .none:
                return "None"
            default:
                if conservatism != 0 {
                    return "\(type.description) (\(conservatism))"
                } else {
                    return type.description
                }
            }
        }
    }
    
    public init(
        number: Int,
        datetime: Date,
        maxDepth: Double,
        avgDepth: Double,
        divetime: TimeInterval,
        temperature: Double,
        profile: [DiveProfilePoint],
        tankPressure: [Double],
        gasMix: Int?,
        gasMixCount: Int?,
        gasMixes: [GasMix]?,
        salinity: Double?,
        atmospheric: Double?,
        surfaceTemperature: Double?,
        minTemperature: Double?,
        maxTemperature: Double?,
        tankCount: Int?,
        tanks: [Tank]?,
        diveMode: DiveMode?,
        decoModel: DecoModel?,
        location: Location?,
        rbt: UInt32?,
        heartbeat: UInt32?,
        bearing: UInt32?,
        setpoint: Double?,
        ppo2Readings: [(sensor: UInt32, value: Double)],
        cns: Double?,
        decoStop: DecoStop?,
        fingerprint: Data? = nil,
        vendorSamples: [VendorSample] = []
    ) {
        self.number = number
        self.datetime = datetime
        self.maxDepth = maxDepth
        self.avgDepth = avgDepth
        self.divetime = divetime
        self.temperature = temperature
        self.profile = profile
        self.tankPressure = tankPressure
        self.gasMix = gasMix
        self.gasMixCount = gasMixCount
        self.gasMixes = gasMixes
        self.salinity = salinity
        self.atmospheric = atmospheric
        self.surfaceTemperature = surfaceTemperature
        self.minTemperature = minTemperature
        self.maxTemperature = maxTemperature
        self.tankCount = tankCount
        self.tanks = tanks
        self.diveMode = diveMode
        self.decoModel = decoModel
        self.location = location
        self.rbt = rbt
        self.heartbeat = heartbeat
        self.bearing = bearing
        self.setpoint = setpoint
        self.ppo2Readings = ppo2Readings
        self.cns = cns
        self.decoStop = decoStop
        self.fingerprint = fingerprint
        self.vendorSamples = vendorSamples
    }
}
