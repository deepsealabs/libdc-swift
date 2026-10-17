# Serial cables on macOS

On macOS, LibDCSwift can download dive computers over USB-serial cables (FTDI, Silicon Labs CP210x, Prolific
PL2303, WCH CH34x and the like). The port is libdivecomputer's own serial driver (`dc_serial_open`), wrapped
in a `TapStream` for cancellation, packet logging and optional `.dcrec` recording. iOS builds contain none of
this: every type on this page is `#if os(macOS)`, and the C entry point is `TARGET_OS_OSX` only.

A sandboxed app needs the `com.apple.security.device.serial` entitlement to open a port. Finding ports needs
no entitlement.

## Finding cables

`IOKitCableDiscovery` lists ports from the IORegistry (`IOSerialBSDClient` services) and follows hot-plug
through an `IONotificationPort`. It never opens a port, so listing cables never toggles DTR on a device that
resets when it does (an Arduino, say).

```swift
let discovery = IOKitCableDiscovery()
discovery.start()                        // reads the registry before it returns
for await endpoints in discovery.updates() {
    // [CableEndpoint], known cables first
}
```

Each `CableEndpoint` has a callout path, the adapter's USB VID, PID, serial number and product name, a
`CableHint`, the models to offer (`candidates`) and a `status`:

| Status | Meaning |
|---|---|
| `ready` | The port can be opened. |
| `driverMissing` | A known cable is plugged in, but macOS made no port for it, so `calloutPath` is nil. `hint.driverURL` says where the chip maker's driver is. |
| `busy` | A `DiveComputerSession` in this process has the port open. |

What is listed:

- **USB serial ports.** VID, PID and strings come from the port's USB parent, read with
  `IORegistryEntrySearchCFProperty` (recursively, through parents). The parent walk decides whether a port is
  USB at all, because on Intel Macs the Bluetooth controller is itself a USB device.
- **Known cables with no port**, as `driverMissing`. This is the Oceanic/Pelagic cable (0403:F460) until FTDI's
  driver is installed.
- **Paired classic-Bluetooth ports**, as `.classicBTSerial`. They are listed but can't be opened yet.
- Built-in ports (`debug-console`) and macOS's own `Bluetooth-Incoming-Port` are left out.

An arrival is read again after a short settle (500 ms by default), because a USB device appears before its
serial port does; reading at once would show the cable as `driverMissing` for a moment. A removal is read at
once.

`StaticCableDiscovery` takes endpoints you set, for tests and previews. Both discoveries map a
`RegistrySnapshot`, so the mapping can be tested on fixtures.

## Cable hints

| VID:PID | Hint | Models offered |
|---|---|---|
| 0403:F680 | Suunto USB cable | Suunto serial families only |
| 0403:87D0 | Cressi USB cable | Cressi Leonardo, Goa and Edy families only |
| 0403:F460 | Oceanic/Pelagic USB cable (needs FTDI's driver) | Oceanic Atom 2, Veo 250 and VT Pro families only |
| 0403:6015, 0403:6001 | FTDI FT-X, FT232R | every serial model, OSTC first |
| 10C4:EA60, 10C4:EA70 | Silicon Labs CP210x, CP2105 | every serial model |
| 067B:2303, 067B:2304 | Prolific PL2303 | every serial model |
| 1A86:7523, 1A86:55D4 | WCH CH340, CH9102 | every serial model |

Any other USB serial port is listed with no hint, offering every serial model. Serial descriptors carry no
USB filter, so the flow is model first: the user picks the model.

## Opening and downloading

```swift
let session = try await DiveComputerSession.open(endpoint, model: model, discovery: discovery)
DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result in
    if let error = CableError(download: result, session: session) { /* show error.message */ }
    result.fingerprintCommit?.acknowledge()   // once the host has stored the dives
    session.close()
}
```

`open` runs on its own queue and does this:

1. It refuses a non-serial endpoint or model (`unsupportedTransport`) and a cable with no port (`driverMissing`).
   It takes the session lease, or throws `sessionInProgress`.
2. A pre-flight `open(O_RDWR | O_NOCTTY | O_NONBLOCK)` plus `TIOCEXCL` captures errno. `dc_serial_open`
   reports busy and not-permitted the same way (`DC_STATUS_NOACCESS`); errno tells them apart.
3. `open_serial_device` (LibDCBridge) resolves the descriptor before it touches the port, opens the port, hands
   it to the `TapStream`, and opens the device with one `dc_device_open` attempt. A serial computer that didn't
   answer once won't answer a retry on the same port.

Cancelling the opening task, or calling `session.cancel()`, ends a blocked read, poll or sleep within 100 ms.
Writes can't be interrupted. With a started `discovery`, pulling the cable cancels the session and sets `wasUnplugged`.

The session's `storageKey` is the endpoint's `locatorKey`. It is never the computer's identity, which DEVINFO
gives during the download. Fingerprints are keyed by identity (see `DEVICE_IDENTITY.md`). For a computer that
reports no serial, the adapter's USB serial number stands in for the unit.

| `CableError` | From |
|---|---|
| `permissionDenied` | EPERM, EACCES: usually a sandbox without `device.serial` |
| `busy` | EBUSY: another app (often the computer maker's) has the port |
| `notFound` | ENOENT, ENXIO, ENODEV: the cable came out before the open |
| `noResponse(family)` | `DC_STATUS_TIMEOUT` before any dive: the wrong model, not seated, or not in PC mode. `message` adds the family's `DeviceCatalog.cableConnectInstructions(for:)` |
| `unplugged` | The discovery saw the port go, or the link failed with the port gone |
| `protocolError(status)` | Anything else libdivecomputer reports once the port is open |

## Fixtures

`.dcrec` files record what a driver did on the port. `DCStreamRecorder`'s scrubber rewrites serial numbers,
dates and positions before a recording is saved, and a recording never holds a port path or an adapter serial.
`Tests/LibDCSwiftTests/Fixtures/hw_ostc_mk2_synthetic.dcrec` is a classic OSTC download recorded over a pty
through `DiveComputerSession.open`, from an emulator built from `hw_ostc.c`. Its values are synthetic, and its
serial is scrubbed to a stand-in. Run the tests with `LIBDC_REGENERATE_DCREC=1` to record it again.
