# Serial cables on macOS

On macOS, LibDCSwift can download dive computers over USB-serial cables (FTDI, Silicon Labs CP210x, Prolific
PL2303, WCH CH34x and the like). The port is libdivecomputer's own serial driver (`dc_serial_open`), wrapped
in a `TapStream` for cancellation, packet logging and optional `.dcrec` recording. iOS builds contain none of
this: every type on this page is `#if os(macOS)`, and the C entry point is `TARGET_OS_OSX` only.

A sandboxed app needs the `com.apple.security.device.serial` entitlement to open a port. Finding ports needs
no entitlement.

Computers that are USB HID devices themselves (Suunto EON Steel family, Scubapro G2 family, Aladin Square) are
listed by the same discovery and opened by the same `open`; see `MACOS_USB_HID.md`. So is the Atomic Aquatics
Cobalt, which libdivecomputer reads over raw USB; see `MACOS_USB.md`.

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

- **USB serial ports.** A walk up the port's providers finds its USB device, and the VID, PID, serial number
  and product name are read from that device's own entry (`IORegistryEntryCreateCFProperty`, no search up the
  tree). A search would hand a chip with no serial number of its own (a CH340, many PL2303s) the serial of a
  hub or dock above it. The walk also decides whether a port is USB at all, because on Intel Macs the
  Bluetooth controller is itself a USB device.
- **Known cables with no port**, as `driverMissing`. This is the Oceanic/Pelagic cable (0403:F460) until FTDI's
  driver is installed.
- **Paired classic-Bluetooth ports**, as `.classicBTSerial`: the Shearwater Predator, Petrel, Petrel 2, Nerd
  and Perdix, over the `/dev/cu.*` port their Serial Port Profile pairing makes. Beta; see below.
- Built-in ports (`debug-console`) and macOS's own `Bluetooth-Incoming-Port` are left out.

An arrival is read again after a short settle (500 ms by default), because a USB device appears before its
serial port does. A cable that arrives after `start()` and still has no port is held back for `driverGrace`
(3 s by default) before it is listed as `driverMissing`, because a DriverKit serial driver can take that long
to publish its port. Cables already plugged in at `start()` are listed at once. A removal is read at once.

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

Which cables macOS drives itself was read from macOS 26.4's built-in driver personalities (AppleUSBFTDI,
AppleUSBSLCOM, AppleUSBPLCOM, AppleUSBCHCOM). Only 0403:F460 is missing there. Older macOS versions may lack
other PIDs, so every FTDI hint carries FTDI's driver page as a fallback `driverURL`.

## When a cable isn't listed, or has no port

- **Not listed at all.** On Apple silicon Mac laptops (macOS 13 and later), macOS asks "Allow accessory to
  connect?" the first time a USB accessory is plugged in. Until the user allows it, or if they decline, the cable never reaches the
  IORegistry, so there is nothing to list, not even a `driverMissing` endpoint. Tell the user to unplug and
  plug in again and allow it, or to change "Allow accessories to connect" in System Settings, Privacy &
  Security.
- **Listed as `driverMissing`.** `endpoint.driverMissingMessage` says what to do in English: install the chip
  maker's driver for a cable macOS has no driver for (with `hint.driverURL`), or replug, then install the
  driver, for one macOS should drive itself.
- **Listed as `busy`.** A session in this process has the port. Another app holding it is only found at open,
  as `CableError.busy`.

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

1. It refuses an endpoint that is neither `.serial` nor `.classicBTSerial`, a model with no descriptor for that
   transport, or a cable with no port (`unsupportedTransport`, `driverMissing`), all before the port is
   touched, since opening it raises DTR. It takes the session lease, or throws `sessionInProgress`.
2. A pre-flight `open(O_RDWR | O_NOCTTY | O_NONBLOCK)` plus `TIOCEXCL` captures errno. `dc_serial_open`
   reports busy and not-permitted the same way (`DC_STATUS_NOACCESS`); errno tells them apart, and a
   classic-Bluetooth port that is paired but not connected right now reports `ENOTCONN`
   (`CableError.bluetoothNotConnected`).
3. `open_serial_device` (LibDCBridge) resolves the descriptor before it touches the port, opens the port, hands
   it to the `TapStream`, and opens the device with one `dc_device_open` attempt. A serial computer that didn't
   answer once won't answer a retry on the same port. A paired classic-Bluetooth port opens exactly the same
   way: Shearwater's open (`shearwater_common_setup`) only configures the line, so it needs no handshake.

Cancelling the opening task, or calling `session.cancel()`, ends a blocked read, poll or sleep within 100 ms.
Writes can't be interrupted. A cancel that lands just as the open finishes closes the session and throws
`cancelled`, rather than returning a session whose port gives up on every read. With a started `discovery`,
pulling the cable cancels the session and sets `wasUnplugged`.

`session.close()` never waits on the computer's *reply*. An owned cable session cancels itself before
`dc_device_close`, so a driver's quit or exit command still goes out, but its acknowledgement isn't waited for.
Closing on the main thread after a failed download, as above, returns at once even when the computer has
stopped answering (Pelagic, OSTC 3 and Cressi closes would otherwise wait 1 to 9 s). The close-time *write*
itself has no such cancellation, though, and a stalled link (a classic-Bluetooth RFCOMM connection whose
computer went out of range, say) can block it indefinitely; close a cable session off the main thread.

The session's `storageKey` is the endpoint's `locatorKey`. It is never the computer's identity, which DEVINFO
gives during the download. Fingerprints are keyed by identity (see `DEVICE_IDENTITY.md`). For a computer that
reports no serial, the adapter's USB serial number stands in for the unit.

| `CableError` | From |
|---|---|
| `unsupportedTransport` | A model with no `.serial` or `.classicBTSerial` descriptor on this endpoint's transport |
| `driverMissing` | An endpoint with no port; see `endpoint.driverMissingMessage` |
| `bluetoothNotConnected` | ENOTCONN on a `.classicBTSerial` port: start Upload Log on the computer and keep it near the Mac |
| `permissionDenied` | EPERM, EACCES: usually a sandbox without `device.serial` |
| `busy` | EBUSY: another app (often the computer maker's) has the port |
| `notFound` | ENOENT, ENXIO, ENODEV: the cable came out before the open |
| `noResponse(family)` | `DC_STATUS_TIMEOUT` before any dive: the wrong model, not seated, or not in PC mode. `message` adds the family's `DeviceCatalog.cableConnectInstructions(for:)` |
| `unplugged` | The discovery saw the port go, or the link failed with the port gone |
| `protocolError(status)` | Anything else libdivecomputer reports once the port is open |

## Classic Bluetooth (Shearwater), Beta

Shearwater has no download cable. The Predator, Petrel, Petrel 2, Nerd and Perdix instead carry a classic
Bluetooth (not BLE) radio, which macOS's built-in `IOUserBluetoothSerialDriver` turns into a `/dev/cu.*`
Serial Port Profile port once the computer is paired in System Settings > Bluetooth. That port is
`DC_TRANSPORT_SERIAL` to libdivecomputer, so `DiveComputerSession.open` opens a `.classicBTSerial` endpoint
exactly as it opens a USB-serial one, through the same `open_serial_device` and `TapStream`.

Petrel 2 and Perdix also have BLE, which needs no pairing; `.classicBTSerial` matters mainly for the Predator,
Petrel and Nerd, which don't. No real computer has confirmed a download over this path yet, so every model
`DeviceCatalog.models(for: .classicBTSerial)` offers is `isBeta(on: .classicBTSerial)`
(`DeviceCatalog.betaFamilies[.classicBTSerial]`), and `CableEndpoint.isBeta` follows. Hosts should label them
"Beta".

A port that exists from an earlier pairing but whose computer isn't connected now (off, out of range, or not
in Upload Log) fails the pre-flight `open` with `ENOTCONN`, read as `CableError.bluetoothNotConnected`. That
errno mapping hasn't been confirmed against real hardware. A computer that is paired, in range and in Upload
Log but silent still reads as `noResponse`, as any serial computer does.

Every paired Serial Port Profile port is offered all 5 Shearwater models regardless of its name, so a
non-Shearwater SPP device (a GPS, a phone, an OBD adapter) also shows up here once it's paired. Narrowing
candidates by the port's own name is a follow-up, once HIL shows what Shearwater's ports are actually called.

## Fixtures

`.dcrec` files record what a driver did on the port. `DCStreamRecorder`'s scrubber rewrites serial numbers,
dates and positions before a recording is saved, and a recording never holds a port path or an adapter serial.
`Tests/LibDCSwiftTests/Fixtures/hw_ostc_mk2_synthetic.dcrec` is a classic OSTC download recorded over a pty
through `DiveComputerSession.open`, from an emulator built from `hw_ostc.c`. Its values are synthetic, and its
serial is scrubbed to a stand-in. Run the tests with `LIBDC_REGENERATE_DCREC=1` to record it again.
`shearwater_petrel_serial_synthetic.dcrec` is the same, over a `.classicBTSerial` endpoint, from an emulator
built from `shearwater_common.c`'s SLIP framing: RDBI DEVINFO, then a one-page manifest with no dive header,
so the walk ends with none. `ShearwaterSerialReplayTests` regenerates it the same way.

### Recording a real computer

`SerialHardwareTests` runs against a real computer when two variables are set:

```sh
LIBDC_SERIAL_PORT=/dev/cu.usbserial-XXXX LIBDC_SERIAL_MODEL="Heinrichs Weikamp OSTC Mk2" \
    swift test --filter SerialHardwareTests
```

It finds the port through `IOKitCableDiscovery` and prints the endpoint. It then opens it with
`DiveComputerSession.open`, downloads everything through a `DCStreamRecorder`, and prints the identity and the
newest dive's depth, time and date. Next it scrubs the computer's serial from the recording (32- and 16-bit,
both byte orders, and ASCII digits). It writes the recording only if the scrubbed copy replays to the same
dives under a stand-in serial. Last, it downloads again and expects `.noNewDives`. The recording goes to
`Tests/LibDCSwiftTests/Fixtures/Hardware/<family>_<model>.dcrec`, and
`SerialReplayTests.testCommittedHardwareRecordingsReplay` replays every recording there.

The scrubber only knows serial numbers. Dive dates, and positions on computers that log them, stay as the
computer sent them, so commit a recording only for dives that are fine to publish.
