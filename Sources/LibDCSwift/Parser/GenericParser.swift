import Foundation
import Clibdivecomputer
import LibDCBridge

/*
 Generic Dive Computer Parser
 
 This parser collects comprehensive dive data from various dive computers:
 
 Basic Dive Info:
 - Dive Time: Total duration of the dive in seconds
 - Max Depth: Maximum depth reached during dive (meters)
 - Avg Depth: Average depth throughout dive (meters)
 - Atmospheric: Surface pressure (bar)
 
 Temperature Data:
 - Surface Temperature: Temperature at start of dive (Celsius)
 - Minimum Temperature: Lowest temperature during dive
 - Maximum Temperature: Highest temperature during dive
 
 Gas & Tank Information:
 - Gas Mixes: List of all gas mixes used
   * Oxygen percentage (O2)
   * Helium percentage (He)
   * Nitrogen percentage (N2)
   * Usage type (oxygen, diluent, sidemount)
 - Tank Data:
   * Volume (liters)
   * Working pressure (bar)
   * Start/End pressures
   * Associated gas mix
 
 Decompression Info:
 - Decompression Model (Bühlmann, VPM, RGBM, etc.)
 - Conservatism settings
 - Gradient Factors (low/high) for Bühlmann
 
 Location:
 - GPS coordinates (if supported)
 - Altitude of dive site
 
 Detailed Profile:
 Time series data including:
 - Depth readings
 - Temperature
 - Tank pressures
 - Events:
   * Gas switches
   * Deco/Safety stops
   * Ascent rate warnings
   * Violations
   * PPO2 warnings
   * User-set bookmarks
 
 Sample Events Legend:
 - DECOSTOP: Required decompression stop
 - ASCENT: Ascent rate warning
 - CEILING: Ceiling violation
 - WORKLOAD: Work load indication
 - TRANSMITTER: Transmitter status/warnings
 - VIOLATION: Generic violation
 - BOOKMARK: User-marked point
 - SURFACE: Surface event
 - SAFETYSTOP: Safety stop (voluntary/mandatory)
 - GASCHANGE: Gas mix switch
 - DEEPSTOP: Deep stop
 - CEILING_SAFETYSTOP: Ceiling during safety stop
 - FLOOR: Floor reached during dive
 - DIVETIME: Dive time notification
 - MAXDEPTH: Max depth reached
 - OLF: Oxygen limit fraction
 - PO2: PPO2 warning
 - AIRTIME: Remaining air time warning
 - RGBM: RGBM warning
 - HEADING: Compass heading
 - TISSUELEVEL: Tissue saturation
*/

/// A generic parser for dive computer data that supports multiple device families.
/// Uses libdivecomputer's parsing capabilities to extract dive information.
public class GenericParser {
    /// Error types that can occur during parsing
    public enum ParserError: Error {
        case invalidParameters /// Invalid parameters provided to the parser
        case parserCreationFailed(dc_status_t) /// Failed to create the parser
        case datetimeRetrievalFailed(dc_status_t) /// Failed to retrieve datetime information
        case fieldRetrievalFailed(dc_status_t) /// Failed to retrieve field data
        case sampleProcessingFailed(dc_status_t) /// Failed at processing dive samples
    }
    
    /// Retrieves a specific field from the dive data parser
    /// - Parameters:
    ///   - parser: The libdivecomputer parser instance
    ///   - type: Type of field to retrieve
    ///   - flags: Optional flags for field retrieval
    /// - Returns: The field value if successful, nil otherwise
    private static func getField<T>(_ parser: OpaquePointer?, type: dc_field_type_t, flags: UInt32 = 0) -> T? {
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        
        let status = dc_parser_get_field(parser, type, flags, value)
        guard status == DC_STATUS_SUCCESS else { return nil }
        
        return value.load(as: T.self)
    }
    
    /// Folds libdivecomputer's sample callbacks into profile points.
    ///
    /// libdivecomputer opens each sample with DC_SAMPLE_TIME and then reports that
    /// sample's values, so a point is only complete when the next time arrives (or
    /// parsing ends). Repeated DC_SAMPLE_TIME calls with the same time continue the
    /// same sample.
    final class SampleAccumulator {
        var data = SampleData()
        private var hasOpenSample = false

        private static let gasMixUnknown = Int(UInt32.max)

        func handle(_ type: dc_sample_type_t, _ value: dc_sample_value_t) {
            switch type {
            case DC_SAMPLE_TIME:
                let time = TimeInterval(value.time) / 1000.0
                if hasOpenSample && time == data.time { return }
                closeSample()
                data.time = time
                hasOpenSample = true
                return
            default:
                // A value before the first DC_SAMPLE_TIME belongs to a sample at t=0.
                hasOpenSample = true
            }

            switch type {
            case DC_SAMPLE_DEPTH:
                data.depth = value.depth
                data.maxDepth = max(data.maxDepth, value.depth)

            case DC_SAMPLE_PRESSURE:
                // Fired once per transmitter within a sample; record each against
                // its own tank (deepsealabs/libdc-swift#41).
                data.recordTankPressure(tank: Int(value.pressure.tank), value: value.pressure.value)

            case DC_SAMPLE_TEMPERATURE:
                data.temperature = value.temperature

            case DC_SAMPLE_EVENT:
                recordEvent(RawDiveEvent(
                    rawType: value.event.type,
                    value: value.event.value,
                    flags: value.event.flags,
                    timeOffset: value.event.time
                ))

            case DC_SAMPLE_RBT:
                data.rbt = value.rbt

            case DC_SAMPLE_HEARTBEAT:
                data.heartbeat = value.heartbeat

            case DC_SAMPLE_BEARING:
                data.bearing = value.bearing

            case DC_SAMPLE_SETPOINT:
                data.setpoint = value.setpoint

            case DC_SAMPLE_PPO2:
                data.ppo2.append((sensor: value.ppo2.sensor, value: value.ppo2.value))

            case DC_SAMPLE_CNS:
                data.cns = value.cns * 100.0  // Convert to percentage

            case DC_SAMPLE_DECO:
                let deco = SampleData.DecoData(
                    type: dc_deco_type_t(rawValue: value.deco.type),
                    depth: value.deco.depth,
                    time: value.deco.time,
                    tts: value.deco.tts
                )
                data.deco = deco
                data.sampleDeco = deco

            case DC_SAMPLE_GASMIX:
                recordGasMix(Int(value.gasmix))

            case DC_SAMPLE_LOCATION:
                if data.location == nil {
                    data.location = DiveData.Location(
                        latitude: value.location.latitude,
                        longitude: value.location.longitude,
                        altitude: value.location.altitude
                    )
                }

            case DC_SAMPLE_VENDOR:
                // The bytes are only valid for the duration of the callback, so copy them.
                let bytes: Data
                if let raw = value.vendor.data, value.vendor.size > 0 {
                    bytes = Data(bytes: raw, count: Int(value.vendor.size))
                } else {
                    bytes = Data()
                }
                data.vendorSamples.append(
                    DiveData.VendorSample(time: data.time, type: value.vendor.type, data: bytes)
                )

            default:
                break
            }
        }

        /// Flushes the sample still open when libdivecomputer stops calling back.
        func finish() {
            closeSample()
        }

        private func recordEvent(_ event: RawDiveEvent) {
            data.rawEvents.append(event)
            guard let legacy = event.legacyEvent else { return }
            // Some computers report both SAMPLE_EVENT_GASCHANGE and DC_SAMPLE_GASMIX for one switch.
            if legacy == .gasChange && data.events.contains(.gasChange) { return }
            data.events.append(legacy)
        }

        private func recordGasMix(_ newGasMix: Int) {
            // Shearwater sends DC_GASMIX_UNKNOWN for tanks without AI transmitters;
            // treating it as a real mix would mislabel subsequent points.
            guard newGasMix != Self.gasMixUnknown else { return }
            if let previous = data.gasmix, previous != newGasMix, !data.events.contains(.gasChange) {
                data.events.append(.gasChange)
            }
            data.gasmix = newGasMix
        }

        private func closeSample() {
            guard hasOpenSample else { return }
            data.profile.append(makeProfilePoint())
            data.maxTime = max(data.maxTime, data.time)

            if let temp = data.temperature {
                data.tempMinimum = min(data.tempMinimum, temp)
                data.tempMaximum = max(data.tempMaximum, temp)
                data.lastTemperature = temp
                if data.tempSurface == 0 {
                    data.tempSurface = temp
                }
            }

            data.events = []
            data.rawEvents = []
            data.sampleDeco = nil
            hasOpenSample = false
        }

        private func makeProfilePoint() -> DiveProfilePoint {
            let deco = data.sampleDeco
            let kind = deco.flatMap { DecoKind(rawValue: $0.type.rawValue) }
            let isStop = kind != nil && kind != .ndl

            return DiveProfilePoint(
                time: data.time,
                depth: data.depth,
                temperature: data.temperature,
                pressure: data.primaryTankPressure,
                tankPressures: data.currentTankPressures,
                po2: data.ppo2.last?.value,
                events: data.events,
                rawEvents: data.rawEvents,
                decoKind: kind,
                ndl: kind == .ndl ? deco?.time : nil,
                decoStop: isStop ? deco?.depth : nil,
                decoTime: isStop ? deco?.time : nil,
                tts: deco?.tts,
                currentGas: data.gasmix,
                cns: data.cns,
                rbt: data.rbt,
                heartbeat: data.heartbeat,
                bearing: data.bearing,
                setpoint: data.setpoint
            )
        }

        func addTank(_ tank: dc_tank_t) {
            data.tanks.append(GenericParser.convertTank(tank))
        }

        func setDecoModel(_ model: dc_decomodel_t) {
            data.decoModel = GenericParser.convertDecoModel(model)
        }

        /// Time-weighted average depth (trapezoidal), or 0 for an empty profile.
        /// Time-weighted mean depth over the samples up to `limit` seconds.
        func calculateAverageDepth(upTo limit: TimeInterval = .infinity) -> Double {
            guard data.profile.count >= 2 else {
                return data.profile.first?.depth ?? 0
            }

            var weightedSum: Double = 0
            var totalTime: TimeInterval = 0
            for i in 0..<(data.profile.count - 1) {
                let current = data.profile[i]
                guard current.time < limit else { break }
                var nextTime = data.profile[i + 1].time
                var nextDepth = data.profile[i + 1].depth
                if nextTime > limit {
                    nextDepth = current.depth + (nextDepth - current.depth) * (limit - current.time) / (nextTime - current.time)
                    nextTime = limit
                }
                let interval = nextTime - current.time
                weightedSum += (current.depth + nextDepth) / 2.0 * interval
                totalTime += interval
            }
            return totalTime > 0 ? weightedSum / totalTime : 0
        }
    }

    /// Parses raw dive data into a structured DiveData object
    /// - Parameters:
    ///   - family: The family of the dive computer
    ///   - model: The specific model number
    ///   - diveNumber: Sequential number of the dive
    ///   - diveData: Raw data from the dive computer
    ///   - dataSize: Size of the raw data
    ///   - context: Optional parser context
    /// - Returns: A structured DiveData object
    /// - Throws: ParserError if parsing fails
    public static func parseDiveData(
        family: DeviceConfiguration.DeviceFamily,
        model: UInt32,
        diveNumber: Int,
        diveData: UnsafePointer<UInt8>,
        dataSize: Int,
        context: OpaquePointer? = nil,
        fingerprint: Data? = nil,
        fallbackDate: Date? = nil
    ) throws -> DiveData {
        var parser: OpaquePointer?
        
        // Create parser based on device family
        let rc = create_parser_for_device(&parser, context, family.asDCFamily, model, diveData, size_t(dataSize))

        guard rc == DC_STATUS_SUCCESS, parser != nil else {
            logError("Parser creation failed with status: \(rc)")
            throw ParserError.parserCreationFailed(rc)
        }
        
        defer {
            dc_parser_destroy(parser)
        }
        
        // Get dive time
        var datetime = dc_datetime_t()
        let datetimeStatus = dc_parser_get_datetime(parser, &datetime)
        let haveParserDatetime = (datetimeStatus == DC_STATUS_SUCCESS)

        // Some families don't carry a datetime in the parsed stream (e.g. a
        // Suunto Nautic dive with no surface GPS fix). The caller can supply a
        // fallback — typically derived from the dive's fingerprint/id — so the
        // dive still parses instead of throwing.
        guard haveParserDatetime || fallbackDate != nil else {
            throw ParserError.datetimeRetrievalFailed(datetimeStatus)
        }
        
        let wrapper = SampleAccumulator()
        let wrapperPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(wrapper).toOpaque())

        let sampleCallback: dc_sample_callback_t = { type, valuePtr, userData in
            guard let userData = userData, let value = valuePtr?.pointee else { return }
            Unmanaged<SampleAccumulator>.fromOpaque(userData).takeUnretainedValue().handle(type, value)
        }

        let samplesStatus = dc_parser_samples_foreach(parser, sampleCallback, wrapperPtr)
        Unmanaged<SampleAccumulator>.fromOpaque(wrapperPtr).release()
        guard samplesStatus == DC_STATUS_SUCCESS else {
            throw ParserError.sampleProcessingFailed(samplesStatus)
        }
        wrapper.finish()

        let divetime = resolveDivetime(field: getField(parser, type: DC_FIELD_DIVETIME), sampleSpan: wrapper.data.maxTime)
        let avgDepth = resolveAverageDepth(
            field: getField(parser, type: DC_FIELD_AVGDEPTH),
            maxDepth: wrapper.data.maxDepth,
            sampled: wrapper.calculateAverageDepth(upTo: divetime))
        // Other families keep the sampled maximum; their field semantics aren't verified.
        let maxDepth = family == .suuntoNautic
            ? resolveMaxDepth(field: getField(parser, type: DC_FIELD_MAXDEPTH), sampled: wrapper.data.maxDepth)
            : wrapper.data.maxDepth

        // Get gas mix information
        if let gasmixCount: UInt32 = getField(parser, type: DC_FIELD_GASMIX_COUNT) {
            for i in 0..<gasmixCount {
                if let gasmix: dc_gasmix_t = getField(parser, type: DC_FIELD_GASMIX, flags: UInt32(i)) {
                    let mix = GasMix(
                        helium: gasmix.helium,
                        oxygen: gasmix.oxygen,
                        nitrogen: gasmix.nitrogen,
                        usage: gasmix.usage
                    )
                    wrapper.data.gasMixes.append(mix)
                }
            }
        }
        
        // Get tank information
        if let tankCount: UInt32 = getField(parser, type: DC_FIELD_TANK_COUNT) {
            for i in 0..<tankCount {
                if let tank: dc_tank_t = getField(parser, type: DC_FIELD_TANK, flags: UInt32(i)) {
                    wrapper.addTank(tank)
                }
            }
        }
        
        // Get deco model
        var decoValue = dc_decomodel_t()
        _ = dc_parser_get_field(parser, DC_FIELD_DECOMODEL, 0, &decoValue)
        if let decoModel: dc_decomodel_t = getField(parser, type: DC_FIELD_DECOMODEL) {
            wrapper.setDecoModel(decoModel)
        }
        
        // Get dive mode
        let diveMode: DiveData.DiveMode
        if let modeValue: UInt32 = getField(parser, type: DC_FIELD_DIVEMODE) {
            diveMode = switch modeValue {
            case DC_DIVEMODE_FREEDIVE.rawValue: .freedive
            case DC_DIVEMODE_GAUGE.rawValue: .gauge
            case DC_DIVEMODE_OC.rawValue: .openCircuit
            case DC_DIVEMODE_CCR.rawValue: .closedCircuit
            case DC_DIVEMODE_SCR.rawValue: .semiClosedCircuit
            default: .openCircuit
            }
        } else {
            diveMode = .openCircuit  // Default to OC if not specified
        }

        // Get environmental data fields
        if let salinity: dc_salinity_t = getField(parser, type: DC_FIELD_SALINITY) {
            // salinity.density (kg/m^3) carries the actual measured value on devices that
            // report it (e.g. brackish or high-salinity water); fall back to the generic
            // constant only when density isn't reported.
            wrapper.data.salinity = salinity.density > 0
                ? salinity.density / 1000.0
                : (salinity.type == DC_WATER_SALT ? 1.025 : 1.000)
        }

        if let atmospheric: Double = getField(parser, type: DC_FIELD_ATMOSPHERIC) {
            wrapper.data.atmospheric = atmospheric
        }

        // Get temperature fields
        if let tempMin: Double = getField(parser, type: DC_FIELD_TEMPERATURE_MINIMUM) {
            wrapper.data.tempMinimum = tempMin
        }

        if let tempMax: Double = getField(parser, type: DC_FIELD_TEMPERATURE_MAXIMUM) {
            wrapper.data.tempMaximum = tempMax
        }

        if let tempSurf: Double = getField(parser, type: DC_FIELD_TEMPERATURE_SURFACE) {
            wrapper.data.tempSurface = tempSurf
        }

        // Create date from the parser's datetime, or the caller's fallback.
        let date: Date
        if haveParserDatetime {
            var dateComponents = DateComponents()
            dateComponents.year = Int(datetime.year)
            dateComponents.month = Int(datetime.month)
            dateComponents.day = Int(datetime.day)
            dateComponents.hour = Int(datetime.hour)
            dateComponents.minute = Int(datetime.minute)
            dateComponents.second = Int(datetime.second)

            // Most families report the dive's local wall-clock, so the
            // components are interpreted in the device's local calendar. The
            // Suunto Nautic is different: its datetime is derived from the GPS
            // fix and returned as true UTC (dc_datetime_gmtime), so build the
            // Date in UTC to preserve the correct absolute instant. The watch's
            // local offset is not in the dive data (it's a device TZ setting the
            // Suunto app reads separately, see issue #29), so display is left to
            // localize into the viewer's timezone.
            var calendar = Calendar(identifier: .gregorian)
            if family == .suuntoNautic {
                calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
            }
            guard let d = calendar.date(from: dateComponents) else {
                throw ParserError.invalidParameters
            }
            date = d
        } else {
            date = fallbackDate!
        }
        
        return DiveData(
            number: diveNumber,
            datetime: date,
            maxDepth: maxDepth,
            avgDepth: avgDepth,
            divetime: divetime,
            temperature: wrapper.data.tempMinimum,
            profile: wrapper.data.profile,
            tankPressure: wrapper.data.pressure.map { $0.value },
            gasMix: wrapper.data.gasmix,
            gasMixCount: wrapper.data.gasMixes.count,
            gasMixes: wrapper.data.gasMixes.isEmpty ? nil : wrapper.data.gasMixes,
            salinity: wrapper.data.salinity,
            atmospheric: wrapper.data.atmospheric,
            surfaceTemperature: wrapper.data.tempSurface,
            minTemperature: wrapper.data.tempMinimum,
            maxTemperature: wrapper.data.tempMaximum,
            tankCount: wrapper.data.tanks.count,
            tanks: wrapper.data.tanks,
            diveMode: diveMode,
            decoModel: wrapper.data.decoModel,
            location: wrapper.data.location,
            rbt: wrapper.data.rbt,
            heartbeat: wrapper.data.heartbeat,
            bearing: wrapper.data.bearing,
            setpoint: wrapper.data.setpoint,
            ppo2Readings: wrapper.data.ppo2,
            cns: wrapper.data.cns,
            decoStop: wrapper.data.deco.map { deco in
                DiveData.DecoStop(
                    depth: deco.depth,
                    time: TimeInterval(deco.time),
                    type: Int(deco.type.rawValue)
                )
            },
            fingerprint: fingerprint,
            vendorSamples: wrapper.data.vendorSamples
        )
    }

    /// Last-sample time overcounts on computers that keep logging at the
    /// surface after the dive (Suunto Nautic/Ocean), so prefer the computer's
    /// own dive time when it fits inside the samples.
    static func resolveDivetime(field: UInt32?, sampleSpan: TimeInterval) -> TimeInterval {
        // Covers dive times stored in whole minutes, which round past the last sample.
        let slack: TimeInterval = 60
        guard let field, field > 0 else { return sampleSpan }
        let divetime = TimeInterval(field)
        if sampleSpan > 0 && divetime > sampleSpan + slack { return sampleSpan }
        return divetime
    }

    /// The computer's own average depth, unless it's implausible against the
    /// sampled max depth; otherwise the sampled mean over the dive time.
    static func resolveAverageDepth(field: Double?, maxDepth: Double, sampled: Double) -> Double {
        guard let field, field > 0, field.isFinite else { return sampled }
        if maxDepth > 0 && field > maxDepth + 0.5 { return sampled }
        return field
    }

    /// The computer's own maximum, which can sit between samples, when it is
    /// close to the sampled maximum; otherwise the sampled maximum.
    static func resolveMaxDepth(field: Double?, sampled: Double) -> Double {
        guard let field, field > 0, field.isFinite, sampled > 0 else { return sampled }
        return field >= sampled - 0.5 && field <= sampled + 3 ? field : sampled
    }

    fileprivate static func convertTank(_ tank: dc_tank_t) -> DiveData.Tank {
        return DiveData.Tank(
            volume: tank.volume,
            workingPressure: tank.workpressure,
            beginPressure: tank.beginpressure,
            endPressure: tank.endpressure,
            gasMix: Int(tank.gasmix),
            usage: convertUsage(tank.usage)
        )
    }
    
    private static func convertUsage(_ usage: dc_usage_t) -> DiveData.Tank.Usage {
        switch usage {
        case DC_USAGE_NONE:
            return .none
        case DC_USAGE_OXYGEN:
            return .oxygen
        case DC_USAGE_DILUENT:
            return .diluent
        case DC_USAGE_SIDEMOUNT:
            return .sidemount
        default:
            return .none
        }
    }
    
    fileprivate static func convertDecoModel(_ model: dc_decomodel_t) -> DiveData.DecoModel {
        let type: DiveData.DecoModel.DecoType
        
        switch model.type {
        case DC_DECOMODEL_BUHLMANN:
            type = .buhlmann
        case DC_DECOMODEL_VPM:
            type = .vpm
        case DC_DECOMODEL_RGBM:
            type = .rgbm
        case DC_DECOMODEL_DCIEM:
            type = .dciem
        default:
            type = .none
        }
        
        // Get conservatism level
        let conservatism = Int(model.conservatism)
        
        // Get gradient factors for Bühlmann
        let gfLow = type == .buhlmann ? UInt(model.params.gf.low) : 0
        let gfHigh = type == .buhlmann ? UInt(model.params.gf.high) : 0
        
        return DiveData.DecoModel(
            type: type,
            conservatism: conservatism,
            gfLow: UInt32(gfLow),
            gfHigh: UInt32(gfHigh)
        )
    }
} 
