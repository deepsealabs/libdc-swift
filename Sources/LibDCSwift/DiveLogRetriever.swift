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
        weak var bluetoothManager: RetrievalFlagHolder?
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
        /// Fingerprints of the dives the parser rejected, newest first. They were downloaded but not delivered, so the
        /// fingerprint must not move past them, unless an earlier download rejected them too (see `settle`).
        var rejectedFingerprints: [Data] = []
        var rejectedCount: Int { rejectedFingerprints.count }
        /// Fingerprints of the dives delivered, so an earlier rejection of one is forgotten.
        var deliveredFingerprints: [Data] = []
        /// The first rejection's status, reported when the download itself went through.
        var rejectionStatus: dc_status_t = DC_STATUS_DATAFORMAT
        /// When false, a "download only new" toggle-off — skip loading/comparing
        /// against the stored fingerprint entirely so a full history re-download
        /// isn't cut short by the fingerprint match early-return below.
        let useFingerprint: Bool
        /// Drivers report a callback stop as success; this keeps a host stop from passing as complete.
        var stoppedByHost = false

        var detectedFamily: dc_family_t = DC_FAMILY_NULL
        var detectedModel: UInt32 = 0

        init(viewModel: DiveDataViewModel, deviceName: String, deviceUUID: String, storedFingerprint: Data?, bluetoothManager: RetrievalFlagHolder?, useFingerprint: Bool = true) {
            self.viewModel = viewModel
            self.deviceName = deviceName
            self.deviceUUID = deviceUUID
            self.storedFingerprint = storedFingerprint
            self.bluetoothManager = bluetoothManager
            self.useFingerprint = useFingerprint
        }
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
        /// The download went through, but the parser rejected dives, so it failed.
        var parseRejected: Bool
    }

    /// Fingerprint rule: the stored fingerprint only advances when the whole
    /// enumeration succeeded. Drivers walk newest-first, so on any error the
    /// dives that did arrive are all newer than the failed one; storing any of
    /// their fingerprints would make the next sync stop before the gap. On
    /// error the old fingerprint is kept and the next sync re-walks from it
    /// (re-delivering the dives this session already got; hosts dedupe them).
    static func outcome(status: dc_status_t, family: dc_family_t, fingerprintMatched: Bool,
                        hasNewDives: Bool, hadStoredFingerprint: Bool, emptyReadCount: Int,
                        rejectedCount: Int = 0, unreadableCount: Int = 0) -> DownloadOutcome {
        var succeeded: Bool
        var saveFingerprint = false

        switch status {
        case DC_STATUS_SUCCESS:
            succeeded = true
            // A dive given up as unreadable no longer holds the fingerprint, even when no other dive came.
            saveFingerprint = hasNewDives || unreadableCount > 0
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
        let emptyReadOnly = emptyReadCount > 0 && !hasNewDives && rejectedCount == 0
        if emptyReadCount > 0 {
            saveFingerprint = false
            if emptyReadOnly { succeeded = false }
        }

        // A dive rejected for the first time is one the download failed to deliver: the fingerprint stays before it.
        let parseRejected = rejectedCount > 0 && succeeded
        if rejectedCount > 0 {
            saveFingerprint = false
            succeeded = false
        }

        return DownloadOutcome(succeeded: succeeded, saveFingerprint: saveFingerprint,
                               interrupted: !succeeded && hasNewDives, emptyReadOnly: emptyReadOnly,
                               parseRejected: parseRejected)
    }

    static func outcome(status: dc_status_t, family: dc_family_t, context: CallbackContext,
                        previouslyRejected: Set<Data> = []) -> DownloadOutcome {
        let rejections = splitRejections(context.rejectedFingerprints, previouslyRejected: previouslyRejected)
        return outcome(status: status, family: family, fingerprintMatched: context.fingerprintMatched,
                       hasNewDives: context.hasNewDives, hadStoredFingerprint: context.storedFingerprint != nil,
                       emptyReadCount: context.emptyReadCount, rejectedCount: rejections.retry.count,
                       unreadableCount: rejections.unreadable.count)
    }

    /// A first rejection holds the fingerprint, so the next download tries the dive once more. The parser gives the
    /// same bytes the same answer, so a dive an earlier download rejected too is unreadable: holding it would re-walk
    /// every dive since the stored fingerprint on every sync and fail each one. A dive with no fingerprint can't be
    /// recognised again, so it always holds.
    static func splitRejections(_ rejected: [Data], previouslyRejected: Set<Data>) -> (retry: [Data], unreadable: [Data]) {
        var retry: [Data] = [], unreadable: [Data] = []
        for fingerprint in rejected {
            if !fingerprint.isEmpty && previouslyRejected.contains(fingerprint) {
                unreadable.append(fingerprint)
            } else {
                retry.append(fingerprint)
            }
        }
        return (retry, unreadable)
    }

    /// Unreadable dives stay remembered, so a download that ignores the fingerprint doesn't hold on them again.
    static func rememberedRejections(previous: Set<Data>, rejected: [Data], delivered: [Data]) -> Set<Data> {
        previous.union(rejected.filter { !$0.isEmpty }).subtracting(delivered)
    }

    /// The key the device's fingerprint is stored under: the stored device's model name, else libdivecomputer's.
    static func fingerprintDeviceType(_ context: CallbackContext) -> String {
        if let stored = DeviceStorage.shared.getStoredDevice(uuid: context.deviceUUID),
           let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            return modelInfo.name
        }
        return context.deviceTypeFromLibDC ?? context.deviceName
    }

    /// Judges a finished download against the dives earlier downloads rejected and remembers this one's rejections.
    /// Returns the dives given up as unreadable. Main thread.
    static func settle(status: dc_status_t, family: dc_family_t,
                       context: CallbackContext) -> (outcome: DownloadOutcome, unreadable: [Data]) {
        guard let serial = context.deviceSerial else {
            return (outcome(status: status, family: family, context: context), [])
        }
        let deviceType = fingerprintDeviceType(context)
        let storage = DeviceFingerprintStorage.shared
        let previous = storage.rejectedDives(forDeviceType: deviceType, serial: serial)
        let remembered = rememberedRejections(previous: previous, rejected: context.rejectedFingerprints,
                                              delivered: context.deliveredFingerprints)
        if remembered != previous {
            storage.setRejectedDives(remembered, forDeviceType: deviceType, serial: serial)
        }
        let unreadable = splitRejections(context.rejectedFingerprints, previouslyRejected: previous).unreadable
        return (outcome(status: status, family: family, context: context, previouslyRejected: previous), unreadable)
    }

    /// The status a parse failure carries; DATAFORMAT when it carries none.
    static func parseFailureStatus(_ error: Error) -> dc_status_t {
        guard let error = error as? GenericParser.ParserError else { return DC_STATUS_DATAFORMAT }
        switch error {
        case .parserCreationFailed(let status), .datetimeRetrievalFailed(let status),
             .fieldRetrievalFailed(let status), .sampleProcessingFailed(let status):
            return status == DC_STATUS_SUCCESS ? DC_STATUS_DATAFORMAT : status
        case .invalidParameters:
            return DC_STATUS_DATAFORMAT
        }
    }

    /// CANCELLED whatever the driver said, so a cut-short download never advances the fingerprint past dives left on the device.
    static func downloadStatus(foreach status: dc_status_t, closedMidDownload: Bool,
                               stoppedByHost: Bool) -> dc_status_t {
        closedMidDownload || stoppedByHost ? DC_STATUS_CANCELLED : status
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

    static let diveCallbackClosure: @convention(c) (
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32 = { data, size, fingerprint, fsize, userdata in
        guard let data = data,
              let userdata = userdata,
              let fingerprint = fingerprint else {
            return 0
        }
        
        let context = Unmanaged<CallbackContext>.fromOpaque(userdata).takeUnretainedValue()
        
        if context.bluetoothManager?.isRetrievingLogs == false {
            logInfo("🛑 Download cancelled")
            context.stoppedByHost = true
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
                DeviceStorage.shared.updateDeviceSerial(uuid: context.deviceUUID, serial: serial)
            }

            // Firmware version reported alongside serial; a provenance snapshot
            // for the reading. 0 means the device reported none.
            let firmwareValue = devicePtr.pointee.devinfo.firmware
            if firmwareValue != 0 {
                DeviceStorage.shared.updateDeviceFirmware(uuid: context.deviceUUID, firmware: String(firmwareValue))
            }

            // Now that we have device info, load the stored fingerprint if we don't have it yet
            if context.useFingerprint,
               context.storedFingerprint == nil,
               let deviceType = context.deviceTypeFromLibDC,
               let serial = context.deviceSerial {
                context.storedFingerprint = context.viewModel.getFingerprint(forDeviceType: deviceType, serial: serial)
            }

            // Update storage if hardware tells us something different (e.g. 13 vs 9)
            DeviceConfiguration.updateDeviceConfigurationFromHardware(
                deviceAddress: context.deviceUUID,
                deviceDataPtr: devicePtr,
                deviceName: context.deviceName
            )
            
            context.hasDeviceInfo = true
        }
        
        let fingerprintData = Data(bytes: fingerprint, count: Int(fsize))

        // Capture the FIRST dive's fingerprint (most recent dive on the device)
        // This is what we'll compare against on the next download
        // Not keyed on logCount: a rejected newest dive leaves it at 1.
        if context.lastFingerprint == nil {
            context.lastFingerprint = fingerprintData
        }
        
        // Check if this dive matches our stored fingerprint (already downloaded)
        if let storedFingerprint = context.storedFingerprint {
            if storedFingerprint == fingerprintData {
                logInfo("✨ Found matching fingerprint - all new dives downloaded")
                context.fingerprintMatched = true
                return 0  // Stop enumeration - we've reached already-downloaded dives
            }
        }
        
        // 4. Parse & Store Dive
        var familyToUse: dc_family_t
        var modelToUse: UInt32
        
        // PRIORITY ORDER FOR MODEL SELECTION:
        // 1. Hardware Detection (Most reliable if available)
        // 2. Stored/Forced Configuration (What the user selected)
        // 3. Name-based Detection (Fallback)
        
        if context.detectedModel != 0 {
            familyToUse = context.detectedFamily
            modelToUse = context.detectedModel
        } else if let stored = DeviceStorage.shared.getStoredDevice(uuid: context.deviceUUID) {
            familyToUse = stored.family.asDCFamily
            modelToUse = stored.model
        } else if let deviceInfo = DeviceConfiguration.fromName(context.deviceName) {
            familyToUse = deviceInfo.family.asDCFamily
            modelToUse = deviceInfo.model
        } else {
            logError("❌ Unknown device configuration")
            return 0
        }

        guard let deviceFamily = DeviceConfiguration.DeviceFamily(dcFamily: familyToUse) else {
            logError("❌ Failed to map C family ID \(familyToUse) to Swift DeviceFamily enum")
            return 0
        }

        // Suunto Nautic dives without a surface GPS fix carry no datetime in
        // the parsed stream, but the fingerprint IS the dive's start time (a
        // little-endian UNIX timestamp). Supply it as a fallback so the dive
        // parses instead of throwing on the missing datetime.
        var fallbackDate: Date? = nil
        if deviceFamily == .suuntoNautic, fingerprintData.count == 4 {
            let b = [UInt8](fingerprintData)
            let id = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            fallbackDate = Date(timeIntervalSince1970: TimeInterval(id))
        }

        do {
            let diveData = try GenericParser.parseDiveData(
                family: deviceFamily,
                model: modelToUse,
                diveNumber: context.logCount,
                diveData: data,
                dataSize: Int(size),
                fingerprint: fingerprintData,
                fallbackDate: fallbackDate
            )
            
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
            context.deliveredFingerprints.append(fingerprintData)
            context.logCount += 1
            return 1
        } catch {
            // Go on to the older dives; settle decides whether this one holds the fingerprint.
            logError("❌ Failed to parse dive #\(context.logCount): \(error)")
            if context.rejectedFingerprints.isEmpty { context.rejectionStatus = parseFailureStatus(error) }
            context.rejectedFingerprints.append(fingerprintData)
            return 1
        }
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
            let retrievalQueue = DispatchQueue(label: "com.libdcswift.retrieval", qos: .userInitiated)
            // Before the hop, so a close from here on can't free the device under the queued download.
            bluetoothManager.beginRetrieval(devicePtr)

            retrievalQueue.async {
                DispatchQueue.main.async { viewModel.resetProgress() }
                
                guard let dcDevice = devicePtr.pointee.device else {
                    DispatchQueue.main.async {
                        bluetoothManager.endRetrieval(devicePtr)
                        viewModel.setDetailedError("No device connection found", status: DC_STATUS_IO)
                        markRetrievalFinished(bluetoothManager)
                        completion(false)
                    }
                    return
                }

                if dc_device_get_type(dcDevice) == DC_FAMILY_SUUNTO_NAUTIC {
                    let acknowledged = suunto_nautic_device_handshake_acknowledged(dcDevice) != 0
                    DispatchQueue.main.async { viewModel.lastHandshakeAcknowledged = acknowledged }
                }

                let deviceName = device.name ?? "Unknown Device"

                // Get device type from stored configuration (user-selected) for consistent fingerprint lookups
                let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: device.identifier.uuidString)
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
                    DeviceStorage.shared.updateDeviceSerial(uuid: device.identifier.uuidString, serial: serial)
                    if useFingerprint {
                        storedFingerprint = viewModel.getFingerprint(forDeviceType: deviceTypeForFingerprint, serial: serial)
                    }
                }

                let context = CallbackContext(
                    viewModel: viewModel,
                    deviceName: deviceName,
                    deviceUUID: device.identifier.uuidString,
                    storedFingerprint: storedFingerprint,
                    bluetoothManager: bluetoothManager,
                    useFingerprint: useFingerprint
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
                let progressTimerStopped = DispatchSemaphore(value: 0)
                progressTimer.setCancelHandler { progressTimerStopped.signal() }
                progressTimer.resume()
                
                if useFingerprint {
                    devicePtr.pointee.fingerprint_context = Unmanaged.passUnretained(viewModel).toOpaque()
                    devicePtr.pointee.lookup_fingerprint = fingerprintLookup
                } else {
                    // An earlier download on this connection may have set one on the device.
                    devicePtr.pointee.fingerprint_context = nil
                    devicePtr.pointee.lookup_fingerprint = nil
                    dc_device_set_fingerprint(dcDevice, nil, 0)
                }
                
                let foreachStatus = dc_device_foreach(dcDevice, diveCallbackClosure, contextPtr)
                let closedMidDownload = bluetoothManager.isCloseDeferred(devicePtr)
                if closedMidDownload {
                    logWarning("Download stopped because the device is being closed")
                }
                let enumStatus = downloadStatus(foreach: foreachStatus, closedMidDownload: closedMidDownload,
                                                stoppedByHost: context.stoppedByHost)

                // Log errors for debugging
                if enumStatus != DC_STATUS_SUCCESS && enumStatus != DC_STATUS_PROTOCOL {
                    logError("❌ Download failed: DC_STATUS_\(statusName(enumStatus))")
                }

                progressTimer.cancel()
                // The handler reads devicePtr, which a held-back close frees.
                progressTimerStopped.wait()

                // Sync the device clock to system time while the BLE session is still open.
                // Runs after a normal successful download, and also on the "no new dives"
                // fingerprint-match path so routine check-ins still update the clock.
                // DC_STATUS_UNSUPPORTED is normal for devices without timesync support.
                let clockSyncAllowed = enumStatus == DC_STATUS_SUCCESS
                    || (enumStatus == DC_STATUS_PROTOCOL && context.fingerprintMatched)
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
                    // Before completion, so the host never sees a device a held-back close is about to free.
                    bluetoothManager.endRetrieval(devicePtr)
                    let (outcome, unreadable) = DiveLogRetriever.settle(status: enumStatus, family: family, context: context)
                    let failureStatus = outcome.parseRejected ? context.rejectionStatus : enumStatus
                    let downloadSucceeded = outcome.succeeded
                    let shouldSaveFingerprint = outcome.saveFingerprint
                    let emptyReadOnly = outcome.emptyReadOnly
                    markRetrievalFinished(bluetoothManager)

                    // Record a stable status key for analytics before routing.
                    viewModel.lastDownloadStatus = emptyReadOnly
                        ? "emptyRead"
                        : (downloadSucceeded ? "success" : statusName(failureStatus))
                    viewModel.lastDownloadInterruption = outcome.interrupted
                        ? DiveDataViewModel.DownloadInterruption(status: statusName(failureStatus),
                                                                 divesDownloaded: context.logCount - 1 - context.emptyReadCount,
                                                                 divesRejected: context.rejectedCount)
                        : nil
                    viewModel.lastUnreadableDives = downloadSucceeded ? unreadable : []

                    // Handle the outcome
                    if !downloadSucceeded {
                        if context.stoppedByHost {
                            logInfo("Download stopped by the app after \(context.logCount - 1) dive(s); fingerprint kept")
                            viewModel.updateProgress(.cancelled)
                        } else if emptyReadOnly {
                            logWarning("⚠️ Download returned only empty reads (\(context.emptyReadCount)) — likely BLE contention (official app holding the link)")
                            viewModel.updateProgress(.emptyRead)
                        } else if outcome.parseRejected {
                            logWarning("⚠️ \(context.rejectedCount) dive(s) failed to parse: DC_STATUS_\(statusName(failureStatus)); fingerprint kept")
                            viewModel.setDetailedError("\(context.rejectedCount) dive(s) couldn't be read. Sync again to try once more; a dive that still can't be read is then skipped.", status: failureStatus)
                        } else if outcome.interrupted {
                            logWarning("⚠️ Download interrupted after \(context.logCount - 1) dive(s): DC_STATUS_\(statusName(enumStatus)); fingerprint kept")
                            viewModel.setDetailedError("Some dives couldn't be downloaded. Reconnect and sync again to fetch the rest.", status: enumStatus)
                        } else {
                            viewModel.setDetailedError("Download incomplete - DC_STATUS error code: \(enumStatus)", status: enumStatus)
                        }
                        completion(false)
                    } else {
                        // Download completed successfully
                        if !unreadable.isEmpty {
                            logWarning("⚠️ \(unreadable.count) dive(s) failed to parse again; skipped as unreadable, the fingerprint moves past them")
                        }
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
                    
                    context.isCompleted = true
                    Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
                }

                currentContext = context
            }
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
