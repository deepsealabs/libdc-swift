# Raw USB dive computers on macOS (Beta)

libdivecomputer reads one family over raw USB (`DC_TRANSPORT_USB`) rather than USB-serial or USB HID: the
Atomic Aquatics Cobalt and Cobalt 2. Upstream does this through `usb.c` and libusb. LibDCSwift leaves
`HAVE_LIBUSB` undefined, so `usb.c` stays a stub. On macOS it uses `USBStream` instead: an Objective-C stream
in LibDCBridge (`USBBridge.m`) on IOUSBLib, opened through `dc_custom_open` as `DC_TRANSPORT_USB`, so
libdivecomputer's own Cobalt driver (`atomics_cobalt.c`) runs unchanged. iOS builds contain none of this:
`USBBridge.m` and `USBBridge.h` are `TARGET_OS_OSX` only, and every Swift type on this page is `#if os(macOS)`.

**Beta.** No real Cobalt has been downloaded through this path yet. The library ships it on, and marks the two
models beta: `DCModel.isBeta(on: .usb)` and `CableEndpoint.isBeta` are true for them, from
`DeviceCatalog.betaFamilies`. Hosts should label them "Beta". A host that wants to turn the transport off can
leave `.usb` endpoints out of what it shows.

A sandboxed app needs the `com.apple.security.device.usb` entitlement to open the device. Listing devices needs
no entitlement.

| VID:PID | Models offered | Interface | Endpoints |
|---|---|---|---|
| 0471:0888 | Atomic Aquatics Cobalt, Atomic Aquatics Cobalt 2 | 0 | bulk IN 0x82, bulk OUT 0x02 |

The table is `USBComputers.all`, a copy of `usb.c`'s `g_usb_config`. Both models share the PID, so either can
be picked. The driver reads the model from the computer's version block, and DEVINFO's model names the
computer: 0 is a Cobalt, 2 a Cobalt 2. Model 0 is a real model here, not "unreported" (see
`DEVICE_IDENTITY.md`). The serial is the version block's 8 ASCII digits, read as a decimal number.

## Finding computers

`IOKitCableDiscovery` lists raw USB computers after USB HID computers and before serial ports. They come from
the same `IOUSBHostDevice` read that finds known USB-serial cables, matched on `USBComputers`' VID:PIDs, and the
same notification port follows them: the discovery watches vendor ID 0x0471 as well as the cable vendors. A
device on that vendor ID that isn't a Cobalt (Philips and NXP make many) never becomes an endpoint.

A raw USB endpoint has `transport == .usb`, an `id` of `usbdevice:<registry id>`, no `calloutPath`, the USB
device's `registryID`, and a `locator` of `.usb(vid:pid:registryID:)`. Its `status` is `ready`, or `busy` while a
session in this process has it open. Another app holding the interface is only found at open, as
`CableError.busy`.

## Opening and downloading

`DiveComputerSession.open(_:model:discovery:recorder:deviceStorage:lease:)` is the same call as for serial and
USB HID endpoints. For a raw USB endpoint, on the cable queue, it:

1. Refuses a model that isn't one of the endpoint's candidates, or has no descriptor
   (`unsupportedTransport(.usb)`), before the device is touched. It takes the session lease, or throws
   `sessionInProgress`.
2. Opens the device fresh with `IOKitUSBDevice.open(registryID:interfaceNumber:endpointIn:endpointOut:result:)`:
   - `IOCreatePlugInInterfaceForService` for an `IOUSBDeviceInterface500`, then `USBDeviceOpenSeize`. When
     another client has the device (`kIOReturnExclusiveAccess`), it goes on without it, as libusb does, since
     the interface may still be free.
   - If the device has no configuration, it sets the first one. A vendor-class device can arrive unconfigured,
     with no interfaces until then.
   - It finds interface 0, opens an `IOUSBInterfaceInterface500` on it with `USBInterfaceOpen`, and finds the
     bulk pipes at 0x82 and 0x02.
3. Wraps a `USBStream` on it in a `TapStream` (packet logging on the `"usb"` channel, optional `.dcrec`
   recording), and opens the device with one `dc_device_open` attempt.

The Cobalt's open sets a 2 s timeout, sends vendor request 0x01 on the default pipe and reads the 16-byte
version block. A download sends 0x09 for the newest dive and 0x0A for each next one, reading each in 8 KiB bulk
reads until a short one, and stops at two 0xFF bytes. Every reply ends with a 16-bit additive checksum. The
Cobalt has no quit command, so closing a session only releases the interface and device.

Cancelling the opening task, or calling `session.cancel()`, aborts a blocked transfer within 50 ms
(`USBStream.cancelCheckMilliseconds`). A transfer that fails with the device gone from the registry marks the
session unplugged, so `CableError(download:session:)` is `.unplugged` even without a discovery. With one, the
endpoint also disappears.

| `CableError` | From |
|---|---|
| `unsupportedTransport(.usb)` | A model that isn't one of the endpoint's candidates, or has no descriptor |
| `busy` | `kIOReturnExclusiveAccess` from `USBInterfaceOpen`: another app has the interface |
| `permissionDenied` | `kIOReturnNotPermitted`, `kIOReturnNotPrivileged`: usually a sandbox without `device.usb` |
| `notFound` | The registry entry is gone, or `kIOReturnNoDevice`, `kIOReturnNotAttached`, `kIOReturnNotFound`, `kIOReturnOffline` |
| `usbError(ioReturn:)` | Any other open failure, such as `kIOUSBInterfaceNotFound` or `kIOUSBEndpointNotFound` |
| `noResponse(.atomicsCobalt)` | `DC_STATUS_TIMEOUT` before any dive: the version request went unanswered |
| `unplugged` | The device went away during the session |
| `protocolError(status)` | Anything else libdivecomputer reports once the device is open, such as a bad checksum |

## What each operation does

`USBStream` answers each iostream operation as `usb.c` does when built with libusb, and installs all 15
callbacks, because `dc_custom_open` turns a missing one into a silent `SUCCESS`.

| Operation | Behaviour |
|---|---|
| `set_timeout` | Negative waits for ever, 0 is `UNSUPPORTED` (libusb has no polling read), N is N ms. It starts waiting for ever, as `usb.c` does |
| `read` | One bulk IN transfer of up to `size` bytes on 0x82, ended by a short packet, the full size, or the timeout. A timeout is `TIMEOUT` with the bytes that arrived before it, which `atomics_cobalt.c` takes as the end of a dive. A packet bigger than what's left of the request is an overrun (`IO`) |
| `write` | One bulk OUT transfer on 0x02, with no timeout, as `usb.c`'s write |
| `ioctl` | `DC_IOCTL_USB_CONTROL_READ` and `_WRITE`: a `dc_usb_control_t` (8 bytes: `bmRequestType`, `bRequest`, `wValue`, `wIndex`, `wLength`) followed by its `wLength`-byte data stage, sent with `DeviceRequestTO` and the stream's timeout. A buffer shorter than the setup, or than the setup plus `wLength`, is `INVALIDARGS` and nothing is sent. Any other request is `UNSUPPORTED` |
| `poll` | `UNSUPPORTED` |
| `configure`, `purge`, `flush`, `sleep`, `set_break`, `set_dtr`, `set_rts` | `SUCCESS`, doing nothing, because `usb.c` has no entry for them. `sleep` returns at once |
| `get_lines`, `get_available` | `SUCCESS` with 0 |
| `close` | Closes the interface and the device, once |

IOReturns map as libusb's macOS backend and then `usb.c`'s `syserror` map them: success and
`kIOReturnUnderrun` are `SUCCESS`; `kIOUSBTransactionTimeout` is `TIMEOUT`; `kIOReturnNoDevice`,
`kIOReturnNotOpen` and `kIOReturnNotAttached` are `NODEVICE`; exclusive access and permission errors are
`NOACCESS`; a bad argument is `INVALIDARGS`; no memory is `NOMEMORY`; anything else (a stall, an overrun, an
abort) is `IO`. A failure with the device gone from the registry is `NODEVICE`. Once the cancel check is true,
transfers return `CANCELLED`.

Where this differs from `usb.c`, and why:

- **Reads ask for one max-size packet at a time.** A `ReadPipeTO` that times out reports no byte count, so one
  request for the whole size would lose whatever arrived before the timeout. Asking packet by packet, with the
  read's timeout as one deadline across them, gives the same result as libusb's single transfer: the same bytes,
  the same end on a short packet, and the partial count on a timeout. It costs a round trip per packet (64 bytes
  at full speed).
- **After a timed-out read, `ClearPipeStallBothEnds`** puts the data toggle back in step, as IOUSBLib asks.
- **A control transfer that moved its data stage is `SUCCESS`.** `usb.c` takes `libusb_control_transfer`'s byte
  count for an error, so its libusb build would report `IO` for one. No driver sends a data stage today (the
  Cobalt's requests have `wLength` 0).
- **Cancel aborts.** While a transfer blocks, a timer checks the cancel check every 50 ms and, once it's true,
  calls `AbortPipe` on both pipes and `USBDeviceAbortPipeZero`. Writes and control transfers are refused after a
  cancel too: `usb.c`'s writes have no timeout, and the Cobalt sends nothing on close.

`USBDeviceIO` (the Objective-C protocol `LibDCUSBDevice`) is the seam: `IOKitUSBDevice` is the live device, and
the tests use a fake with USB's bulk rules.

## Testing

- `USBStreamTests` run `USBStream` against the fake: the 15 operations against `usb.c`'s table, the timeout
  rules, the control setup's layout and `wLength` bounds, packet-by-packet reads, a short packet, a zero-length
  packet, a timeout keeping its partial count and clearing the stall, the timeout as one deadline, overrun, the
  IOReturn mapping, removal, cancel within one check, and close.
- `USBCableSessionTests` run libdivecomputer's Cobalt driver through `DiveComputerSession.open` against
  `FakeCobalt`, an emulated computer built from `atomics_cobalt.c` that checks each control request. They cover
  the download and identity of both models, a dive that fills its last packet (so only the read's timeout ends
  it), a dive of exactly one 8 KiB read and one longer than a read, the fingerprint stop, a download recorded
  through the tap and replayed, the refusals and IOReturn mapping, no answer, a bad checksum, unplug, cancel,
  busy in discovery, and registry removal. All values are synthetic.
- `USBReplayTests` play hand-written Cobalt conversations (0x01, 0x09, 0x0A) through `ScriptedStream`, which fails
  on anything unexpected: two dives, an empty logbook, a dive ended by a timeout, dives spanning reads, a bad
  checksum, and a failed control transfer.
- `USBDiscoveryTests` cover which USB devices become endpoints, their order, busy, hot-plug, the layout table,
  and which models are beta.

### Recording a real computer

`USBHardwareTests` runs against a real Cobalt when `LIBDC_USB_MODEL` is set:

```sh
LIBDC_USB_MODEL="Atomic Aquatics Cobalt 2" swift test --filter USBHardwareTests
```

It finds the computer through `IOKitCableDiscovery`, downloads everything through a `DCStreamRecorder`, logs how
long it took and how many reads ended on the timeout, and scrubs the serial from the recording. The serial's
digits sit under additive checksums, so the stand-in keeps their sum. If the scrubbed copy replays to the same
dives, it writes the recording to `Tests/LibDCSwiftTests/Fixtures/Hardware/<family>_<model>_usb.dcrec`. Then it
downloads again and expects `.noNewDives`. With `LIBDC_USB_EXPECT_BUSY=1`, it expects the open to fail with
`busy` instead. Dive dates stay as the computer sent them, so commit a recording only for dives that are fine
to publish.
