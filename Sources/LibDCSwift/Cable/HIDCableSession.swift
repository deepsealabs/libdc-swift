#if os(macOS)
import Foundation
import IOKit
import Clibdivecomputer
import LibDCBridge

extension DiveComputerSession {
    /// Opens `model` on a USB HID endpoint: a `HIDStream` on the device's own IOHIDDevice, behind a `TapStream`, opened as `DC_TRANSPORT_USBHID`.
    static func openHID(
        _ endpoint: CableEndpoint,
        model: DCModel,
        discovery: CableDiscovering?,
        recorder: DCStreamRecorder?,
        deviceStorage: DeviceStorage,
        lease: DiveComputerSessionLease,
        cancellation: CableOpenCancellation,
        makeDevice: HIDDeviceFactory,
        claims: EndpointClaims = .shared
    ) throws -> DiveComputerSession {
        guard endpoint.transport == .usbHID else { throw CableError.unsupportedTransport(endpoint.transport) }
        guard let locator = endpoint.locator, let vid = endpoint.vendorID, let pid = endpoint.productID,
              let claimKey = endpoint.claimKey else {
            throw CableError.notFound
        }
        // EON Steel reports the opened descriptor's model as its own, so only a model this VID:PID can be is opened.
        guard model.transports.contains(.usbHID),
              DeviceCatalog.candidates(vid: vid, pid: pid, transport: .usbHID).contains(model),
              DeviceConfiguration.hasDescriptor(family: model.dcFamily, model: model.model) else {
            throw CableError.unsupportedTransport(.usbHID)
        }
        guard !cancellation.isCancelled else { throw CableError.cancelled }
        guard lease.tryAcquire() else { throw CableError.sessionInProgress }
        var leaseHeld = true
        defer { if leaseHeld { lease.release() } }

        guard let device = makeDevice(endpoint) else { throw CableError.notFound }
        let hid = HIDStream(device: device)
        let opened = hid.start()
        guard opened == kIOReturnSuccess else { throw CableError(hidOpen: opened) }

        var context: OpaquePointer?
        guard dc_context_new(&context) == DC_STATUS_SUCCESS, let context else {
            _ = hid.close()
            throw CableError.protocolError(DC_STATUS_NOMEMORY)
        }
        hid.setCancellation { cancellation.isCancelled }
        let inner: OpaquePointer
        do {
            inner = try DCCustomStream.open(backend: hid, transport: DC_TRANSPORT_USBHID, context: context)
        } catch {
            _ = hid.close()
            dc_context_free(context)
            throw CableError.protocolError((error as? DCCustomStreamError)?.status ?? DC_STATUS_NOMEMORY)
        }
        let tap = TapStream(inner: inner, recorder: recorder, isCancelled: { cancellation.isCancelled })
        let stream: OpaquePointer
        do {
            stream = try DCCustomStream.open(backend: tap, transport: tap.transport, context: context)
        } catch {
            // Closed here, while the context the inner stream logs to is still alive.
            _ = tap.close()
            dc_context_free(context)
            throw CableError.protocolError((error as? DCCustomStreamError)?.status ?? DC_STATUS_NOMEMORY)
        }

        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        data.pointee.context = context
        // One attempt, as on serial: a computer that didn't answer won't answer a retry on the same device.
        let status = open_device_on_iostream(data, stream, model.dcFamily, model.model, 1, 0)
        guard status == DC_STATUS_SUCCESS else {
            data.deinitialize(count: 1)
            data.deallocate()
            throw CableError.deviceFailed(status, family: model.family, portPresent: !hid.isRemoved)
        }

        let session = openedCable(devicePtr: data, displayName: model.name, storageKey: locator.locatorKey,
                                  locator: locator, deviceStorage: deviceStorage, lease: lease)
        leaseHeld = false
        let isCancelled: () -> Bool = { [weak session] in cancellation.isCancelled || (session?.isCancelled ?? true) }
        tap.setCancellation(isCancelled)
        hid.setCancellation(isCancelled)
        claims.claim(claimKey)
        session.onTeardown { claims.release(claimKey) }
        // The device itself says when it goes, so an unplug is seen without a discovery too.
        hid.setRemovalHandler { [weak session] in session?.markUnplugged() }
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

extension IOKitHIDDevice {
    static func make(_ endpoint: CableEndpoint) -> HIDDeviceIO? {
        endpoint.registryID.flatMap { IOKitHIDDevice(registryID: $0) }
    }
}

extension CableError {
    /// What IOHIDDeviceOpen failing with `result` means.
    init(hidOpen result: IOReturn) {
        switch result {
        case kIOReturnExclusiveAccess: self = .busy
        case kIOReturnNotPermitted, kIOReturnNotPrivileged: self = .permissionDenied
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotFound, kIOReturnOffline: self = .notFound
        default: self = .usbError(ioReturn: result)
        }
    }
}
#endif
