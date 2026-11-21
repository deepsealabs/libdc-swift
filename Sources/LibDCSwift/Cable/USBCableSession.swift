#if os(macOS)
import Foundation
import IOKit
import Clibdivecomputer
import LibDCBridge

extension DiveComputerSession {
    /// Opens `model` on a raw USB endpoint: a `USBStream` on the computer's claimed interface, behind a `TapStream`, opened as `DC_TRANSPORT_USB`.
    static func openUSB(
        _ endpoint: CableEndpoint,
        model: DCModel,
        discovery: CableDiscovering?,
        recorder: DCStreamRecorder?,
        deviceStorage: DeviceStorage,
        lease: DiveComputerSessionLease,
        cancellation: CableOpenCancellation,
        makeDevice: USBDeviceFactory,
        claims: EndpointClaims = .shared
    ) throws -> DiveComputerSession {
        guard endpoint.transport == .usb else { throw CableError.unsupportedTransport(endpoint.transport) }
        guard let locator = endpoint.locator, let vid = endpoint.vendorID, let pid = endpoint.productID,
              let claimKey = endpoint.claimKey else {
            throw CableError.notFound
        }
        guard model.transports.contains(.usb),
              DeviceCatalog.candidates(vid: vid, pid: pid, transport: .usb).contains(model),
              DeviceConfiguration.hasDescriptor(family: model.dcFamily, model: model.model),
              let layout = USBComputers.layout(vendorID: vid, productID: pid) else {
            throw CableError.unsupportedTransport(.usb)
        }
        guard !cancellation.isCancelled else { throw CableError.cancelled }
        guard lease.tryAcquire() else { throw CableError.sessionInProgress }
        var leaseHeld = true
        defer { if leaseHeld { lease.release() } }

        let device = try makeDevice(endpoint, layout)
        let usb = USBStream(device: device, endpointIn: layout.endpointIn, endpointOut: layout.endpointOut)
        usb.cancelCheck = { cancellation.isCancelled }
        // A dive tail a killed app left on bulk IN would arrive in place of the version block, and its garbage become the identity.
        usb.drainStaleInput()

        var context: OpaquePointer?
        var innerContext: OpaquePointer?
        guard dc_context_new(&context) == DC_STATUS_SUCCESS, let context else {
            device.close()
            throw CableError.protocolError(DC_STATUS_NOMEMORY)
        }
        // The inner stream logs WARNING and up on its own context, so a debug log has each driver call once, from the tap's stream.
        guard dc_context_new(&innerContext) == DC_STATUS_SUCCESS, let innerContext else {
            device.close()
            dc_context_free(context)
            throw CableError.protocolError(DC_STATUS_NOMEMORY)
        }
        attach_libdc_log(innerContext)
        dc_context_set_loglevel(innerContext, DC_LOGLEVEL_WARNING)
        var opened: OpaquePointer?
        let openStatus = usb.open(&opened, context: innerContext)
        guard openStatus == DC_STATUS_SUCCESS, let inner = opened else {
            dc_context_free(innerContext)
            dc_context_free(context)
            throw CableError.protocolError(openStatus == DC_STATUS_SUCCESS ? DC_STATUS_NOMEMORY : openStatus)
        }
        let tap = TapStream(inner: inner, recorder: recorder, isCancelled: { cancellation.isCancelled })
        let stream: OpaquePointer
        do {
            stream = try DCCustomStream.open(backend: tap, transport: tap.transport, context: context)
        } catch {
            // Closed here, while the context the inner stream logs to is still alive.
            _ = tap.close()
            dc_context_free(innerContext)
            dc_context_free(context)
            throw CableError.protocolError((error as? DCCustomStreamError)?.status ?? DC_STATUS_NOMEMORY)
        }

        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.context = context
        // One attempt, as on serial and USB HID: a computer that didn't answer won't answer a retry on the same device.
        let status = open_device_on_iostream(data, stream, model.dcFamily, model.model, 1, 0)
        guard status == DC_STATUS_SUCCESS else {
            // The failed open closed the tap's stream, and the inner stream with it.
            dc_context_free(innerContext)
            data.deinitialize(count: 1)
            data.deallocate()
            throw CableError.deviceFailed(status, family: model.family, portPresent: !usb.isRemoved && device.isAttached)
        }
        data.pointee.stream_context = innerContext

        let session = openedCable(devicePtr: data, displayName: model.name, storageKey: locator.locatorKey,
                                  locator: locator, deviceStorage: deviceStorage, lease: lease)
        leaseHeld = false
        // Held past close, so a download that failed can still tell an unplug from a link error.
        session.setPresenceCheck { !usb.isRemoved && device.isAttached }
        let isCancelled: () -> Bool = { [weak session] in cancellation.isCancelled || (session?.isCancelled ?? true) }
        tap.setCancellation(isCancelled)
        // Upstream never interrupts a close: its transfers run on their own timeouts, unless the cable already went.
        session.onClosing { state in
            usb.cancelCheck = nil
            usb.abortCheck = { state.unplugged }
            tap.beginClosing(sessionCancelled: state.cancelled || cancellation.isCancelled)
        }
        usb.cancelCheck = isCancelled
        // An unplug the registry saw aborts at once; there is no dive left to finish.
        usb.abortCheck = { [weak session] in session?.wasUnplugged ?? true }
        claims.claim(claimKey)
        session.onTeardown { claims.release(claimKey) }
        // A transfer that finds the device gone says so, so an unplug is seen without a discovery too.
        usb.removalHandler = { [weak session] in session?.markUnplugged() }
        if usb.isRemoved { session.markUnplugged() }
        discovery?.cancelOnRemoval(of: endpoint.id, session: session)
        if session.wasUnplugged {
            session.close()
            throw CableError.unplugged
        }
        if cancellation.isCancelled {
            session.close()
            throw CableError.cancelled
        }
        return session
    }
}

/// Opens the `USBDeviceIO` a raw USB endpoint names, with its layout; tests pass fakes.
typealias USBDeviceFactory = (CableEndpoint, USBInterfaceLayout) throws -> USBDeviceIO

extension IOKitUSBDevice {
    static func make(_ endpoint: CableEndpoint, _ layout: USBInterfaceLayout) throws -> USBDeviceIO {
        guard let registryID = endpoint.registryID else { throw CableError.notFound }
        var result: Int32 = kIOReturnSuccess
        guard let device = IOKitUSBDevice.open(registryID: registryID, interfaceNumber: layout.interfaceNumber,
                                               endpointIn: layout.endpointIn, endpointOut: layout.endpointOut,
                                               result: &result) else {
            throw CableError(usbOpen: result)
        }
        return device
    }
}

extension CableError {
    /// What opening a raw USB computer's device and interface failing with `result` means.
    init(usbOpen result: IOReturn) {
        switch result {
        case kIOReturnExclusiveAccess: self = .busy
        case kIOReturnNotPermitted, kIOReturnNotPrivileged: self = .permissionDenied
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotFound, kIOReturnOffline: self = .notFound
        default: self = .usbError(ioReturn: result)
        }
    }
}
#endif
