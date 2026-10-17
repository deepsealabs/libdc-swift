import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
#if canImport(UIKit)
import UIKit
#endif

/// The flag the per-dive callback reads as its cancel switch.
protocol RetrievalFlagHolder: AnyObject {
    var isRetrievingLogs: Bool { get set }
}

extension CoreBluetoothManager: RetrievalFlagHolder {}

public class DiveLogRetriever {
    public class CallbackContext {
        var logCount: Int = 1
        let viewModel: DiveDataViewModel
        var lastFingerprint: Data?
        let deviceName: String
        let deviceUUID: String
        var deviceSerial: String?
        var deviceTypeFromLibDC: String?  // Exact device type string from libdivecomputer
        var hasNewDives: Bool = false
        /// Test seam standing in for `CoreBluetoothManager.isRetrievingLogs`.
        let isCancelled: () -> Bool
        /// Test seam: an isolated store instead of `DeviceStorage.shared`.
        let deviceStorage: DeviceStorage
        var devicePtr: UnsafeMutablePointer<device_data_t>?
        var hasDeviceInfo: Bool = false
        var storedFingerprint: Data?
        var isCompleted: Bool = false
        var fingerprintMatched: Bool = false  // Track if we stopped due to fingerprint match
        /// Dives that parsed to an empty/degenerate record (no profile
        /// samples, ~0 duration) and were skipped. On the Suunto NG family
        /// this is the signature of a contended BLE stream (the official
        /// Suunto app still holding the link): enumeration succeeds but the
        /// data payload comes back empty. Used at completion to withhold the
        /// fingerprint (so a clean retry re-downloads) and to signal the
        /// empty-read outcome instead of a false "no new dives".
        var emptyReadCount: Int = 0
        /// When false, a "download only new" toggle-off — skip loading/comparing
        /// against the stored fingerprint entirely so a full history re-download
        /// isn't cut short by the fingerprint match early-return below.
        let useFingerprint: Bool

        var detectedFamily: dc_family_t = DC_FAMILY_NULL
        var detectedModel: UInt32 = 0

        let policy: RetrievalPolicy
        /// Dives the parser rejected; any of them keeps a session download from committing its fingerprint.
        var parseFailureCount: Int = 0
        /// The per-dive check saw a cancel and stopped the walk.
        var cancelled: Bool = false
        /// The C lookup gave the device a stored fingerprint, so a walk that delivers nothing means no new dives.
        var deviceHadStoredFingerprint: Bool = false
        private var descriptorCheck: (family: dc_family_t, model: UInt32, known: Bool)?

        init(viewModel: DiveDataViewModel, deviceName: String, deviceUUID: String, storedFingerprint: Data?, isCancelled: @escaping () -> Bool, deviceStorage: DeviceStorage = .shared, useFingerprint: Bool = true, policy: RetrievalPolicy = .legacy) {
            self.viewModel = viewModel
            self.deviceName = deviceName
            self.deviceUUID = deviceUUID
            self.storedFingerprint = storedFingerprint
            self.isCancelled = isCancelled
            self.deviceStorage = deviceStorage
            self.useFingerprint = useFingerprint
            self.policy = policy
        }

        /// A session parses with the hardware model when a descriptor knows it, else with the descriptor it opened.
        func sessionParseTarget() -> (family: dc_family_t, model: UInt32)? {
            let opened = devicePtr?.pointee.descriptor.map { (family: dc_descriptor_get_type($0), model: dc_descriptor_get_model($0)) }
            guard detectedModel != 0, detectedFamily != DC_FAMILY_NULL else { return opened ?? configuredParseTarget() }
            if descriptorCheck?.family != detectedFamily || descriptorCheck?.model != detectedModel {
                descriptorCheck = (detectedFamily, detectedModel,
                                   DeviceConfiguration.hasDescriptor(family: detectedFamily, model: detectedModel))
            }
            if descriptorCheck?.known == true { return (detectedFamily, detectedModel) }
            return opened ?? (detectedFamily, detectedModel)
        }

        /// What the host stored or the name implies, for a device opened without a descriptor.
        private func configuredParseTarget() -> (family: dc_family_t, model: UInt32)? {
            if let stored = deviceStorage.getStoredDevice(uuid: deviceUUID) { return (stored.family.asDCFamily, stored.model) }
            return DeviceConfiguration.fromName(deviceName).map { ($0.family.asDCFamily, $0.model) }
        }

        var deviceClock: GenericParser.DeviceClock? {
            guard let devicePtr, devicePtr.pointee.have_clock != 0 else { return nil }
            return GenericParser.DeviceClock(devtime: devicePtr.pointee.clock.devtime, systime: devicePtr.pointee.clock.systime)
        }
    }

    /// Whose contract a download follows.
    enum RetrievalPolicy {
        /// The `CBPeripheral` download's: it saves the fingerprint itself, and a between-dive cancel reads as a short download.
        case legacy
        /// `retrieveDiveLogs(session:)`'s: the host acknowledges the fingerprint, and cancels and unparsed dives are reported.
        case session
    }

    /// A parsed record with no profile samples AND no meaningful duration is
    /// an empty read, not a real dive. Both conditions are required so a
    /// genuine ultra-short dive -- which still carries samples -- is never
    /// dropped. See `CallbackContext.emptyReadCount`.
    static func isEmptyRead(_ dive: DiveData) -> Bool {
        dive.profile.isEmpty && dive.divetime <= 1
    }

    /// What a finished `dc_device_foreach` means for the caller and for the
    /// stored fingerprint.
    struct DownloadOutcome: Equatable {
        var succeeded: Bool
        var saveFingerprint: Bool
        /// Some dives arrived, then the download failed: the rest are still on
        /// the device and a later sync must fetch them.
        var interrupted: Bool
        var emptyReadOnly: Bool
    }

    /// Fingerprint rule: the stored fingerprint only advances when the whole
    /// enumeration succeeded. Drivers walk newest-first, so on any error the
    /// dives that did arrive are all newer than the failed one; storing any of
    /// their fingerprints would make the next sync stop before the gap. On
    /// error the old fingerprint is kept and the next sync re-walks from it
    /// (re-delivering the dives this session already got; hosts dedupe them).
    static func outcome(status: dc_status_t, family: dc_family_t, fingerprintMatched: Bool,
                        hasNewDives: Bool, hadStoredFingerprint: Bool, emptyReadCount: Int) -> DownloadOutcome {
        var succeeded: Bool
        var saveFingerprint = false

        switch status {
        case DC_STATUS_SUCCESS:
            succeeded = true
            saveFingerprint = hasNewDives
        case DC_STATUS_PROTOCOL where fingerprintMatched:
            succeeded = true
        case DC_STATUS_PROTOCOL where !hasNewDives && hadStoredFingerprint && family != DC_FAMILY_SUUNTO_NAUTIC:
            // Legacy leniency for drivers that end a no-new-dives walk with
            // PROTOCOL. The Nautic driver only returns PROTOCOL for a real
            // failure (a refused stream), so it is never read as "no new dives".
            succeeded = true
        default:
            succeeded = false
        }

        // An empty read never advances the fingerprint, so a clean retry
        // re-downloads; all-empty is a soft failure (e.g. "close the Suunto app").
        let emptyReadOnly = emptyReadCount > 0 && !hasNewDives
        if emptyReadCount > 0 {
            saveFingerprint = false
            if emptyReadOnly { succeeded = false }
        }

        return DownloadOutcome(succeeded: succeeded, saveFingerprint: saveFingerprint,
                               interrupted: !succeeded && hasNewDives, emptyReadOnly: emptyReadOnly)
    }

    /// Stable, human-stable name for a libdivecomputer status code, used for
    /// logging and for `DiveDataViewModel.lastDownloadStatus` (analytics).
    static func statusName(_ status: dc_status_t) -> String {
        switch status {
        case DC_STATUS_SUCCESS:     return "SUCCESS"
        case DC_STATUS_DONE:        return "DONE"
        case DC_STATUS_UNSUPPORTED: return "UNSUPPORTED"
        case DC_STATUS_INVALIDARGS: return "INVALIDARGS"
        case DC_STATUS_NOMEMORY:    return "NOMEMORY"
        case DC_STATUS_NODEVICE:    return "NODEVICE"
        case DC_STATUS_NOACCESS:    return "NOACCESS"
        case DC_STATUS_IO:          return "IO"
        case DC_STATUS_TIMEOUT:     return "TIMEOUT"
        case DC_STATUS_PROTOCOL:    return "PROTOCOL"
        case DC_STATUS_DATAFORMAT:  return "DATAFORMAT"
        case DC_STATUS_CANCELLED:   return "CANCELLED"
        default:                    return "UNKNOWN(\(status))"
        }
    }

    private static let diveCallbackClosure: @convention(c) (
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32 = { data, size, fingerprint, fsize, userdata in
        guard let data = data,
              let userdata = userdata else {
            return 0
        }
        
        let context = Unmanaged<CallbackContext>.fromOpaque(userdata).takeUnretainedValue()
        // Suunto Solution passes no fingerprint; a session still downloads those dives, it just can't commit one.
        guard fingerprint != nil || context.policy == .session else {
            return 0
        }
        
        if context.isCancelled() {
            logInfo("🛑 Download cancelled")
            context.cancelled = true
            return 0
        }
        
        // 1. Capture Device Info (Once)
        if !context.hasDeviceInfo,
           let devicePtr = context.devicePtr,
           devicePtr.pointee.have_devinfo != 0 {
            context.deviceSerial = String(format: "%08x", devicePtr.pointee.devinfo.serial)
            context.detectedModel = devicePtr.pointee.devinfo.model
            
            // Capture the exact device type string from libdivecomputer
            if let modelCStr = devicePtr.pointee.model {
                context.deviceTypeFromLibDC = String(cString: modelCStr)
            }
            
            if let desc = devicePtr.pointee.descriptor {
                context.detectedFamily = dc_descriptor_get_type(desc)
            }

            // Update stored device with serial for fingerprint cleanup when forgetting
            if let serial = context.deviceSerial {
                context.deviceStorage.updateDeviceSerial(uuid: context.deviceUUID, serial: serial)
            }

            // Firmware version reported alongside serial; a provenance snapshot
            // for the reading. 0 means the device reported none.
            let firmwareValue = devicePtr.pointee.devinfo.firmware
            if firmwareValue != 0 {
                context.deviceStorage.updateDeviceFirmware(uuid: context.deviceUUID, firmware: String(firmwareValue))
            }

            // Now that we have device info, load the stored fingerprint if we don't have it yet
            if context.useFingerprint,
               context.storedFingerprint == nil,
               let deviceType = context.deviceTypeFromLibDC,
               let serial = context.deviceSerial {
                context.storedFingerprint = context.viewModel.getFingerprint(forDeviceType: deviceType, serial: serial)
            }

            // Update storage if hardware tells us something different (e.g. 13 vs 9)
            if context.policy == .session {
                DeviceConfiguration.updateDeviceConfigurationFromHardware(
                    deviceAddress: context.deviceUUID,
                    deviceDataPtr: devicePtr,
                    deviceName: context.deviceName,
                    storage: context.deviceStorage,
                    requireKnownModel: true
                )
            } else {
                DeviceConfiguration.updateDeviceConfigurationFromHardware(
                    deviceAddress: context.deviceUUID,
                    deviceDataPtr: devicePtr,
                    deviceName: context.deviceName
                )
            }
            
            context.hasDeviceInfo = true
        }
        
        let fingerprintData = fingerprint.map { Data(bytes: $0, count: Int(fsize)) } ?? Data()

        // Capture the FIRST dive's fingerprint (most recent dive on the device)
        // This is what we'll compare against on the next download
        if context.logCount == 1 {
            context.lastFingerprint = fingerprintData
        }
        
        // Check if this dive matches our stored fingerprint (already downloaded)
        if let storedFingerprint = context.storedFingerprint,
           !(context.policy == .session && fingerprintData.isEmpty) {
            if storedFingerprint == fingerprintData {
                logInfo("✨ Found matching fingerprint - all new dives downloaded")
                context.fingerprintMatched = true
                return 0  // Stop enumeration - we've reached already-downloaded dives
            }
        }
        
        // 4. Parse & Store Dive
        let diveData: DiveData
        do {
            if context.policy == .session {
                guard let target = context.sessionParseTarget() else {
                    logError("❌ Unknown device configuration for dive #\(context.logCount)")
                    context.parseFailureCount += 1
                    return 1
                }
                diveData = try GenericParser.parseDiveData(
                    dcFamily: target.family,
                    model: target.model,
                    diveNumber: context.logCount,
                    diveData: data,
                    dataSize: Int(size),
                    fingerprint: fingerprintData.isEmpty ? nil : fingerprintData,
                    fallbackDate: nauticFallbackDate(family: target.family, fingerprint: fingerprintData),
                    clock: context.deviceClock
                )
            } else {
                guard let parsed = try parseLegacy(context, data: data, size: size, fingerprint: fingerprintData) else {
                    return 0
                }
                diveData = parsed
            }
        } catch {
            logError("❌ Failed to parse dive #\(context.logCount): \(error)")
            context.parseFailureCount += 1
            return 1
        }

        // A record with no profile samples AND no duration isn't a real
        // dive -- it's an empty read. Skip it: don't surface a phantom
        // dive, don't count it as new, and (via emptyReadCount at
        // completion) don't advance the fingerprint. logCount still
        // advances so dive numbers stay unique. Both conditions are
        // required so a genuine ultra-short dive (which still carries
        // samples) is never dropped.
        if isEmptyRead(diveData) {
            logWarning("⚠️ Skipping empty/degenerate dive #\(context.logCount) (no samples, 0 duration)")
            context.emptyReadCount += 1
            context.logCount += 1
            return 1
        }

        DispatchQueue.main.async {
            context.viewModel.appendDives([diveData])
            context.viewModel.updateProgress(count: context.logCount)
        }

        context.hasNewDives = true
        context.logCount += 1
        return 1
    }

    /// Model selection for the `CBPeripheral` download; nil stops the walk (no configuration or family).
    private static func parseLegacy(_ context: CallbackContext, data: UnsafePointer<UInt8>, size: UInt32, fingerprint fingerprintData: Data) throws -> DiveData? {
        var familyToUse: dc_family_t
        var modelToUse: UInt32
        
        // PRIORITY ORDER FOR MODEL SELECTION:
        // 1. Hardware Detection (Most reliable if available)
        // 2. Stored/Forced Configuration (What the user selected)
        // 3. Name-based Detection (Fallback)
        
        if context.detectedModel != 0 {
            familyToUse = context.detectedFamily
            modelToUse = context.detectedModel
        } else if let stored = context.deviceStorage.getStoredDevice(uuid: context.deviceUUID) {
            familyToUse = stored.family.asDCFamily
            modelToUse = stored.model
        } else if let deviceInfo = DeviceConfiguration.fromName(context.deviceName) {
            familyToUse = deviceInfo.family.asDCFamily
            modelToUse = deviceInfo.model
        } else {
            logError("❌ Unknown device configuration")
            return nil
        }

        guard let deviceFamily = DeviceConfiguration.DeviceFamily(dcFamily: familyToUse) else {
            logError("❌ Failed to map C family ID \(familyToUse) to Swift DeviceFamily enum")
            return nil
        }

        return try GenericParser.parseDiveData(
            family: deviceFamily,
            model: modelToUse,
            diveNumber: context.logCount,
            diveData: data,
            dataSize: Int(size),
            fingerprint: fingerprintData,
            fallbackDate: nauticFallbackDate(family: familyToUse, fingerprint: fingerprintData)
        )
    }

    /// Suunto Nautic dives without a surface GPS fix carry no datetime in
    /// the parsed stream, but the fingerprint IS the dive's start time (a
    /// little-endian UNIX timestamp). Supply it as a fallback so the dive
    /// parses instead of throwing on the missing datetime.
    private static func nauticFallbackDate(family: dc_family_t, fingerprint fingerprintData: Data) -> Date? {
        guard family == DC_FAMILY_SUUNTO_NAUTIC, fingerprintData.count == 4 else { return nil }
        let b = [UInt8](fingerprintData)
        let id = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        return Date(timeIntervalSince1970: TimeInterval(id))
    }
    
    private static let fingerprintLookup: @convention(c) (
        UnsafeMutableRawPointer?, 
        UnsafePointer<CChar>?, 
        UnsafePointer<CChar>?, 
        UnsafeMutablePointer<Int>?
    ) -> UnsafeMutablePointer<UInt8>? = { context, deviceType, serial, size in
        guard let context = context, let size = size else {
            logWarning("⚠️ Fingerprint lookup called with nil context or size")
            return nil
        }
        
        let viewModel = Unmanaged<DiveDataViewModel>.fromOpaque(context).takeUnretainedValue()
        
        if let serialStr = serial.map({ String(cString: $0) }),
           let typeStr = deviceType.map({ String(cString: $0) }) {
             
             if let fingerprint = viewModel.getFingerprint(forDeviceType: typeStr, serial: serialStr) {
                size.pointee = fingerprint.count
                // Allocate with malloc, not Swift's allocator: close_device_data() on the C
                // side calls free() on this pointer, and mixing Swift's UnsafeMutablePointer
                // allocator with C free() is not a guaranteed-safe pairing.
                guard let raw = malloc(fingerprint.count) else { return nil }
                let buffer = raw.assumingMemoryBound(to: UInt8.self)
                fingerprint.copyBytes(to: buffer, count: fingerprint.count)
                return buffer
            } else {
                // No stored fingerprint -- return nil so the C bridge skips
                // dc_device_set_fingerprint entirely (configuredc.c checks
                // `fingerprint && fsize > 0` before calling it). Previously
                // this returned a 4-byte 0xFFFFFFFF sentinel, which broke
                // fingerprinting on any device whose fingerprint size isn't
                // 4 bytes (e.g. Oceanic/Aqualung Atom2 requires 8): passing
                // a wrongly-sized buffer makes dc_device_set_fingerprint
                // fail with DC_STATUS_INVALIDARGS, so fingerprinting never
                // took effect and every sync re-downloaded all dives.
                size.pointee = 0
                return nil
            }
        } else {
            logWarning("⚠️ Fingerprint lookup called with nil device type or serial")
        }
        return nil
    }
    
    private static var currentContext: CallbackContext?

    /// Test seam: the retrieval path with no live `CBPeripheral`/`CoreBluetoothManager`.
    static func retrieveDiveLogs(
            from devicePtr: UnsafeMutablePointer<device_data_t>,
            deviceName: String,
            deviceUUID: String,
            viewModel: DiveDataViewModel,
            isCancelled: @escaping () -> Bool,
            markFinished: @escaping () -> Void,
            deviceStorage: DeviceStorage = .shared,
            syncClock: Bool = false,
            useFingerprint: Bool = true,
            onProgress: ((Int, Int) -> Void)? = nil,
            completion: @escaping (Bool) -> Void
        ) {
            runRetrieval(
                from: devicePtr,
                deviceName: deviceName,
                deviceUUID: deviceUUID,
                viewModel: viewModel,
                isCancelled: isCancelled,
                deviceStorage: deviceStorage,
                syncClock: syncClock,
                useFingerprint: useFingerprint,
                session: nil,
                onProgress: onProgress,
                noDevice: {
                    viewModel.setDetailedError("No device connection found", status: DC_STATUS_IO)
                    markFinished()
                    completion(false)
                },
                finish: { context, enumStatus, family in
                    finishLegacy(context, status: enumStatus, family: family, viewModel: viewModel,
                                 markFinished: markFinished, completion: completion)
                }
            )
        }

    /// Saves no fingerprint itself: the result's `fingerprintCommit` (complete, fully parsed walks only) waits for `acknowledge()`. Completes on main.
    public static func retrieveDiveLogs(
            session: DiveComputerSession,
            viewModel: DiveDataViewModel,
            syncClock: Bool = false,
            useFingerprint: Bool = true,
            onProgress: ((Int, Int) -> Void)? = nil,
            completion: @escaping (DiveDownloadResult) -> Void
        ) {
            func endEarly(_ outcome: DiveDownloadResult.Outcome, status: dc_status_t) {
                DispatchQueue.main.async {
                    if outcome == .cancelled {
                        viewModel.lastDownloadStatus = "cancelled"
                        viewModel.updateProgress(.cancelled)
                    }
                    completion(DiveDownloadResult(outcome: outcome, status: status, divesDownloaded: 0,
                                                  parseFailureCount: 0, fingerprintCommit: nil))
                }
            }
            guard session.beginDownload() else {
                logWarning("⚠️ Session for \(session.displayName) is closed or already downloading")
                return endEarly(.failed(DC_STATUS_INVALIDARGS), status: DC_STATUS_INVALIDARGS)
            }
            guard !session.isCancelled else {
                session.endDownload()
                return endEarly(.cancelled, status: DC_STATUS_CANCELLED)
            }
            runRetrieval(
                from: session.devicePtr,
                deviceName: session.displayName,
                deviceUUID: session.storageKey,
                viewModel: viewModel,
                isCancelled: { session.isCancelled },
                deviceStorage: session.deviceStorage,
                syncClock: syncClock,
                useFingerprint: useFingerprint,
                session: session,
                onProgress: onProgress,
                noDevice: {
                    viewModel.setDetailedError("No device connection found", status: DC_STATUS_IO)
                    session.endDownload()
                    completion(DiveDownloadResult(outcome: .failed(DC_STATUS_IO), status: DC_STATUS_IO, divesDownloaded: 0,
                                                  parseFailureCount: 0, fingerprintCommit: nil))
                },
                finish: { context, enumStatus, family in
                    let result = finishSession(context, status: enumStatus, family: family, viewModel: viewModel)
                    session.endDownload()
                    completion(result)
                }
            )
        }

    /// The download both overloads share; `noDevice` and `finish` run on the main thread.
    private static func runRetrieval(
            from devicePtr: UnsafeMutablePointer<device_data_t>,
            deviceName: String,
            deviceUUID: String,
            viewModel: DiveDataViewModel,
            isCancelled: @escaping () -> Bool,
            deviceStorage: DeviceStorage,
            syncClock: Bool,
            useFingerprint: Bool,
            session: DiveComputerSession?,
            onProgress: ((Int, Int) -> Void)?,
            noDevice: @escaping () -> Void,
            finish: @escaping (CallbackContext, dc_status_t, dc_family_t) -> Void
        ) {
            let retrievalQueue = DispatchQueue(label: "com.libdcswift.retrieval", qos: .userInitiated)
            let policy: RetrievalPolicy = session == nil ? .legacy : .session

            retrievalQueue.async {
                DispatchQueue.main.async { viewModel.resetProgress() }

                guard let dcDevice = devicePtr.pointee.device else {
                    DispatchQueue.main.async(execute: noDevice)
                    return
                }

                if dc_device_get_type(dcDevice) == DC_FAMILY_SUUNTO_NAUTIC {
                    let acknowledged = suunto_nautic_device_handshake_acknowledged(dcDevice) != 0
                    DispatchQueue.main.async { viewModel.lastHandshakeAcknowledged = acknowledged }
                }

                // Get device type from stored configuration (user-selected) for consistent fingerprint lookups
                let storedDevice = deviceStorage.getStoredDevice(uuid: deviceUUID)
                let deviceTypeForFingerprint: String
                if let stored = storedDevice,
                   let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
                    deviceTypeForFingerprint = modelInfo.name
                } else {
                    deviceTypeForFingerprint = DeviceConfiguration.getDeviceDisplayName(from: deviceName)
                }

                var storedFingerprint: Data? = nil
                // Try to get fingerprint if we already have device info (from a previous connection)
                if devicePtr.pointee.have_devinfo != 0 {
                    let serial = String(format: "%08x", devicePtr.pointee.devinfo.serial)
                    deviceStorage.updateDeviceSerial(uuid: deviceUUID, serial: serial)
                    if useFingerprint {
                        storedFingerprint = viewModel.getFingerprint(forDeviceType: deviceTypeForFingerprint, serial: serial)
                    }
                }

                let context = CallbackContext(
                    viewModel: viewModel,
                    deviceName: deviceName,
                    deviceUUID: deviceUUID,
                    storedFingerprint: storedFingerprint,
                    isCancelled: isCancelled,
                    deviceStorage: deviceStorage,
                    useFingerprint: useFingerprint,
                    policy: policy
                )
                context.devicePtr = devicePtr
                
                let contextPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque())
                
                // Timer requires an active RunLoop on the current thread to fire, and
                // retrievalQueue is a plain DispatchQueue with no RunLoop pumping while
                // blocked in dc_device_foreach below, so Timer.scheduledTimer would never
                // fire here. DispatchSourceTimer works on any queue.
                let progressTimer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                progressTimer.schedule(deadline: .now(), repeating: 0.25)
                progressTimer.setEventHandler {
                    if devicePtr.pointee.have_progress != 0 {
                        onProgress?(Int(devicePtr.pointee.progress.current), Int(devicePtr.pointee.progress.maximum))
                    }
                }
                progressTimer.resume()
                
                if useFingerprint {
                    if let session {
                        session.retainLookupContext(viewModel)
                    } else {
                        devicePtr.pointee.fingerprint_context = Unmanaged.passUnretained(viewModel).toOpaque()
                    }
                    devicePtr.pointee.lookup_fingerprint = fingerprintLookup
                } else {
                    session?.releaseLookupContext()
                    // An earlier download on this connection may have set one on the device.
                    devicePtr.pointee.fingerprint_context = nil
                    devicePtr.pointee.lookup_fingerprint = nil
                    dc_device_set_fingerprint(dcDevice, nil, 0)
                }
                
                let enumStatus = dc_device_foreach(dcDevice, diveCallbackClosure, contextPtr)
                if policy == .session, useFingerprint, devicePtr.pointee.fingerprint != nil, devicePtr.pointee.fsize > 0 {
                    context.deviceHadStoredFingerprint = true
                }

                // Log errors for debugging
                if enumStatus != DC_STATUS_SUCCESS && enumStatus != DC_STATUS_PROTOCOL {
                    logError("❌ Download failed: DC_STATUS_\(statusName(enumStatus))")
                }

                progressTimer.cancel()

                // Sync the device clock to system time while the BLE session is still open.
                // Runs after a normal successful download, and also on the "no new dives"
                // fingerprint-match path so routine check-ins still update the clock.
                // DC_STATUS_UNSUPPORTED is normal for devices without timesync support.
                let clockSyncAllowed = (enumStatus == DC_STATUS_SUCCESS
                    || (enumStatus == DC_STATUS_PROTOCOL && context.fingerprintMatched))
                    && !(policy == .session && context.cancelled)
                if syncClock && clockSyncAllowed {
                    let now = Date()
                    let comps = Calendar(identifier: .gregorian).dateComponents(
                        in: TimeZone.current, from: now
                    )
                    if let year = comps.year, let month = comps.month, let day = comps.day,
                       let hour = comps.hour, let minute = comps.minute, let second = comps.second {
                        var dt = dc_datetime_t()
                        dt.year     = Int32(year)
                        dt.month    = Int32(month)
                        dt.day      = Int32(day)
                        dt.hour     = Int32(hour)
                        dt.minute   = Int32(minute)
                        dt.second   = Int32(second)
                        dt.timezone = Int32(TimeZone.current.secondsFromGMT(for: now) / 60)
                        let clockStatus = dc_device_timesync(dcDevice, &dt)
                        switch clockStatus {
                        case DC_STATUS_SUCCESS:
                            logInfo("✅ Device clock synced to system time")
                        case DC_STATUS_UNSUPPORTED:
                            logInfo("ℹ️ This device does not support clock synchronization")
                        default:
                            logWarning("⚠️ Clock sync failed with status: \(clockStatus)")
                        }
                    } else {
                        logWarning("⚠️ Clock sync skipped: could not extract date components")
                    }
                }

                let family = dc_device_get_type(dcDevice)
                DispatchQueue.main.async {
                    finish(context, enumStatus, family)
                    context.isCompleted = true
                    Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
                }

                // A session's view model must not outlive its close through this static.
                if policy == .legacy {
                    currentContext = context
                }
            }
        }

    private static func legacyOutcome(_ context: CallbackContext, status: dc_status_t, family: dc_family_t,
                                      hadStoredFingerprint: Bool) -> DownloadOutcome {
        outcome(status: status, family: family,
                fingerprintMatched: context.fingerprintMatched,
                hasNewDives: context.hasNewDives,
                hadStoredFingerprint: hadStoredFingerprint,
                emptyReadCount: context.emptyReadCount)
    }

    /// Same rule for the save and the commit: the stored device's model name, else what libdivecomputer called it.
    private static func fingerprintDeviceType(_ context: CallbackContext) -> String {
        if let stored = context.deviceStorage.getStoredDevice(uuid: context.deviceUUID),
           let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            return modelInfo.name
        }
        return context.deviceTypeFromLibDC ?? context.deviceName
    }

    private static func finishLegacy(_ context: CallbackContext, status enumStatus: dc_status_t, family: dc_family_t,
                                     viewModel: DiveDataViewModel, markFinished: () -> Void, completion: (Bool) -> Void) {
        let outcome = legacyOutcome(context, status: enumStatus, family: family,
                                    hadStoredFingerprint: context.storedFingerprint != nil)
        let downloadSucceeded = outcome.succeeded
        let shouldSaveFingerprint = outcome.saveFingerprint
        let emptyReadOnly = outcome.emptyReadOnly
        markFinished()

        // Record a stable status key for analytics before routing.
        viewModel.lastDownloadStatus = emptyReadOnly
            ? "emptyRead"
            : (downloadSucceeded ? "success" : statusName(enumStatus))
        viewModel.lastDownloadInterruption = outcome.interrupted
            ? DiveDataViewModel.DownloadInterruption(status: statusName(enumStatus),
                                                     divesDownloaded: context.logCount - 1 - context.emptyReadCount)
            : nil

        // Handle the outcome
        if !downloadSucceeded {
            if emptyReadOnly {
                logWarning("⚠️ Download returned only empty reads (\(context.emptyReadCount)) — likely BLE contention (official app holding the link)")
                viewModel.updateProgress(.emptyRead)
            } else if outcome.interrupted {
                logWarning("⚠️ Download interrupted after \(context.logCount - 1) dive(s): DC_STATUS_\(statusName(enumStatus)); fingerprint kept")
                viewModel.setDetailedError("Some dives couldn't be downloaded. Reconnect and sync again to fetch the rest.", status: enumStatus)
            } else {
                viewModel.setDetailedError("Download incomplete - DC_STATUS error code: \(enumStatus)", status: enumStatus)
            }
            completion(false)
        } else {
            // Download completed successfully
            if shouldSaveFingerprint, let lastFP = context.lastFingerprint, let serial = context.deviceSerial {
                // Use stored device configuration (user-selected) for consistent fingerprint storage
                let deviceType = fingerprintDeviceType(context)
                logInfo("✅ Download completed - \(context.logCount - 1) dive(s) downloaded")
                viewModel.saveFingerprint(lastFP, deviceType: deviceType, serial: serial)
                viewModel.finalizeDiveNumbering()  // Sort by date and renumber (oldest = #1)
                viewModel.updateProgress(.completed)
            } else if context.fingerprintMatched || (context.storedFingerprint != nil && !context.hasNewDives) {
                logInfo("ℹ️ No new dives found")
                viewModel.updateProgress(.noNewDives)
            } else {
                viewModel.finalizeDiveNumbering()  // Sort by date and renumber (oldest = #1)
                viewModel.updateProgress(.completed)
            }
            completion(true)
        }
    }

    /// `outcome`'s rule plus the session's: a cancel or an unparsed dive is its own outcome and never commits.
    static func sessionOutcome(_ legacy: DownloadOutcome, status: dc_status_t, cancelled: Bool, parseFailureCount: Int,
                               fingerprintMatched: Bool, hadStoredFingerprint: Bool, hasNewDives: Bool)
        -> (outcome: DiveDownloadResult.Outcome, commits: Bool) {
        if cancelled || status == DC_STATUS_CANCELLED { return (.cancelled, false) }
        guard legacy.succeeded else {
            if legacy.emptyReadOnly { return (.emptyRead, false) }
            return (legacy.interrupted ? .interrupted(status) : .failed(status), false)
        }
        if parseFailureCount > 0 { return (.unreadableDives(parseFailureCount), false) }
        if legacy.saveFingerprint { return (.completed, true) }
        if fingerprintMatched || (hadStoredFingerprint && !hasNewDives) { return (.noNewDives, false) }
        return (.completed, false)
    }

    private static func finishSession(_ context: CallbackContext, status enumStatus: dc_status_t, family: dc_family_t,
                                      viewModel: DiveDataViewModel) -> DiveDownloadResult {
        let hadStoredFingerprint = context.storedFingerprint != nil || context.deviceHadStoredFingerprint
        let legacy = legacyOutcome(context, status: enumStatus, family: family, hadStoredFingerprint: hadStoredFingerprint)
        let (outcome, commits) = sessionOutcome(legacy, status: enumStatus, cancelled: context.cancelled,
                                                parseFailureCount: context.parseFailureCount,
                                                fingerprintMatched: context.fingerprintMatched,
                                                hadStoredFingerprint: hadStoredFingerprint,
                                                hasNewDives: context.hasNewDives)
        let divesDownloaded = context.logCount - 1 - context.emptyReadCount

        var commit: FingerprintCommit?
        // A family that reports no fingerprints has nothing to commit, so every download fetches all its dives.
        if commits, let lastFP = context.lastFingerprint, !lastFP.isEmpty, let serial = context.deviceSerial {
            commit = FingerprintCommit(fingerprint: lastFP, deviceType: fingerprintDeviceType(context),
                                       serial: serial, viewModel: viewModel)
        }

        viewModel.lastDownloadInterruption = legacy.interrupted && outcome != .cancelled
            ? DiveDataViewModel.DownloadInterruption(status: statusName(enumStatus), divesDownloaded: divesDownloaded)
            : nil
        if context.hasNewDives {
            viewModel.finalizeDiveNumbering()  // Sort by date and renumber (oldest = #1)
        }

        switch outcome {
        case .completed:
            logInfo("✅ Download completed - \(divesDownloaded) dive(s) downloaded\(commit == nil ? "" : "; fingerprint awaits acknowledgement")")
            viewModel.lastDownloadStatus = "success"
            viewModel.updateProgress(.completed)
        case .noNewDives:
            logInfo("ℹ️ No new dives found")
            viewModel.lastDownloadStatus = "success"
            viewModel.updateProgress(.noNewDives)
        case .cancelled:
            logInfo("🛑 Download cancelled after \(divesDownloaded) dive(s); fingerprint kept")
            viewModel.lastDownloadStatus = "cancelled"
            viewModel.updateProgress(.cancelled)
        case .emptyRead:
            logWarning("⚠️ Download returned only empty reads (\(context.emptyReadCount)) — likely BLE contention (official app holding the link)")
            viewModel.lastDownloadStatus = "emptyRead"
            viewModel.updateProgress(.emptyRead)
        case .unreadableDives(let count):
            logWarning("⚠️ \(count) dive(s) couldn't be parsed; fingerprint kept")
            viewModel.lastDownloadStatus = "unreadableDives"
            viewModel.setError("\(count) dive(s) couldn't be read. The other \(divesDownloaded) were downloaded.")
        case .interrupted(let status):
            logWarning("⚠️ Download interrupted after \(divesDownloaded) dive(s): DC_STATUS_\(statusName(status)); fingerprint kept")
            viewModel.lastDownloadStatus = statusName(status)
            viewModel.setDetailedError("Some dives couldn't be downloaded. Reconnect and sync again to fetch the rest.", status: status)
        case .failed(let status):
            viewModel.lastDownloadStatus = statusName(status)
            viewModel.setDetailedError("Download incomplete - DC_STATUS error code: \(status)", status: status)
        }

        return DiveDownloadResult(outcome: outcome, status: enumStatus, divesDownloaded: divesDownloaded,
                                  parseFailureCount: context.parseFailureCount, fingerprintCommit: commit)
    }

    /// Legacy contract, kept for existing callers: saves the fingerprint itself, even past an unparsed dive; prefer `retrieveDiveLogs(session:)`.
    public static func retrieveDiveLogs(
            from devicePtr: UnsafeMutablePointer<device_data_t>,
            device: CBPeripheral,
            viewModel: DiveDataViewModel,
            bluetoothManager: CoreBluetoothManager,
            syncClock: Bool = false,
            useFingerprint: Bool = true,
            onProgress: ((Int, Int) -> Void)? = nil,
            completion: @escaping (Bool) -> Void
        ) {
            markRetrievalStarted(bluetoothManager)
            retrieveDiveLogs(
                from: devicePtr,
                deviceName: device.name ?? "Unknown Device",
                deviceUUID: device.identifier.uuidString,
                viewModel: viewModel,
                // Matches the pre-seam nil semantics: a deallocated manager reads as cancelled.
                isCancelled: { [weak bluetoothManager] in bluetoothManager?.isRetrievingLogs == false },
                markFinished: { markRetrievalFinished(bluetoothManager) },
                deviceStorage: .shared,
                syncClock: syncClock,
                useFingerprint: useFingerprint,
                onProgress: onProgress,
                completion: completion
            )
        }

    public static func getCurrentContext() -> CallbackContext? {
        return currentContext
    }

    // Set on the caller's turn, not later on the retrieval queue, so a cancel issued right after the call isn't overwritten.
    static func markRetrievalStarted(_ holder: RetrievalFlagHolder) {
        if Thread.isMainThread {
            holder.isRetrievingLogs = true
        } else {
            DispatchQueue.main.sync { holder.isRetrievingLogs = true }
        }
    }

    // Runs before completion so a download started from the completion handler keeps its flag.
    static func markRetrievalFinished(_ holder: RetrievalFlagHolder) {
        holder.isRetrievingLogs = false
    }
}
