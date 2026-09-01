import Foundation
import Clibdivecomputer
import LibDCBridge

/// EXPERIMENTAL: raw protocol access + decoding for Suunto Nautic/Ocean
/// devices.
///
/// This family now also works through the normal
/// `DiveLogRetriever`/`GenericParser` pipeline: `dc_device_foreach()`
/// enumerates real dives, and `GenericParser` parses each one, taking a
/// fallback datetime from the dive fingerprint (the logbook id is the
/// dive's UNIX start time) for dives with no surface GPS fix, and carrying
/// the non-standard series (battery, IMU, GPS accuracy, gradient factors)
/// through the generic `DC_SAMPLE_VENDOR` channel into
/// `DiveData.vendorSamples`.
///
/// This explorer is complementary, not the only path: it exposes the raw
/// RPC primitives for interactive protocol work, a cheap `listDives`
/// (same `/Logbook/Entries` endpoint, without downloading every dive), a
/// richly-typed `decode` (battery in volts, IMU axes, etc. rather than raw
/// vendor bytes) for the tester UI, and raw-capture export.
public enum SuuntoNauticExplorer {

    public enum ExplorerError: Error {
        case notConnected
        case requestFailed(dc_status_t)
    }

    /// Issue a raw GET request to an arbitrary RPC endpoint path, e.g.
    /// "/System/Mode", "/Logbook/Entries", "/Logbook/UnsynchronisedLogs".
    /// Returns the raw, undecoded response bytes.
    public static func request(device devicePtr: UnsafeMutablePointer<device_data_t>, path: String) throws -> Data {
        guard let dcDevice = devicePtr.pointee.device else {
            throw ExplorerError.notConnected
        }

        guard let buffer = dc_buffer_new(0) else {
            throw ExplorerError.requestFailed(DC_STATUS_NOMEMORY)
        }
        defer { dc_buffer_free(buffer) }

        let status = suunto_nautic_device_request(dcDevice, path, buffer)
        guard status == DC_STATUS_SUCCESS else {
            throw ExplorerError.requestFailed(status)
        }

        return dataFromBuffer(buffer)
    }

    /// Fetch a small whole resource (e.g. `/Logbook/Entries`) via the
    /// short-fetch flow. Unlike `request` above, which returns only the ACK,
    /// this runs the GET → ACK → short 0x0D fetch → data sequence. For dive
    /// *data* (compressed, paginated) use `download` instead.
    public static func fetch(device devicePtr: UnsafeMutablePointer<device_data_t>, path: String) throws -> Data {
        guard let dcDevice = devicePtr.pointee.device else {
            throw ExplorerError.notConnected
        }

        guard let buffer = dc_buffer_new(0) else {
            throw ExplorerError.requestFailed(DC_STATUS_NOMEMORY)
        }
        defer { dc_buffer_free(buffer) }

        let status = suunto_nautic_device_fetch(dcDevice, path, buffer)
        guard status == DC_STATUS_SUCCESS else {
            throw ExplorerError.requestFailed(status)
        }

        return dataFromBuffer(buffer)
    }

    /// Lists dive IDs from `/Logbook/Entries`, sorted newest-first (each ID
    /// is a UNIX timestamp). Cheaper than `dc_device_foreach()`, which
    /// downloads every dive just to enumerate them.
    public static func listDives(device devicePtr: UnsafeMutablePointer<device_data_t>) throws -> [UInt32] {
        guard let dcDevice = devicePtr.pointee.device else {
            throw ExplorerError.notConnected
        }
        guard let buffer = dc_buffer_new(0) else {
            throw ExplorerError.requestFailed(DC_STATUS_NOMEMORY)
        }
        defer { dc_buffer_free(buffer) }

        // The entry parsing lives in the C driver (suunto_nautic_device_list),
        // the single source of truth also used by dc_device_foreach. It writes
        // the dive ids as packed little-endian uint32, newest-first; here we
        // just unpack that list — no protocol logic duplicated in Swift.
        let status = suunto_nautic_device_list(dcDevice, buffer)
        guard status == DC_STATUS_SUCCESS else {
            throw ExplorerError.requestFailed(status)
        }

        let data = dataFromBuffer(buffer)
        let bytes = [UInt8](data)
        var ids: [UInt32] = []
        var i = 0
        while i + 4 <= bytes.count {
            ids.append(UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24))
            i += 4
        }
        return ids
    }

    /// Download and decompress a specific logbook entry, given its
    /// numeric id as it appears in a "/Logbook/byId/<id>/..." path (e.g.
    /// "1787752091"). Returns the decoded SBEM0103 TLV stream, ready for
    /// `decode(sbemData:)` below.
    public static func download(device devicePtr: UnsafeMutablePointer<device_data_t>, logbookID: String) throws -> Data {
        guard let dcDevice = devicePtr.pointee.device else {
            throw ExplorerError.notConnected
        }

        guard let buffer = dc_buffer_new(0) else {
            throw ExplorerError.requestFailed(DC_STATUS_NOMEMORY)
        }
        defer { dc_buffer_free(buffer) }

        let status = suunto_nautic_device_download(dcDevice, logbookID, buffer)
        guard status == DC_STATUS_SUCCESS else {
            throw ExplorerError.requestFailed(status)
        }

        return dataFromBuffer(buffer)
    }


    /// A decoded dive profile. Populated from the standard dc_parser_t
    /// fields/samples: depth, temperature, tank pressure, and (from the
    /// appended /Summary section) gradient factors and gas mix. See
    /// suunto_nautic.h for what's still missing (dive events, datetime).
    public struct DecodedProfile {
        public struct DepthSample { public let time: TimeInterval; public let depth: Double }
        public struct TemperatureSample { public let time: TimeInterval; public let temperature: Double }
        public struct TankSample { public let time: TimeInterval; public let tank: Int; public let pressure: Double }
        public struct Tank { public let index: Int; public let beginPressure: Double; public let endPressure: Double }
        public struct Gas { public let o2Percent: Int; public let hePercent: Int }
        /// A dive event (alarm, warning, gas switch, ...). `type` is the
        /// libdivecomputer `parser_sample_event_t` value; `isBegin` marks a
        /// begin (true) vs end (false) edge.
        /// Non-standard telemetry the C parser decodes and delivers through the
        /// standard DC_SAMPLE_VENDOR channel (SAMPLE_VENDOR_SUUNTO_NAUTIC), since
        /// libdivecomputer has no dedicated sample types for these. This layer
        /// only unpacks the kind-tagged records.
        public struct BatterySample { public let time: TimeInterval; public let voltage: Double; public let charge: Double } // V, 0..1
        public struct GPSAccuracySample { public let time: TimeInterval; public let ehpe: Double; public let evpe: Double } // metres
        /// 9-axis IMU (accel/gyro/mag), raw int16 counts in stream order. The
        /// scale factors below are validated against this reference dive (accel
        /// magnitude ≈ 1g and gyro ≈ 0 during the stillest samples). The axis
        /// order is identity with no sign flips (accel/gyro/mag lanes → X,Y,Z in
        /// order), confirmed by decompiling libmds' IMU path (no swaps, no FNEG).
        /// The magnetometer unit is microtesla but its raw→µT scale isn't in
        /// libmds (it's in the on-device / MATLAB nav code), so mag stays raw.
        public struct IMUSample {
            public let time: TimeInterval
            public let ax: Int, ay: Int, az: Int
            public let gx: Int, gy: Int, gz: Int
            public let mx: Int, my: Int, mz: Int

            /// raw accel * this = g. Sensor is ±4g (binary constant 1/8192) but
            /// the stream is logged at half resolution, so the effective factor
            /// is 1/4096 (gives 0.98g at rest on the reference dive).
            public static let accelScaleG = 1.0 / 4096.0
            /// raw gyro * this = deg/s (±250°/s; reads ~0.26°/s at rest).
            public static let gyroScaleDegPerSec = 1.0 / 131.0
            /// Standard gravity, for g -> m/s².
            public static let gravity = 9.80665

            public var accelG: (x: Double, y: Double, z: Double) {
                (Double(ax) * Self.accelScaleG, Double(ay) * Self.accelScaleG, Double(az) * Self.accelScaleG)
            }
            public var gyroDegPerSec: (x: Double, y: Double, z: Double) {
                (Double(gx) * Self.gyroScaleDegPerSec, Double(gy) * Self.gyroScaleDegPerSec, Double(gz) * Self.gyroScaleDegPerSec)
            }
        }
        public struct DiveRouteSample { public let time: TimeInterval; public let features: [Int] } // 5x uint16, semantics TBD
        /// Decompression status, from the standard DC_SAMPLE_DECO channel.
        public struct DecoSample {
            public enum Kind { case noDeco, decoStop }
            public let time: TimeInterval
            public let kind: Kind
            public let ndl: TimeInterval   // seconds remaining (no-deco phase)
            public let ceiling: Double     // metres (deco phase)
            public let tts: TimeInterval   // seconds to surface
        }
        /// Real-time gradient factors (percent). No standard libdivecomputer
        /// channel, so carried via DC_SAMPLE_VENDOR.
        public struct GradientFactorSample { public let time: TimeInterval; public let gf99: Int; public let gfSurface: Int; public let gfLeading: Int }
        public struct Event {
            public let time: TimeInterval
            public let type: UInt32
            public let isBegin: Bool
            public let value: UInt32

            /// Human-readable label. For alarm/warning/notify/state events the
            /// parser passes the native Suunto (subgroup, type) through `value`
            /// as (subgroup << 8 | type), so we can show the exact Suunto label
            /// ("Safety Stop Ahead", "At Safety Stop", ...) rather than the
            /// lossy libdivecomputer mapping. Gas switch keeps `value` as the
            /// gas number.
            public var label: String {
                if type == SAMPLE_EVENT_GASCHANGE.rawValue {
                    return "Gas switch → \(value)\(isBegin ? "" : " end")"
                }
                if let native = Self.nauticEventLabel(subgroup: Int(value >> 8), type: Int(value & 0xFF)) {
                    return "\(native) \(isBegin ? "start" : "end")"
                }
                return "Event \(type) \(isBegin ? "start" : "end")"
            }

            /// Authoritative Suunto dive-event labels, per subgroup, from the
            /// per-dive /Logbook/byId/<id>/Descriptors SBEM schema. The type
            /// number is only meaningful within its subgroup (there is no flat
            /// table). 0x18 Alarm, 0x19 Warning, 0x1A Notify, 0x1B State.
            static func nauticEventLabel(subgroup: Int, type: Int) -> String? {
                switch subgroup {
                case 0x18: // Alarm
                    return [1: "PO₂ low", 2: "PO₂ high", 3: "Tank pressure", 4: "Gas time",
                            5: "Ascent speed", 7: "CNS 100%", 8: "OTU 300", 10: "Deco stop broken",
                            12: "Deep stop broken", 13: "Safety stop broken", 31: "Depth", 50: "Battery"][type]
                case 0x19: // Warning
                    return [6: "User PO₂ high", 14: "CNS 80%", 15: "OTU 250", 20: "No-deco time",
                            28: "User tank pressure", 29: "User gas time", 30: "Sidemount", 31: "Depth",
                            32: "Dive time", 42: "User NDL", 44: "Recovery time", 50: "Battery"][type]
                case 0x1A: // Notify
                    return [11: "Gas switch", 21: "Setpoint switch", 28: "User tank pressure",
                            29: "User gas time", 30: "Sidemount", 31: "Depth", 32: "Dive time",
                            41: "Stop done", 42: "User NDL", 44: "Recovery time", 60: "Bearing set",
                            61: "Bearing cleared", 62: "Stopwatch started", 63: "Stopwatch reset"][type]
                case 0x1B: // State
                    return [19: "NDL exceeded", 35: "At deco stop", 36: "At deep stop",
                            37: "At safety stop", 38: "Deco stop ahead", 39: "Deep stop ahead",
                            40: "Safety stop ahead"][type]
                default:
                    return nil
                }
            }
        }

        /// Dive start time. Derived by the parser from the first GPS fix's
        /// absolute UTC (dc_parser_get_datetime); for a dive with no surface GPS
        /// fix the parser can't recover it, and `decode` falls back to the
        /// logbook ID, which is that same UNIX timestamp. nil only when neither
        /// is available.
        public var startDate: Date?
        public var divetime: TimeInterval
        public var maxDepth: Double
        public var avgDepth: Double
        public var temperatureMinimum: Double?
        public var temperatureMaximum: Double?
        public var tanks: [Tank]
        public var gradientFactorLow: Int?
        public var gradientFactorHigh: Int?
        public var gases: [Gas]
        public var depthProfile: [DepthSample]
        public var temperatureProfile: [TemperatureSample]
        public var tankProfile: [TankSample]
        public var events: [Event]
        public var batteryProfile: [BatterySample]
        public var gpsAccuracyProfile: [GPSAccuracySample]
        public var imuProfile: [IMUSample]
        public var diveRouteProfile: [DiveRouteSample]
        public var decoProfile: [DecoSample]
        public var gradientFactorProfile: [GradientFactorSample]
    }

    /// Decode a downloaded (and already decompressed) SBEM0103 stream
    /// into a real dive profile. Calls the same dc_parser_t machinery
    /// GenericParser uses, but directly — see the type-level doc comment
    /// for why this bypasses GenericParser.parseDiveData.
    ///
    /// Pass `logbookID` (the numeric id used to download the dive) to fill in
    /// `startDate`: that id is the dive's start time as a UNIX timestamp.
    public static func decode(sbemData: Data, logbookID: UInt32? = nil) throws -> DecodedProfile {
        var parser: OpaquePointer?
        let status = sbemData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> dc_status_t in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress
            return create_parser_for_device(&parser, nil, DC_FAMILY_SUUNTO_NAUTIC, 0, ptr, sbemData.count)
        }
        guard status == DC_STATUS_SUCCESS, let parser else {
            throw ExplorerError.requestFailed(status)
        }
        defer { dc_parser_destroy(parser) }

        var divetime: UInt32 = 0
        var maxDepth: Double = 0
        var avgDepth: Double = 0
        dc_parser_get_field(parser, DC_FIELD_DIVETIME, 0, &divetime)
        dc_parser_get_field(parser, DC_FIELD_MAXDEPTH, 0, &maxDepth)
        dc_parser_get_field(parser, DC_FIELD_AVGDEPTH, 0, &avgDepth)

        // Dive start: prefer the parser's stream-derived datetime (from the GPS
        // UTC anchor); fall back to the logbook ID when the stream has no fix.
        var startDate: Date? = logbookID.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        var dt = dc_datetime_t()
        if dc_parser_get_datetime(parser, &dt) == DC_STATUS_SUCCESS {
            var comps = DateComponents()
            comps.year = Int(dt.year); comps.month = Int(dt.month); comps.day = Int(dt.day)
            comps.hour = Int(dt.hour); comps.minute = Int(dt.minute); comps.second = Int(dt.second)
            comps.timeZone = TimeZone(identifier: "UTC")
            if let d = Calendar(identifier: .gregorian).date(from: comps) { startDate = d }
        }

        var tempMin: Double = 0
        var tempMax: Double = 0
        let tempMinStatus = dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MINIMUM, 0, &tempMin)
        let tempMaxStatus = dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MAXIMUM, 0, &tempMax)

        var tanks: [DecodedProfile.Tank] = []
        for i in 0..<8 {
            var tank = dc_tank_t()
            if dc_parser_get_field(parser, DC_FIELD_TANK, UInt32(i), &tank) == DC_STATUS_SUCCESS {
                tanks.append(.init(index: i, beginPressure: tank.beginpressure, endPressure: tank.endpressure))
            }
        }

        // Gradient factors (from the /Summary section, via the decompression model).
        var gfLow: Int?
        var gfHigh: Int?
        var deco = dc_decomodel_t()
        if dc_parser_get_field(parser, DC_FIELD_DECOMODEL, 0, &deco) == DC_STATUS_SUCCESS,
           deco.type == DC_DECOMODEL_BUHLMANN {
            gfLow = Int(deco.params.gf.low)
            gfHigh = Int(deco.params.gf.high)
        }

        // Gas mixes (fractions -> percent).
        var gases: [DecodedProfile.Gas] = []
        var gasCount: UInt32 = 0
        if dc_parser_get_field(parser, DC_FIELD_GASMIX_COUNT, 0, &gasCount) == DC_STATUS_SUCCESS {
            for i in 0..<gasCount {
                var mix = dc_gasmix_t()
                if dc_parser_get_field(parser, DC_FIELD_GASMIX, i, &mix) == DC_STATUS_SUCCESS {
                    gases.append(.init(o2Percent: Int((mix.oxygen * 100).rounded()),
                                       hePercent: Int((mix.helium * 100).rounded())))
                }
            }
        }

        let collector = SampleCollector()
        let collectorPtr = Unmanaged.passRetained(collector).toOpaque()
        defer { Unmanaged<SampleCollector>.fromOpaque(collectorPtr).release() }

        let callback: dc_sample_callback_t = { type, valuePtr, userData in
            guard let userData, let value = valuePtr?.pointee else { return }
            let collector = Unmanaged<SampleCollector>.fromOpaque(userData).takeUnretainedValue()
            switch type {
            case DC_SAMPLE_TIME:
                collector.currentTime = TimeInterval(value.time) / 1000.0
            case DC_SAMPLE_DEPTH:
                collector.depth.append(.init(time: collector.currentTime, depth: value.depth))
            case DC_SAMPLE_TEMPERATURE:
                collector.temperature.append(.init(time: collector.currentTime, temperature: value.temperature))
            case DC_SAMPLE_PRESSURE:
                collector.tank.append(.init(time: collector.currentTime, tank: Int(value.pressure.tank), pressure: value.pressure.value))
            case DC_SAMPLE_EVENT:
                let isBegin = (value.event.flags & UInt32(SAMPLE_FLAGS_BEGIN.rawValue)) != 0
                collector.events.append(.init(time: collector.currentTime, type: value.event.type, isBegin: isBegin, value: value.event.value))
            case DC_SAMPLE_DECO:
                let isDeco = value.deco.type == DC_DECO_DECOSTOP.rawValue
                collector.deco.append(.init(time: collector.currentTime,
                                            kind: isDeco ? .decoStop : .noDeco,
                                            ndl: TimeInterval(value.deco.time),
                                            ceiling: value.deco.depth,
                                            tts: TimeInterval(value.deco.tts)))
            case DC_SAMPLE_VENDOR:
                // Non-standard telemetry, decoded in the C parser and delivered
                // as a kind-tagged little-endian record (byte 0 = kind).
                guard value.vendor.type == UInt32(SAMPLE_VENDOR_SUUNTO_NAUTIC.rawValue),
                      value.vendor.size >= 1, let raw = value.vendor.data else { break }
                let b = raw.assumingMemoryBound(to: UInt8.self)
                let size = Int(value.vendor.size)
                func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))) }
                func u16(_ o: Int) -> Int { Int(UInt16(b[o]) | (UInt16(b[o + 1]) << 8)) }
                let t = collector.currentTime
                switch b[0] {
                case 1 where size >= 5: // battery
                    collector.battery.append(.init(time: t, voltage: Double(u16(1)) / 1000.0, charge: Double(u16(3)) / 1000.0))
                case 2 where size >= 5: // GPS accuracy (metres)
                    collector.gpsAccuracy.append(.init(time: t, ehpe: Double(u16(1)), evpe: Double(u16(3))))
                case 3 where size >= 19: // IMU: 9x int16
                    collector.imu.append(.init(time: t, ax: i16(1), ay: i16(3), az: i16(5),
                                                gx: i16(7), gy: i16(9), gz: i16(11),
                                                mx: i16(13), my: i16(15), mz: i16(17)))
                case 4 where size >= 11: // DiveRoute: 5x uint16
                    collector.diveRoute.append(.init(time: t, features: [u16(1), u16(3), u16(5), u16(7), u16(9)]))
                case 5 where size >= 7: // real-time gradient factors
                    collector.gf.append(.init(time: t, gf99: i16(1), gfSurface: i16(3), gfLeading: i16(5)))
                default:
                    break
                }
            default:
                break
            }
        }

        dc_parser_samples_foreach(parser, callback, collectorPtr)

        return DecodedProfile(
            startDate: startDate,
            divetime: TimeInterval(divetime),
            maxDepth: maxDepth,
            avgDepth: avgDepth,
            temperatureMinimum: tempMinStatus == DC_STATUS_SUCCESS ? tempMin : nil,
            temperatureMaximum: tempMaxStatus == DC_STATUS_SUCCESS ? tempMax : nil,
            tanks: tanks,
            gradientFactorLow: gfLow,
            gradientFactorHigh: gfHigh,
            gases: gases,
            depthProfile: collector.depth,
            temperatureProfile: collector.temperature,
            tankProfile: collector.tank,
            events: collector.events,
            batteryProfile: collector.battery,
            gpsAccuracyProfile: collector.gpsAccuracy,
            imuProfile: collector.imu,
            diveRouteProfile: collector.diveRoute,
            decoProfile: collector.deco,
            gradientFactorProfile: collector.gf
        )
    }

    private static func dataFromBuffer(_ buffer: OpaquePointer) -> Data {
        let size = dc_buffer_get_size(buffer)
        guard size > 0, let base = dc_buffer_get_data(buffer) else {
            return Data()
        }
        return Data(bytes: base, count: size)
    }
}

private final class SampleCollector {
    var currentTime: TimeInterval = 0
    var depth: [SuuntoNauticExplorer.DecodedProfile.DepthSample] = []
    var temperature: [SuuntoNauticExplorer.DecodedProfile.TemperatureSample] = []
    var tank: [SuuntoNauticExplorer.DecodedProfile.TankSample] = []
    var events: [SuuntoNauticExplorer.DecodedProfile.Event] = []
    var battery: [SuuntoNauticExplorer.DecodedProfile.BatterySample] = []
    var gpsAccuracy: [SuuntoNauticExplorer.DecodedProfile.GPSAccuracySample] = []
    var imu: [SuuntoNauticExplorer.DecodedProfile.IMUSample] = []
    var diveRoute: [SuuntoNauticExplorer.DecodedProfile.DiveRouteSample] = []
    var deco: [SuuntoNauticExplorer.DecodedProfile.DecoSample] = []
    var gf: [SuuntoNauticExplorer.DecodedProfile.GradientFactorSample] = []
}
