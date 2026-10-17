# USB HID dive computers on macOS

Some dive computers are USB HID devices themselves: the cable carries USB straight to the computer, with no
USB-serial chip in between. On macOS, LibDCSwift downloads them through `HIDStream`, a `DCIOStreamBackend` on
the computer's own `IOHIDDevice`. It is opened through `DCCustomStream` as `DC_TRANSPORT_USBHID`, so
libdivecomputer's EON Steel and Uwatec Smart drivers take their USB HID code paths. No HID library is vendored,
and `HAVE_HIDAPI` stays undefined, so `usbhid.c` is still a stub. iOS builds contain none of this: every type
on this page is `#if os(macOS)`.

A sandboxed app needs the `com.apple.security.device.usb` entitlement to open a device. Listing devices needs
no entitlement. Downloads never ask for Input Monitoring (see below).

| VID:PID | Models offered | Notes |
|---|---|---|
| 1493:0030 | Suunto EON Steel | |
| 1493:0033 | Suunto EON Core | |
| 1493:0035 | Suunto D5 | |
| 1493:0036 | Suunto EON Steel Black | |
| 2e6c:3201 | Scubapro G2, Scubapro G2 TEK | One PID for both. The user picks one, and DEVINFO's model names the computer |
| 2e6c:3211 | Scubapro G2 Console | |
| 2e6c:4201 | Scubapro G2 HUD | |
| c251:2006 | Scubapro Aladin Square | USB HID only |

The Scubapro G3 has no PID in libdivecomputer's table yet, so it isn't listed.

## Finding computers

`IOKitCableDiscovery` lists USB HID computers next to serial ports, before them. They come from an
`IOHIDManager` whose matching is `IOHIDManagerSetDeviceMatchingMultiple` on vendor IDs 0x1493, 0x2e6c and
0xc251 only (`HIDVendors.vendorIDs`). The manager is never opened (`IOHIDManagerOpen` is never called), and no
keyboard or mouse is ever matched, so listing devices can't raise the Input Monitoring prompt. The same manager,
activated on the discovery's queue, reports arrivals and removals.

A matched device becomes an endpoint only when its VID:PID is a model above (`DeviceCatalog.candidates`). That
leaves out other devices on the same vendor IDs: a Suunto watch on 0x1493, or a Keil debug probe on 0xc251,
whose vendor ID the Aladin Square uses. A device on the generic desktop usage page (keyboards and mice) is never
listed either.

A USB HID endpoint has `transport == .usbHID`, an `id` of `usbhid:<registry id>`, no `calloutPath`, the device's
`registryID`, and a `locator` of `.usbHID(vid:pid:registryID:)`. Its `status` is `ready`, or `busy` while a
session in this process has it open. Another app holding it is only found at open, as `CableError.busy`.

## Opening and downloading

```swift
let session = try await DiveComputerSession.open(endpoint, model: model, discovery: discovery)
DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result in
    if let error = CableError(download: result, session: session) { /* show error.message */ }
    result.fingerprintCommit?.acknowledge()
    session.close()
}
```

This is the same call as for a serial endpoint. For a USB HID endpoint, `open` does this on the cable queue:

1. It refuses a model that this VID:PID can't be (`unsupportedTransport(.usbHID)`) before the device is touched.
   The EON Steel driver reports the opened descriptor's model as the computer's own, so opening an EON Steel
   as an EON Core would store it as one. It takes the session lease, or throws `sessionInProgress`.
2. It creates a fresh `IOHIDDevice` from the endpoint's registry entry. A device that was cancelled can't be
   scheduled again, so every open gets a new one.
3. `HIDStream.start()` opens it with `IOHIDDeviceOpen`, seizing it by default as hidapi does on macOS.
4. It wraps the stream in a `TapStream` (for packet logging on the `"usbhid"` channel and optional `.dcrec`
   recording) and opens the device with one `dc_device_open` attempt.

Cancelling the opening task, or calling `session.cancel()`, ends a blocked read within 100 ms. Writes can't be
interrupted, and they aren't refused after a cancel, so a driver's quit command still goes out on close. The
device reports its own removal, so pulling it out ends the download and sets `wasUnplugged` even without a
discovery. With one, the endpoint also disappears.

| `CableError` | From |
|---|---|
| `unsupportedTransport(.usbHID)` | A model that isn't one of the endpoint's candidates, or has no descriptor |
| `busy` | `kIOReturnExclusiveAccess`: another app has seized the device (often the computer maker's app) |
| `permissionDenied` | `kIOReturnNotPermitted`, `kIOReturnNotPrivileged`: usually a sandbox without `device.usb` |
| `notFound` | The registry entry is gone, or `kIOReturnNoDevice`, `kIOReturnNotAttached`, `kIOReturnNotFound`, `kIOReturnOffline` |
| `usbError(ioReturn:)` | `IOHIDDeviceOpen` failed for another reason |
| `noResponse(family)` | `DC_STATUS_TIMEOUT` before any dive. `message` adds `DeviceCatalog.cableConnectInstructions(for:)` |
| `unplugged` | The device went away during the session |
| `protocolError(status)` | Anything else libdivecomputer reports once the device is open |

A seize also succeeds over another app's shared open and cuts that app off. The device stays seized until the
session closes.

## What each operation does

`HIDStream` answers each iostream operation the way `usbhid.c` does when it is built with hidapi, which is the
path libdivecomputer uses on macOS:

| Operation | Behaviour |
|---|---|
| `set_timeout` | Negative blocks, 0 returns at once, N waits N ms. The stream starts at -1, as `usbhid.c` does |
| `read` | One input report per call, with the report-ID byte exactly as IOKit delivered it (the EON Steel driver checks byte 0 is 0x3f), cut to the requested size. The rest of a cut report is dropped. A timeout is `SUCCESS` with 0 bytes, as `hid_read_timeout` returning 0 is. After a removal, reports that arrived first are still read, then `IO` |
| `write` | If byte 0 is 0, `IOHIDDeviceSetReport(Output, 0, data + 1, n - 1)`; otherwise `IOHIDDeviceSetReport(Output, data[0], data, n)`. In both cases `actual` is n, report-ID byte included. An empty write sends nothing. A failed report is `IO` |
| `poll`, `ioctl` | `UNSUPPORTED` |
| `configure`, `purge`, `flush`, `sleep`, `set_break`, `set_dtr`, `set_rts` | `SUCCESS`, doing nothing, because `usbhid.c` has no entry for them. `purge` doesn't drop queued reports, and `sleep` returns at once |
| `get_lines`, `get_available` | `SUCCESS` with 0 |
| `close` | See the lifecycle below |

At most 30 unread reports are kept, and the oldest is dropped beyond that, as in hidapi's macOS backend. The
report buffer is the device's `kIOHIDMaxInputReportSizeKey`, and never under 64 bytes.

## Lifecycle

`HIDStream` follows the rules in `IOHIDDevice.h` for a device on a dispatch queue:

```
created --start()--> IOHIDDeviceOpen --fails--> closed (nothing else was called)
                         |
                         v
                      opened: IOHIDDeviceRegisterInputReportCallback(buffer)
                              IOHIDDeviceRegisterRemovalCallback
                              IOHIDDeviceSetDispatchQueue (once)
                              IOHIDDeviceSetCancelHandler
                              IOHIDDeviceActivate
                         |
                         v
                      active  --close()--> IOHIDDeviceCancel --> cancelling
                                                                    |
                         cancel handler, on the device's queue:     v
                           IOHIDDeviceClose (skipped once removed)
                           release the device and the report buffer --> closed
```

- Every "Register" call and the dispatch queue are set before activation, never after.
- The cancel handler owns the device and the buffer IOKit copies reports into. Neither is freed until the
  handler has run, even if the stream itself is gone, because IOKit can still deliver a report up to then.
- `close()` waits up to 2 s for the handler. If the handler is late, `close()` returns anyway, and the handler
  still closes and releases the device when it runs.
- An unplugged device is never closed, as in hidapi.
- A stream that is dropped without being closed cancels its device, and the handler cleans up.

`HIDDeviceIO` is the seam: `IOKitHIDDevice` is the live device, and the tests use a fake that checks this order
and fails on anything the header forbids.

## Testing

- `HIDStreamTests` cover the lifecycle and the semantics above against the fake device.
- `HIDCableSessionTests` run libdivecomputer's own EON Steel and Uwatec Smart drivers through `HIDStream`
  against emulated computers built from `suunto_eonsteel.c` and `uwatec_smart.c`. They cover the open, DEVINFO,
  multi-report file reads, unplug, cancel, refusals, and a download recorded through the tap and replayed
  through `ScriptedStream`. All values are synthetic.
- `HIDDiscoveryTests` cover which HID devices become endpoints and how hot-plug cancels a session.

### Recording a real computer

`HIDHardwareTests` runs against a real computer when `LIBDC_USBHID_MODEL` is set:

```sh
LIBDC_USBHID_MODEL="Suunto EON Steel" swift test --filter HIDHardwareTests
```

It finds the computer through `IOKitCableDiscovery` and downloads everything through a `DCStreamRecorder`. It
checks that Input Monitoring wasn't requested, and scrubs the computer's serial from the recording. If the
scrubbed copy replays to the same dives, it writes the recording to
`Tests/LibDCSwiftTests/Fixtures/Hardware/<family>_<model>_usbhid.dcrec`. Then it downloads again and expects
`.noNewDives`. With `LIBDC_USBHID_EXPECT_BUSY=1`, it expects the open to fail with `busy` instead, for a run with
the maker's app holding the device. As with serial recordings, dive dates stay as the computer sent them, so
commit a recording only for dives that are fine to publish.

## If IOKit's HID path fails on hardware

The fallback is to vendor hidapi under its BSD licence option and build `usbhid.c` with `HAVE_HIDAPI`. That is
only worth doing if hardware testing shows `HIDStream` can't do something hidapi can. It isn't part of the
library today.
