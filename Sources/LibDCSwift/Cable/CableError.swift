#if os(macOS)
import Foundation
import Clibdivecomputer

/// Why a cable session didn't open, or a cable download ended early, in terms a host can show.
public enum CableError: Error, Equatable {
    /// No cable opener for this endpoint's transport, or the model isn't reachable over it or has no libdivecomputer descriptor; nothing touched the port.
    case unsupportedTransport(DCTransport)
    /// macOS made no port for the cable; `CableEndpoint.driverMissingMessage` says which driver to get and where.
    case driverMissing
    /// The paired classic-Bluetooth port exists from an earlier pairing, but the computer isn't connected over Bluetooth now (ENOTCONN): off, out of range, or not in its upload mode.
    case bluetoothNotConnected
    /// The app may not open the port (EPERM, EACCES) or USB device (kIOReturnNotPermitted): a sandboxed app without `com.apple.security.device.serial` or `device.usb`, say.
    case permissionDenied
    /// Another app has the port open exclusively (EBUSY), or has seized the USB device (kIOReturnExclusiveAccess), often the computer maker's own app.
    case busy
    /// Another `DiveComputerSession` is open; there is one at a time.
    case sessionInProgress
    /// The port or USB device isn't there (ENOENT, ENXIO, ENODEV, kIOReturnNoDevice): it came out before the open.
    case notFound
    /// The cable came out while the session was open.
    case unplugged
    /// The computer didn't answer within the driver's timeout: the wrong model, not seated, or not in its PC or download mode.
    case noResponse(DeviceConfiguration.DeviceFamily)
    case cancelled
    /// The port wouldn't open for another reason, with its errno.
    case portError(errno: Int32)
    /// The USB device wouldn't open for another reason, with its IOReturn.
    case usbError(ioReturn: Int32)
    /// libdivecomputer failed with this status once the port was open (a protocol or data error, often the wrong model).
    case protocolError(dc_status_t)

    /// What `open(2)` on the port failing with `code` means.
    public init(openErrno code: Int32) {
        switch code {
        case EBUSY: self = .busy
        case EPERM, EACCES: self = .permissionDenied
        case ENOENT, ENXIO, ENODEV: self = .notFound
        case ENOTCONN: self = .bluetoothNotConnected
        default: self = .portError(errno: code)
        }
    }

    /// `dc_serial_open` failing after the pre-flight open succeeded, which leaves a race with another app or an unplug.
    static func portOpenFailed(_ status: dc_status_t) -> CableError {
        switch status {
        case DC_STATUS_NOACCESS: return .busy
        case DC_STATUS_NODEVICE: return .notFound
        case DC_STATUS_CANCELLED: return .cancelled
        default: return .protocolError(status)
        }
    }

    /// The device failing to open, or a download failing, on a port that is open; `portPresent` tells an unplug from a link error.
    static func deviceFailed(_ status: dc_status_t, family: DeviceConfiguration.DeviceFamily, portPresent: Bool) -> CableError {
        switch status {
        case DC_STATUS_TIMEOUT: return .noResponse(family)
        case DC_STATUS_CANCELLED: return .cancelled
        case DC_STATUS_IO, DC_STATUS_NODEVICE: return portPresent ? .protocolError(status) : .unplugged
        default: return .protocolError(status)
        }
    }

    /// What ended a cable download early, or nil when it didn't end early or the reason isn't the cable's (unreadable dives, an empty read).
    public init?(download result: DiveDownloadResult, session: DiveComputerSession) {
        if session.wasUnplugged {
            guard result.outcome != .completed, result.outcome != .noNewDives else { return nil }
            self = .unplugged
            return
        }
        let family = session.devicePtr.pointee.descriptor
            .flatMap { DeviceConfiguration.DeviceFamily(dcFamily: dc_descriptor_get_type($0)) }
        let portPresent = session.locator?.portPath.map { access($0, F_OK) == 0 } ?? true
        switch result.outcome {
        case .cancelled:
            self = .cancelled
        case .failed(let status), .interrupted(let status):
            guard let family else { self = .protocolError(status); return }
            // A timeout after some dives is a link that stalled, not a computer that never answered.
            if status == DC_STATUS_TIMEOUT, result.divesDownloaded > 0 {
                self = .protocolError(status)
                return
            }
            self = Self.deviceFailed(status, family: family, portPresent: portPresent)
        case .completed, .noNewDives, .emptyRead, .unreadableDives:
            return nil
        }
    }

    /// An English sentence for logs and hosts that don't localize their own.
    public var message: String {
        switch self {
        case .unsupportedTransport(let transport):
            return "This dive computer can't be downloaded over this connection (\(transport.rawValue))."
        case .driverMissing:
            return "macOS made no serial port for this cable. Install the driver for its USB-serial chip, then unplug the cable and plug it in again."
        case .bluetoothNotConnected:
            return "This dive computer isn't connected over Bluetooth. Start Upload Log on it and keep it near the Mac; if it was unpaired, pair it again in System Settings > Bluetooth."
        case .permissionDenied:
            return "This app isn't allowed to open the cable's serial port or the dive computer's USB connection."
        case .busy:
            return "Another app is using the cable or dive computer. Quit the dive computer maker's app, then try again."
        case .sessionInProgress:
            return "Another dive computer download is in progress."
        case .notFound:
            return "The cable or dive computer isn't connected. Plug it in and try again."
        case .unplugged:
            return "The cable was unplugged during the download."
        case .noResponse(let family):
            let checkCable: String
            switch family {
            case .shearwaterPredator, .shearwaterPetrel:
                checkCable = "Check that the model is right. "
            default:
                checkCable = "Check that the model is right and the cable is seated. "
            }
            return "The dive computer didn't answer. " + checkCable + DeviceCatalog.cableConnectInstructions(for: family)
        case .cancelled:
            return "The download was cancelled."
        case .portError(let code):
            return "The cable's serial port couldn't be opened (\(String(cString: strerror(code))))."
        case .usbError(let code):
            return "The dive computer's USB connection couldn't be opened (IOReturn " + String(format: "0x%08x", code) + ")."
        case .protocolError(let status):
            return "The dive computer's reply couldn't be read (libdivecomputer status \(status.rawValue)). Check that the model is right."
        }
    }
}

extension CableError: LocalizedError {
    public var errorDescription: String? { message }
}

extension DiveComputerLocator {
    /// The device file a serial or paired-Bluetooth locator opens.
    var portPath: String? {
        switch self {
        case .serial(let path, _, _, _), .classicBTSerial(let path): return path
        case .ble, .usbHID, .usb: return nil
        }
    }
}

extension DeviceCatalog {
    /// What to do on the computer before a cable download, for a "no response" message.
    public static func cableConnectInstructions(for family: DeviceConfiguration.DeviceFamily) -> String {
        switch family {
        case .suuntoSolution, .suuntoEon, .suuntoVyper, .suuntoVyper2, .suuntoD9:
            return "Clip the Suunto cable on so its contacts touch the computer's, with the computer showing the time, not a menu or a dive."
        case .oceanicVtpro, .oceanicVeo250, .oceanicAtom2:
            return "Plug the cable into the computer's data port. Most models switch to PC or download mode on their own; if yours doesn't, start it from the computer's menu."
        case .maresNemo, .maresPuck, .maresDarwin, .maresIconHD:
            return "If the computer has a PC mode, start it from the menu, then attach the Mares cable or interface."
        case .cressiEdy, .cressiLeonardo, .cressiGoa:
            return "Attach the Cressi cable, then start the computer's PC or data transfer mode from its menu if it has one."
        case .hwOstc, .hwOstc3, .hwFrog:
            return "Wake the computer. On OSTC 3 and later models, start the download mode from the menu if it doesn't connect on its own."
        case .reefnetSensus, .reefnetSensusPro, .reefnetSensusUltra:
            return "Seat the Sensus in its ReefNet interface so the contacts touch."
        case .uwatecAladin, .uwatecMemomouse:
            return "Seat the computer on the Memomouse so its contacts touch the pins."
        case .suuntoEonSteel:
            return "Attach the Suunto USB cable so it clicks onto the computer's contacts, then wake the computer."
        case .uwatecSmart:
            return "Connect the computer's USB cable, then wake the computer."
        case .shearwaterPredator, .shearwaterPetrel:
            // No cable: classic Bluetooth only comes up once the computer's own Upload Log starts it.
            return "On the computer, open Dive Log > Upload Log so it shows Wait PC, keep it near the Mac, then try again. If it still doesn't connect, check it's paired in System Settings > Bluetooth."
        default:
            return "Wake the computer, attach the cable, and start its PC, download or transfer mode if it has one."
        }
    }
}
#endif
