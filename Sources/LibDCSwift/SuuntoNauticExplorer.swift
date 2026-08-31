import Foundation
import Clibdivecomputer
import LibDCBridge

/// EXPERIMENTAL: raw protocol access + decoding for Suunto Nautic/Ocean
/// devices.
///
/// This family still can't be driven through the normal
/// `DiveLogRetriever`/`GenericParser` pipeline: the parser has no dive
/// datetime (see `suunto_nautic.h` in the libdivecomputer submodule),
/// which `GenericParser.parseDiveData` requires and would throw on.
/// (`dc_device_foreach()` itself *can* enumerate real dives now — see
/// `listDives` below, which uses the same `/Logbook/Entries` endpoint
/// more cheaply, without downloading every dive just to list them.)
/// `decode` below calls the same underlying dc_parser_t machinery
/// directly, skipping the datetime requirement, since real profile data
/// (depth, temperature, tank pressure) decodes successfully even
/// without it.
///
/// These functions exist so a connected device can still be
/// interactively explored, dives can be downloaded + decoded by a known
/// logbook ID, and raw captures can be exported to help push the
/// remaining reverse-engineering (dive enumeration, other SBEM chunks,
/// the true dive timestamp) forward.
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
        var ids: [UInt32] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let id = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
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

    /// A decoded dive profile. Only the fields/chunks the parser
    /// currently understands are populated (depth, temperature, tank
    /// pressure) — see suunto_nautic.h for what's still missing (dive
    /// events, GPS, the true dive date/time).
    public struct DecodedProfile {
        public struct DepthSample { public let time: TimeInterval; public let depth: Double }
        public struct TemperatureSample { public let time: TimeInterval; public let temperature: Double }
        public struct TankSample { public let time: TimeInterval; public let tank: Int; public let pressure: Double }
        public struct Tank { public let index: Int; public let beginPressure: Double; public let endPressure: Double }

        public var divetime: TimeInterval
        public var maxDepth: Double
        public var avgDepth: Double
        public var temperatureMinimum: Double?
        public var temperatureMaximum: Double?
        public var tanks: [Tank]
        public var depthProfile: [DepthSample]
        public var temperatureProfile: [TemperatureSample]
        public var tankProfile: [TankSample]
    }

    /// Decode a downloaded (and already decompressed) SBEM0103 stream
    /// into a real dive profile. Calls the same dc_parser_t machinery
    /// GenericParser uses, but directly — see the type-level doc comment
    /// for why this bypasses GenericParser.parseDiveData.
    public static func decode(sbemData: Data) throws -> DecodedProfile {
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
            default:
                break
            }
        }

        dc_parser_samples_foreach(parser, callback, collectorPtr)

        return DecodedProfile(
            divetime: TimeInterval(divetime),
            maxDepth: maxDepth,
            avgDepth: avgDepth,
            temperatureMinimum: tempMinStatus == DC_STATUS_SUCCESS ? tempMin : nil,
            temperatureMaximum: tempMaxStatus == DC_STATUS_SUCCESS ? tempMax : nil,
            tanks: tanks,
            depthProfile: collector.depth,
            temperatureProfile: collector.temperature,
            tankProfile: collector.tank
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
}
