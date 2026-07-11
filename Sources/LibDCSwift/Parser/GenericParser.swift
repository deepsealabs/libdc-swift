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
    
    /// Wrapper class for collecting sample data during parsing
    private class SampleDataWrapper {
        /// The collected sample data
        var data = SampleData()
        
        /// Adds a new profile point from current sample data
        func addProfilePoint() {
            // Extract deco data
            let ndl = data.deco?.type == DC_DECO_NDL ? data.deco?.time : nil
            let decoStop = data.deco?.type == DC_DECO_DECOSTOP ? data.deco?.depth : nil
            let decoTime = data.deco?.type == DC_DECO_DECOSTOP ? data.deco?.time : nil
            let tts = data.deco?.tts

            let point = DiveProfilePoint(
                time: data.time,
                depth: data.depth,
                temperature: data.temperature,
                pressure: data.pressure.last?.value,
                po2: data.ppo2.last?.value,
                ndl: ndl,
                decoStop: decoStop,
                decoTime: decoTime,
                tts: tts,
                currentGas: data.gasmix,
                cns: data.cns,
                rbt: data.rbt,
                heartbeat: data.heartbeat,
                bearing: data.bearing,
                setpoint: data.setpoint
            )
            data.profile.append(point)
            
            // Update maximum time
            data.maxTime = max(data.maxTime, data.time)
            
            // Track temperature ranges
            if let temp = data.temperature {
                data.tempMinimum = min(data.tempMinimum, temp)
                data.tempMaximum = max(data.tempMaximum, temp)
                data.lastTemperature = temp
                // Store surface temperature if not set
                if data.tempSurface == 0 {
                    data.tempSurface = temp
                }
            }
        }
        
        /// Adds tank information to the sample data
        /// - Parameter tank: Tank information from the dive computer
        func addTank(_ tank: dc_tank_t) {
            data.tanks.append(GenericParser.convertTank(tank))
        }
        
        /// Sets the decompression model used for the dive
        /// - Parameter model: Decompression model information
        func setDecoModel(_ model: dc_decomodel_t) {
            data.decoModel = GenericParser.convertDecoModel(model)
        }

        /// Calculates time-weighted average depth from profile data
        /// - Returns: Average depth in meters, or 0 if profile is empty
        func calculateAverageDepth() -> Double {
            guard data.profile.count >= 2 else {
                return data.profile.first?.depth ?? 0
            }

            var weightedSum: Double = 0
            var totalTime: TimeInterval = 0

            // Calculate time-weighted average using trapezoidal rule
            for i in 0..<(data.profile.count - 1) {
                let currentPoint = data.profile[i]
                let nextPoint = data.profile[i + 1]

                let timeInterval = nextPoint.time - currentPoint.time
                let avgDepthSegment = (currentPoint.depth + nextPoint.depth) / 2.0

                weightedSum += avgDepthSegment * timeInterval
                totalTime += timeInterval
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
        context: OpaquePointer? = nil
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
        
        guard datetimeStatus == DC_STATUS_SUCCESS else {
            throw ParserError.datetimeRetrievalFailed(datetimeStatus)
        }
        
        let wrapper = SampleDataWrapper()
        
        // Convert wrapper to UnsafeMutableRawPointer
        let wrapperPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(wrapper).toOpaque())
        
        let sampleCallback: dc_sample_callback_t = { type, valuePtr, userData in
            guard let userData = userData,
                  let value = valuePtr?.pointee else { return }
            
            let wrapper = Unmanaged<SampleDataWrapper>.fromOpaque(userData).takeUnretainedValue()
            
            switch type {
            case DC_SAMPLE_TIME:
                wrapper.data.time = TimeInterval(value.time) / 1000.0
                wrapper.addProfilePoint()
                
            case DC_SAMPLE_DEPTH:
                wrapper.data.depth = value.depth
                wrapper.data.maxDepth = max(wrapper.data.maxDepth, value.depth)
                
            case DC_SAMPLE_PRESSURE:
                wrapper.data.pressure.append((
                    tank: Int(value.pressure.tank),
                    value: value.pressure.value
                ))
                
            case DC_SAMPLE_TEMPERATURE:
                wrapper.data.temperature = value.temperature
                
            case DC_SAMPLE_EVENT:
                let eventType = value.event.type
                var events: [DiveEvent] = []
                
                switch eventType {
                case SAMPLE_EVENT_ASCENT.rawValue:
                    events.append(.ascent)
                case SAMPLE_EVENT_VIOLATION.rawValue:
                    events.append(.violation)
                case SAMPLE_EVENT_DECOSTOP.rawValue:
                    events.append(.decoStop)
                case SAMPLE_EVENT_GASCHANGE.rawValue:
                    events.append(.gasChange)
                case SAMPLE_EVENT_BOOKMARK.rawValue:
                    events.append(.bookmark)
                case SAMPLE_EVENT_SAFETYSTOP.rawValue:
                    events.append(.safetyStop(mandatory: false))
                case SAMPLE_EVENT_SAFETYSTOP_MANDATORY.rawValue:
                    events.append(.safetyStop(mandatory: true))
                case SAMPLE_EVENT_CEILING.rawValue:
                    events.append(.ceiling)
                case SAMPLE_EVENT_PO2.rawValue:
                    events.append(.po2)
                case SAMPLE_EVENT_DEEPSTOP.rawValue:
                    events.append(.deepStop)
                default:
                    break
                }
                
                // Add the events to the current point with all available data
                let ndl = wrapper.data.deco?.type == DC_DECO_NDL ? wrapper.data.deco?.time : nil
                let decoStop = wrapper.data.deco?.type == DC_DECO_DECOSTOP ? wrapper.data.deco?.depth : nil
                let decoTime = wrapper.data.deco?.type == DC_DECO_DECOSTOP ? wrapper.data.deco?.time : nil
                let tts = wrapper.data.deco?.tts

                let point = DiveProfilePoint(
                    time: wrapper.data.time,
                    depth: wrapper.data.depth,
                    temperature: wrapper.data.temperature,
                    pressure: wrapper.data.pressure.last?.value,
                    po2: wrapper.data.ppo2.last?.value,
                    events: events,
                    ndl: ndl,
                    decoStop: decoStop,
                    decoTime: decoTime,
                    tts: tts,
                    currentGas: wrapper.data.gasmix,
                    cns: wrapper.data.cns,
                    rbt: wrapper.data.rbt,
                    heartbeat: wrapper.data.heartbeat,
                    bearing: wrapper.data.bearing,
                    setpoint: wrapper.data.setpoint
                )
                wrapper.data.profile.append(point)
                
            case DC_SAMPLE_RBT:
                wrapper.data.rbt = value.rbt
                
            case DC_SAMPLE_HEARTBEAT:
                wrapper.data.heartbeat = value.heartbeat
                
            case DC_SAMPLE_BEARING:
                wrapper.data.bearing = value.bearing
                
            case DC_SAMPLE_SETPOINT:
                wrapper.data.setpoint = value.setpoint
                
            case DC_SAMPLE_PPO2:
                wrapper.data.ppo2.append((
                    sensor: value.ppo2.sensor,
                    value: value.ppo2.value
                ))
                
            case DC_SAMPLE_CNS:
                wrapper.data.cns = value.cns * 100.0  // Convert to percentage
                
            case DC_SAMPLE_DECO:
                wrapper.data.deco = SampleData.DecoData(
                    type: dc_deco_type_t(rawValue: value.deco.type),
                    depth: value.deco.depth,
                    time: value.deco.time,
                    tts: value.deco.tts
                )
                
            case DC_SAMPLE_GASMIX:
                let gasMixUnknown = Int(UInt32.max)
                let newGasMix = Int(value.gasmix)
                // Synthesize a gasChange event when the active gas mix changes.
                // Skip DC_GASMIX_UNKNOWN (0xFFFFFFFF), which Shearwater sends for tanks
                // without AI transmitters — treating it as a real mix would poison the
                // current-gas tracker and mislabel subsequent profile points.
                if newGasMix != gasMixUnknown,
                   let previousGas = wrapper.data.gasmix,
                   newGasMix != previousGas {
                    // Dedup: some computers emit both SAMPLE_EVENT_GASCHANGE and
                    // DC_SAMPLE_GASMIX at the same timestamp. If the most recent profile
                    // point already carries a .gasChange event at this time, skip.
                    let alreadyHasGasChangeAtThisTime =
                        wrapper.data.profile.last?.time == wrapper.data.time &&
                        wrapper.data.profile.last?.events.contains(.gasChange) == true
                    if !alreadyHasGasChangeAtThisTime {
                        let ndl = wrapper.data.deco?.type == DC_DECO_NDL ? wrapper.data.deco?.time : nil
                        let decoStop = wrapper.data.deco?.type == DC_DECO_DECOSTOP ? wrapper.data.deco?.depth : nil
                        let decoTime = wrapper.data.deco?.type == DC_DECO_DECOSTOP ? wrapper.data.deco?.time : nil
                        let tts = wrapper.data.deco?.tts
                        let point = DiveProfilePoint(
                            time: wrapper.data.time,
                            depth: wrapper.data.depth,
                            temperature: wrapper.data.temperature,
                            pressure: wrapper.data.pressure.last?.value,
                            po2: wrapper.data.ppo2.last?.value,
                            events: [.gasChange],
                            ndl: ndl,
                            decoStop: decoStop,
                            decoTime: decoTime,
                            tts: tts,
                            currentGas: newGasMix,
                            cns: wrapper.data.cns,
                            rbt: wrapper.data.rbt,
                            heartbeat: wrapper.data.heartbeat,
                            bearing: wrapper.data.bearing,
                            setpoint: wrapper.data.setpoint
                        )
                        wrapper.data.profile.append(point)
                    }
                }
                // Only update the previous-gas tracker when the new mix is real —
                // don't poison it with DC_GASMIX_UNKNOWN.
                if newGasMix != gasMixUnknown {
                    wrapper.data.gasmix = newGasMix
                }

            case DC_SAMPLE_LOCATION:
                if wrapper.data.location == nil {
                    wrapper.data.location = DiveData.Location(
                        latitude: value.location.latitude,
                        longitude: value.location.longitude,
                        altitude: value.location.altitude
                    )
                }

            default:
                break
            }
        }
        
        let samplesStatus = dc_parser_samples_foreach(parser, sampleCallback, wrapperPtr)
        
        // Release the wrapper after we're done
        Unmanaged<SampleDataWrapper>.fromOpaque(wrapperPtr).release()
        guard samplesStatus == DC_STATUS_SUCCESS else {
            throw ParserError.sampleProcessingFailed(samplesStatus)
        }
        
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

        // Create date from components
        var dateComponents = DateComponents()
        dateComponents.year = Int(datetime.year)
        dateComponents.month = Int(datetime.month)
        dateComponents.day = Int(datetime.day)
        dateComponents.hour = Int(datetime.hour)
        dateComponents.minute = Int(datetime.minute)
        dateComponents.second = Int(datetime.second)
        
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: dateComponents) else {
            throw ParserError.invalidParameters
        }
        
        return DiveData(
            number: diveNumber,
            datetime: date,
            maxDepth: wrapper.data.maxDepth,
            avgDepth: wrapper.calculateAverageDepth(),
            divetime: wrapper.data.maxTime,
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
            }
        )
    }
    
    private static func convertTank(_ tank: dc_tank_t) -> DiveData.Tank {
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
    
    private static func convertDecoModel(_ model: dc_decomodel_t) -> DiveData.DecoModel {
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
