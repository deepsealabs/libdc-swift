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

        // The response embeds each LogId as a 4-aligned little-endian uint32
        // in a small SBEM payload among handle/flag/count/CRC fields; filter
        // to a plausible timestamp window to isolate them (matches the C
        // driver). Must stay 4-aligned -- the IDs are packed adjacently, so an
        // unaligned read straddling two can invent a phantom dive.
        let diveIDRange: ClosedRange<UInt32> = 1_500_000_000...2_100_000_000
        let bytes = [UInt8](data)

        func uint32LE(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        }

        // Cap extraction at the SBEM entry count (LE uint32 at offset 16 of
        // the frame content). The payload ends with a per-request rolling
        // token that can itself fall in the dive-ID window; stopping after
        // `expected` values keeps that tail from becoming a phantom entry.
        let countOffset = 16
        let maxIDs = bytes.count / 4
        var expected = maxIDs
        if bytes.count >= countOffset + 4 {
            let n = Int(uint32LE(countOffset))
            if n <= maxIDs { expected = n }
        }

        var ids: [UInt32] = []
        var offset = 0
        while offset + 4 <= bytes.count && ids.count < expected {
            let id = uint32LE(offset)
            if diveIDRange.contains(id) {
                ids.append(id)
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

            /// Human-readable label, e.g. "Ascent rate start" or "Gas switch → 2".
            public var label: String {
                let name: String
                switch type {
                case SAMPLE_EVENT_ASCENT.rawValue: name = "Ascent rate"
                case SAMPLE_EVENT_CEILING.rawValue, SAMPLE_EVENT_CEILING_SAFETYSTOP.rawValue: name = "Ceiling"
                case SAMPLE_EVENT_DECOSTOP.rawValue: name = "Deco stop"
                case SAMPLE_EVENT_DEEPSTOP.rawValue: name = "Deep stop"
                case SAMPLE_EVENT_SAFETYSTOP.rawValue, SAMPLE_EVENT_SAFETYSTOP_MANDATORY.rawValue: name = "Safety stop"
                case SAMPLE_EVENT_PO2.rawValue: name = "PO₂"
                case SAMPLE_EVENT_AIRTIME.rawValue: name = "Air time"
                case SAMPLE_EVENT_GASCHANGE.rawValue: return "Gas switch → \(value)"
                case SAMPLE_EVENT_VIOLATION.rawValue: name = "Violation"
                case SAMPLE_EVENT_BOOKMARK.rawValue: name = "Bookmark"
                default: name = "Event \(type)"
                }
                return "\(name) \(isBegin ? "start" : "end")"
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
