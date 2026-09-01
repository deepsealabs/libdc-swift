import Foundation
import Clibdivecomputer
import LibDCBridge

/// EXPERIMENTAL: raw protocol access + decoding for Suunto Nautic/Ocean
/// devices.
///
/// This family isn't driven through the normal
/// `DiveLogRetriever`/`GenericParser` pipeline yet: the parser only
/// recovers the dive datetime when the dive has a surface GPS fix (it's
/// derived from the GPS UTC anchor — see `suunto_nautic.h` in the
/// libdivecomputer submodule), whereas `GenericParser.parseDiveData`
/// requires a datetime unconditionally and would throw on a no-GPS dive.
/// (`dc_device_foreach()` itself *can* enumerate real dives now — see
/// `listDives` below, which uses the same `/Logbook/Entries` endpoint
/// more cheaply, without downloading every dive just to list them.)
/// `decode` below calls the same underlying dc_parser_t machinery
/// directly, and fills the datetime from the logbook ID when the stream
/// has no fix.
///
/// These functions exist so a connected device can still be
/// interactively explored, dives can be downloaded + decoded by a known
/// logbook ID, and raw captures can be exported.
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
        let data = try fetch(device: devicePtr, path: "/Logbook/Entries")
        return parseDiveEntries(data)
    }

    /// Extract dive-start IDs from a raw /Logbook/Entries response.
    ///
    /// Each logbook entry stores its start timestamp (the LogId, a UNIX time)
    /// immediately followed by the dive's end timestamp, both as 4-aligned
    /// little-endian uint32s in the plausible-timestamp window. We want only
    /// the starts: when an in-range value is immediately followed by a larger
    /// in-range value within a day, that pair is one entry's (start, end), so
    /// take the start and skip the end. Anything between entries (flags, counts)
    /// falls outside the window and is skipped. This is why a single dive used
    /// to list as two: the end timestamp looks just like another dive id.
    static func parseDiveEntries(_ data: Data) -> [UInt32] {
        let diveIDRange: ClosedRange<UInt32> = 1_500_000_000...2_100_000_000
        let maxPairGap: UInt32 = 86_400 // 24h: an end is always within a day of its start
        let bytes = [UInt8](data)

        func uint32LE(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        }

        var ids: [UInt32] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let id = uint32LE(offset)
            if diveIDRange.contains(id) {
                ids.append(id)
                // Skip this entry's paired end timestamp, if present.
                if offset + 8 <= bytes.count {
                    let next = uint32LE(offset + 4)
                    if diveIDRange.contains(next) && next > id && next - id <= maxPairGap {
                        offset += 8
                        continue
                    }
                }
            }
            offset += 4
        }

        return ids.sorted(by: >)
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
            events: collector.events
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
}
