# Changelog
All notable changes to LibDCSwift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- `RawDiveEvent` on `DiveProfilePoint.rawEvents`: every `DC_SAMPLE_EVENT` with its payload (`rawType`/`type`, `value`, `flags`, `phase` begin/end, `timeOffset`), including types `DiveEvent` has no case for
- `DecoKind` on `DiveProfilePoint.decoKind`: NDL, safety stop, deco stop or deep stop, from `DC_SAMPLE_DECO`
- `NauticAutoSync`: hands-off Suunto Nautic/Ocean download. Waits for the watch, downloads only dives whose logbook id isn't synced yet, listens for the watch's `/Logbook/UnsynchronisedLogs` and `/Sync/BusyState` pushes while connected, and reconnects under a `ReconnectPolicy` that mirrors the Suunto app (4 s retry, 20/96 attempt caps, 120 min cool-down, loop detection), resuming with the dives still missing (#45)
- `SuuntoNauticExplorer.subscribe`/`unsubscribe`/`waitForNotification` and `dc_device_t` overloads of `listDives`/`download`
- DC Tester: Auto download switch on the device list and the Nautic device screen, with a live log that can be shared or copied as plain text
- `SuuntoNauticExplorer.owningLogbookID(of:among:)`: which listed dive a download's bytes belong to, from the profile's GPS start time
- DC Tester: a by-id download whose bytes belong to another dive says so in the status and the Last Response header, which always name the id requested
- `DiveDataViewModel.lastDownloadInterruption`: set when a download delivered some dives and then failed, so the app can say "some dives couldn't be downloaded, reconnect and sync again"
- `NauticAutoSync.Configuration.connectTimeout` (25 s): a connect attempt that hasn't finished is cancelled (`NauticSyncConnector.cancelConnect()`), the `watchUnreachable` event fires with a "press a button on the watch" hint, and the sync falls back to scanning; DC Tester shows the hint in its status (#29)
- DC Tester: "Download all (ignore fingerprint)" switch next to Download Dives
- `NauticSyncLink.setCancellation(_:)`: blocking calls give up with `DC_STATUS_CANCELLED` while the check returns true; `NauticAutoSync` sets it so `stop()` interrupts a download
- Suunto Nautic/Ocean: the water type set on the watch (fresh, EN13319, salt) from the `/Summary`, as `DiveData.salinity` (#29)
- `suunto_nautic_device_handshake_acknowledged` / `SuuntoNauticExplorer.handshakeAcknowledged(device:)` and `DiveDataViewModel.lastHandshakeAcknowledged`: whether the watch answered the open's handshake. The open still succeeds without it, so a sleeping watch's first request times out; apps can say "press a button on the watch" (#29)
- DC Tester: the Explorer says when the watch hasn't answered since connecting, and keeps an exportable log of its connects, commands and results (Share / Copy / Clear) (#29)
- `SuuntoNauticExplorer.fetchPaged(device:path:)` (`suunto_nautic_device_fetch_paged`): every page of any paged resource, so `/Logbook/byId/<id>/Descriptors` comes through whole; DC Tester's Explorer uses it for Descriptors as well as `/Summary` (#72)
- `libdc_has_custom_baud()` (LibDCBridge): whether the serial driver was built with the non-standard baud rate path (`IOSSIOSPEED`). True on macOS, false on iOS
- `open_device_on_iostream` (LibDCBridge): opens a device on an iostream the caller already opened (a serial port, a custom stream) with a chosen number of `dc_device_open` attempts and wait between them. It takes ownership of the context and iostream on every path: on failure both are released and the `device_data_t` is zeroed. `open_ble_device` now opens through the same code with its existing 5 attempts 3 s apart (`LIBDC_BLE_OPEN_ATTEMPTS`, `LIBDC_BLE_OPEN_RETRY_MS`), still resolving the descriptor before it connects
- `find_descriptor_by_name_transport` (LibDCBridge): descriptor lookup by name for one transport. `DC_TRANSPORT_BLE` is exactly `find_descriptor_by_name`; serial, USB and USB HID match "Vendor Product" (first in table order), and classic Bluetooth and IrDA fall back to libdivecomputer's name filter
- `libdc_set_cancel` (LibDCBridge): installs or clears the cancel callback on an open `device_data_t`
- `libdc_cable_transports()` (LibDCBridge): the cable transports this platform can reach, `DC_TRANSPORT_SERIAL | DC_TRANSPORT_USBHID | DC_TRANSPORT_USB` on macOS and none on iOS (checked at compile time), because `dc_context_get_transports` always reports serial
- `DiveComputerSession`: an open dive computer on any transport. `open(iostream:context:family:model:...)` opens a device on an iostream the caller opened (owning both, as `open_device_on_iostream` does) and closes it in `close()`; `adopt`/`adoptBLE` wrap a device someone else opened. `cancel()` is sticky, and on non-BLE sessions it also fails the next transfer through `libdc_set_cancel`. `close()` during a download cancels it and closes when it ends
- `DiveComputerSessionLease`: one open `DiveComputerSession` at a time, BLE or cable; `open` and `adopt` throw `DiveComputerSessionError.busy` while another session holds it. It serializes sessions only: auto download's `NauticLinkLease` and legacy `openBLEDevice` connections don't take it. While it is held, `openBLEDevice` doesn't close the open device first, so a device an adopted session wraps isn't closed under it
- `DiveLogRetriever.retrieveDiveLogs(session:viewModel:syncClock:useFingerprint:onProgress:completion:)`: the download over a session, with a commit-acknowledge fingerprint contract. It completes with a `DiveDownloadResult` (`completed`, `noNewDives`, `cancelled`, `emptyRead`, `unreadableDives(n)`, `interrupted`, `failed`, plus dive and parse-failure counts) and saves no fingerprint itself: `fingerprintCommit` is offered only when the walk finished and every dive parsed, and the stored fingerprint moves only when the host calls `acknowledge()` on it. A cancel saves nothing and reports `.cancelled`. The view model the C fingerprint lookup reads is retained until the session closes. Dives from a driver that reports no fingerprint (Suunto Solution) are still downloaded and parsed, but no commit is offered, so every download fetches all of them again
- `FingerprintCommit.acknowledge()` saves on the main thread (at once when called there, else on the main queue's next turn). `DiveDownloadResult` and `FingerprintCommit` (with a `save` closure) have public initializers so hosts can build results in their own tests
- Session downloads date Reefnet Sensus, Sensus Pro and Sensus Ultra and Uwatec Memomouse dives from the `DC_EVENT_CLOCK` devtime/systime pair (`dc_parser_set_clock`); without it those parsers count device ticks from 1970
- Session downloads parse with the descriptor the session opened when the hardware reports a model no descriptor knows, and never store such a model (or an unreported model 0) in `DeviceStorage`, since the next open looks the stored model up
- `libdc_close_device_data` (LibDCBridge): releases everything a successful open left in a `device_data_t` and clears its fingerprint lookup (`fingerprint_context`, `lookup_fingerprint`)
- macOS: `DCCustomStream.open(backend:transport:context:)` opens a `dc_custom_open` iostream on a Swift `DCIOStreamBackend`, a protocol with all 15 iostream operations required. It always installs all 15 callbacks, because `custom.c` answers `DC_STATUS_SUCCESS` for a missing one without calling anything (a skipped DTR, RTS or sleep), and keeps the backend alive until `dc_iostream_close`. `DCUSBHIDStreamBackend` and `DCUSBStreamBackend` answer the operations `usbhid.c` and `usb.c` leave out exactly as upstream does (`SUCCESS`, lines and available 0, no sleep, `UNSUPPORTED` poll, and `UNSUPPORTED` ioctl on HID), so a backend implements only the transfers
- macOS: `TapStream` wraps an opened iostream (a `dc_serial_open` port, say) and forwards every operation. A blocked read, poll or sleep gives up with `DC_STATUS_CANCELLED` within 100 ms of its cancel check turning true (`isCancelled:` / `setCancellation(_:)`); reads poll in 50 ms slices and keep the inner stream's -1/0/N ms timeout rules and partial counts, and packet streams (BLE, USB HID) still get one report per read. Writes can't be interrupted. While `Logger.shouldShowRawData` is on, packets go to `Logger.onPacket` with a channel (`"serial"`, `"usbhid"`, or one you pass), and an optional `DCStreamRecorder` records every operation
- macOS: `DCRecording`, a recorded iostream conversation saved as a `.dcrec` file (JSON, one exchange per line). It holds no port path, adapter serial or wall-clock time, and `DCRecordScrubber` (`.replacing(_:)`, `then(_:)`, or your own) rewrites the device's serial, dates or positions in `DCStreamRecorder.recording()`, seeing each direction as one stream so a pattern split across reads is still caught
- macOS: `ScriptedStream` replays a `DCRecording` or hand-written exchanges to a driver, strictly: an unexpected configure, DTR, RTS, write or read size, or anything past the end, fails with `DC_STATUS_IO` and is kept in `deviation`. Replays don't wait, so a recorded download, unplug or timeout reruns in milliseconds
- `PacketEvent.channel`: the link a packet crossed, `PacketEvent.bleChannel` (`"ble"`) for every BLE packet, or a cable stream's channel. `characteristicUUID` is unchanged, and empty on cable channels
- Internal: a `DiveLogRetriever.retrieveDiveLogs(from:deviceName:deviceUUID:viewModel:isCancelled:markFinished:deviceStorage:...)` overload exercises the download/fingerprint pipeline without a live `CBPeripheral` or `DeviceStorage.shared`; the public `CBPeripheral` overload forwards to it unchanged
- Internal: `DeviceStorage` and `DeviceFingerprintStorage` take an injected `UserDefaults` suite (`init(userDefaults:)`, defaulting to `.standard`); `DeviceStorage` also takes an injected fingerprint store so `removeDevice`'s cleanup can be isolated (`init(userDefaults:fingerprints:)`)
- `DCTransport` (`ble`, `serial`, `usbHID`, `usb`, `classicBTSerial`), with stable raw values for storage and `dcValue`, the iostream transport a download opens with. A paired classic-Bluetooth port is a serial port. `CableSupport.transports` is `[.serial, .usbHID, .usb]` on macOS and empty on iOS
- `DeviceCatalog`: every libdivecomputer descriptor as a `DCModel` (vendor, product, family, model, transports, canonical name), read from the descriptor table at runtime. `models(for:)` gives 283 serial, 10 USB HID, 2 USB and 117 BLE models with the bundled libdivecomputer. Shearwater's 5 `SERIAL` descriptors are its paired Bluetooth SPP port, so they are `.classicBTSerial` and are never offered as a cable. `candidates(vid:pid:transport:)` narrows libdivecomputer's family-wide USB filter with an exact VID:PID table (EON Steel, EON Core, D5, EON Steel Black, G2 / G2 TEK, G2 Console, G2 HUD, Aladin Square)
- `DeviceCatalog.canonicalName(family:model:)`: the first `supportedModels` entry with that family and model, else the first descriptor in table order. Family and model don't name one product (G2 and G2 Console are both Uwatec Smart 0x32), and stored devices and existing fingerprints already carry `supportedModels` names
- `DiveComputerIdentity`: family, model, canonical name, serial, firmware and transport, read from DEVINFO. A serial of 0 is unknown. `deviceKey` is `"sn:<serial>"`, else `"md:<canonical name>"` lowercased, the same keys hosts dedupe dives on, on every transport. `storageKey(standIn:)` is the fingerprint key: family plus serial, else, with no serial, the model plus a stand-in for the unit (a cable adapter's USB serial, or the BLE peripheral's identifier); with neither there is no key, so nothing is stored and every download fetches every dive. `init?(device:transport:)` reads one from an open `device_data_t`
- `DiveComputerLocator` (`ble`, `serial`, `usbHID`, `usb`, `classicBTSerial`): where a computer was reached, kept as provenance (`locatorKey`), never as identity. `unitStandIn` is the stand-in for a computer that reports no serial
- `DiveComputerSession.identity` and `locator`, `DiveDownloadResult.identity` and `FingerprintCommit.identity`. `open` and `adopt` take a `locator`, and `adoptBLE` passes the peripheral's
- `StoredDevice.transport` (nil on older records, which read as BLE through `effectiveTransport`) and `locator`, the `DiveComputerLocator` it was last reached through (`locatorKey` is its string form), which `storeDevice` keeps unless it is given new ones. A locator this version can't read decodes as nil and keeps the record. `DeviceStorage.storedDevice(family:serial:)` finds the most recently connected record of one computer on any transport
- Fingerprints keyed by identity: `DeviceFingerprint.key`, and `DeviceFingerprintStorage.getFingerprint(for:standIn:)`, `saveFingerprint(_:for:standIn:)`, `clearFingerprint(for:standIn:)` and `seedFingerprint(identity:data:standIn:)`, also on `DiveDataViewModel`. Lookups fall back to a record saved by 1.18 with the same family and serial, so an unmigrated store never forces a full download. Saves keep the device type and serial a 1.18 reader looks up. `seedFingerprint` stores a fingerprint from a dive the host already has, so the first download on a new host stops there, and never replaces a stored one
- `DeviceFingerprintStorage.migrateLegacyKeys(storedDevices:)` / `DeviceStorage.migrateFingerprintKeys()`: give 1.18 records their identity key in place, leaving their device type, serial, fingerprint and timestamp unchanged. A record with serial 0 is keyed only when exactly one serial-0 BLE device of its family is stored. Idempotent. Details in `Docs/DEVICE_IDENTITY.md`
- macOS: serial cable downloads. `IOKitCableDiscovery` lists USB-serial ports from the IORegistry (`IOSerialBSDClient`, with the VID, PID, serial number and product name read from the USB device's own entry, so an adapter with no serial never takes its hub's) and follows hot-plug through an `IONotificationPort`, without opening any port. Built-in ports and the Bluetooth listening port are left out; paired classic-Bluetooth ports are listed as `.classicBTSerial`. A known cable with no port is listed as `driverMissing`, once a cable that arrived after `start()` has gone `driverGrace` (3 s) without one, and `CableEndpoint.driverMissingMessage` says which driver to install and where. `CableDiscovering.updates()` streams `[CableEndpoint]` (`ready`, `driverMissing`, or `busy` while a session in this process has the port), and `StaticCableDiscovery` serves endpoints you set. Both map a `RegistrySnapshot`, so the mapping runs on fixtures
- macOS: `CableHints`, the cable or chip a VID:PID is: Suunto (0403:F680), Cressi (0403:87D0) and Oceanic/Pelagic (0403:F460, which needs FTDI's driver) offer only their own families; FTDI FT-X/FT232R (OSTC first), CP210x, PL2303 and CH34x offer every serial model. Which cables macOS drives itself was read from macOS 26.4's driver personalities, and every FTDI hint carries FTDI's driver page as a fallback `driverURL`
- macOS: `DiveComputerSession.open(_:model:discovery:recorder:deviceStorage:lease:)` opens a serial endpoint through a `TapStream`, throwing `CableError`. A pre-flight `open` plus `TIOCEXCL` tells busy (EBUSY) from not permitted (EPERM, EACCES), which `dc_serial_open` reports alike. A model with no descriptor is refused as `unsupportedTransport` before the port is touched. Cancelling the task ends the open within 100 ms of a read or wait, including a cancel that lands as the open finishes. With a started discovery, pulling the cable cancels the session and sets `wasUnplugged`. `close()` on an owned cable session cancels it first, so a driver's quit command still goes out but close never waits on a computer that stopped answering. A cable session with no stored record stores the hardware's model under the family it opened, not one its name matches
- macOS: `open_serial_device` (LibDCBridge) resolves the descriptor, opens the port with `dc_serial_open`, hands it to a wrap callback (the tap), and opens the device with one attempt (`LIBDC_SERIAL_OPEN_ATTEMPTS`). It takes ownership of the context on every path
- macOS: `CableError` (`permissionDenied`, `busy`, `sessionInProgress`, `notFound`, `driverMissing`, `unplugged`, `noResponse(family)`, `cancelled`, `unsupportedTransport`, `portError`, `protocolError`), with `CableError(download:session:)` for a download that ended early and an English `message`. `noResponse`'s message adds `DeviceCatalog.cableConnectInstructions(for:)`, what to do on each family's computer before a cable download
- macOS: USB HID downloads. `HIDStream` is a `DCUSBHIDStreamBackend` on a computer's own `IOHIDDevice`, behind the `HIDDeviceIO` seam (`IOKitHIDDevice` is the live device), opened through `DCCustomStream` as `DC_TRANSPORT_USBHID` so the EON Steel and Uwatec Smart drivers take their USB HID paths. Each operation answers as `usbhid.c`'s hidapi build does: a read is one report with its report-ID byte as delivered, cut to the requested size, and a timeout is `SUCCESS` with 0 bytes; a write with report ID 0 sends the bytes after it, any other report ID is sent as the report's first byte, and `actual` is the whole size either way; `poll` and `ioctl` are `UNSUPPORTED`; at most 30 unread reports are kept. The lifecycle follows `IOHIDDevice.h`: the callbacks, dispatch queue and cancel handler are set before `IOHIDDeviceActivate`, and the cancel handler closes the device (unless it was unplugged) and only then releases it and the report buffer. No HID library is vendored and `HAVE_HIDAPI` stays undefined. Details in `Docs/MACOS_USB_HID.md`
- macOS: `IOKitCableDiscovery` lists USB HID dive computers (EON Steel, EON Core, D5, EON Steel Black, G2 / G2 TEK, G2 Console, G2 HUD, Aladin Square) before serial ports. They come from an `IOHIDManager` matching only vendor IDs 0x1493, 0x2e6c and 0xc251 (`HIDVendors.vendorIDs`), which is never opened, so listing never raises the Input Monitoring prompt. Other devices on those vendor IDs (Suunto watches, Keil debug probes), and keyboards and mice, are left out. New: `CableEndpoint.usbHIDDevice(registryID:vendorID:productID:serialNumber:productName:)`, `CableEndpoint.registryID` and `RegistrySnapshot.hidDevices`
- macOS: `DiveComputerSession.open(_:model:discovery:recorder:deviceStorage:lease:)` opens USB HID endpoints too, through a `TapStream`, seizing the device as hidapi does. A model the VID:PID can't be is refused before the device is touched; 2e6c:3201 opens as a G2 or a G2 TEK, and DEVINFO names the computer. `kIOReturnExclusiveAccess` is `CableError.busy`, `kIOReturnNotPermitted` is `permissionDenied`, a device gone before the open is `notFound`, and `CableError.usbError(ioReturn:)` is any other open failure. The device's own removal callback ends a download and sets `wasUnplugged`, with or without a discovery. Cancelling ends a blocked read within 100 ms. The `busy`, `permissionDenied` and `notFound` messages name the dive computer as well as the cable, and `cableConnectInstructions(for:)` has EON Steel and Uwatec Smart entries
- Tests: `HIDStreamTests` (the lifecycle, against a fake `IOHIDDevice` that fails on anything `IOHIDDevice.h` forbids, and the hidapi semantics), `HIDCableSessionTests` (libdivecomputer's EON Steel and Uwatec Smart drivers against emulated computers, with synthetic values), `HIDDiscoveryTests`, and the `HIDHardwareTests` harness, which runs against a real computer with `LIBDC_USBHID_MODEL` set
- macOS (Beta): raw USB downloads for the Atomic Aquatics Cobalt and Cobalt 2 (0471:0888), libdivecomputer's only `DC_TRANSPORT_USB` family. `USBStream` (LibDCBridge, `USBBridge.m`) is a `dc_custom_open` stream on IOUSBLib (`IOCreatePlugInInterfaceForService`, `IOUSBDeviceInterface500`, `IOUSBInterfaceInterface500` on interface 0) that answers every operation as `usb.c`'s libusb build does: bulk reads on 0x82 and writes on 0x02, the `DC_IOCTL_USB_CONTROL_READ`/`_WRITE` ioctl built from `dc_usb_control_t` (a `wLength` past the buffer is `INVALIDARGS`), `set_timeout` 0 `UNSUPPORTED`, and a timed-out read returning `TIMEOUT` with the bytes that came before it, which `atomics_cobalt.c` relies on. Reads go one max-size packet at a time, because a timed-out `ReadPipeTO` reports no count. A cancel aborts a blocked transfer within 50 ms. `HAVE_LIBUSB` stays undefined and no USB library is bundled. Details in `Docs/MACOS_USB.md`
- macOS: `IOKitCableDiscovery` lists raw USB computers (`transport == .usb`, `id` `usbdevice:<registry id>`) after USB HID computers, from `RegistrySnapshot.usbComputers`, and follows them through vendor ID 0x0471. New: `CableEndpoint.usbDevice(registryID:vendorID:productID:serialNumber:productName:)`, `USBComputers` and `USBInterfaceLayout` (`usb.c`'s `g_usb_config`), and the `USBDeviceIO` seam with `IOKitUSBDevice` as the live device
- macOS: `DiveComputerSession.open(_:model:discovery:recorder:deviceStorage:lease:)` opens raw USB endpoints too, through a `TapStream` (channel `"usb"`). `kIOReturnExclusiveAccess` is `CableError.busy`, `kIOReturnNotPermitted` is `permissionDenied`, a device gone before the open is `notFound`, any other open failure is `usbError(ioReturn:)`, and a transfer that finds the device gone marks the session unplugged, with or without a discovery
- macOS: Beta labels. `DeviceCatalog.betaFamilies`, `DCModel.isBeta(on:)` and `CableEndpoint.isBeta` say which models no real computer has confirmed yet on a transport: the Cobalt and Cobalt 2 on `.usb`. Hosts show them as Beta
- Tests: `USBStreamTests` (`usb.c`'s operation table, the control setup's layout and `wLength` bounds, packet-by-packet reads, timeouts with partial counts, cancel and removal, against a fake interface with USB's bulk rules), `USBCableSessionTests` (libdivecomputer's Cobalt driver against an emulated Cobalt), `USBReplayTests` (hand-written Cobalt conversations through `ScriptedStream`), `USBDiscoveryTests`, and the `USBHardwareTests` harness, which runs against a real computer with `LIBDC_USB_MODEL` set
- Tests: discovery mapping on registry fixtures and over a fake hot-plug source, cable sessions over a pseudo-terminal through `dc_serial_open` (line settings, timeouts, cancel, unplug, refusals), and a classic OSTC download, from an emulator built from libdivecomputer's protocol code, recorded over a pty and replayed through `ScriptedStream` (`hw_ostc_mk2_synthetic.dcrec`, synthetic values with the serial scrubbed). `SerialHardwareTests`, run with `LIBDC_SERIAL_PORT` and `LIBDC_SERIAL_MODEL`, downloads a real computer twice and records a serial-scrubbed `.dcrec` into `Fixtures/Hardware`, which `SerialReplayTests` replays. Details in `Docs/MACOS_SERIAL_CABLES.md`
- Golden/characterization tests for the Suunto Nautic/Ocean parser pipeline (per-field aggregates, the full event list, deco-change points and a full-stream hash, not just a coarse summary), storage-key, BLE-name-pattern, and end-to-end retrieval tests against a fake watch, and a GitHub Actions workflow (macOS `swift test`, generic iOS/macOS `xcodebuild`, an iOS Simulator `xcodebuild test`, an iOS no-IOKit-symbols check on `LibDCBridge`, and the DC Tester app build)
- macOS (Beta): classic-Bluetooth downloads for the Shearwater Predator, Petrel, Petrel 2, Nerd and Perdix, over the paired `/dev/cu.*` Serial Port Profile port the L7 serial discovery already lists as `.classicBTSerial`. `DiveComputerSession.open` opens it through `open_serial_device` exactly as a USB-serial endpoint, since it is `DC_TRANSPORT_SERIAL` too; Shearwater's own open (`shearwater_common_setup`) only configures the line, so no handshake is needed to open. `DeviceCatalog.betaFamilies` adds `.classicBTSerial: [.shearwaterPetrel, .shearwaterPredator]`, so every model it offers is Beta. `cableConnectInstructions(for:)` gives these two families Bluetooth-specific wording instead of "attach the cable", since they have none. Details in `Docs/MACOS_SERIAL_CABLES.md`
- macOS: `CableError.notPaired`, from `ENOTCONN` on the pre-flight `open`: a `.classicBTSerial` port left over from an earlier pairing, but the computer isn't connected over Bluetooth now. `message` points at System Settings > Bluetooth
- Tests: a `.classicBTSerial` open over a pseudo-terminal standing in for the paired port (line settings, locator, storage key), `unsupportedTransport` for a model with no `.classicBTSerial` descriptor, `CableError`'s `ENOTCONN` mapping and message, and the catalog's new beta and connect-instructions entries

### Changed
- macOS: a session download keeps an Atomic Aquatics Cobalt's reported model 0 (the Cobalt 1) as its identity and stored model, instead of treating 0 as unreported
- Tests: the committed hardware recordings replay on whichever cable transport they were recorded on, not only serial
- `DeviceConfiguration.DeviceFamily` has a case for every libdivecomputer family (47; it had the 17 BLE ones). The existing cases and their raw values are unchanged
- Session downloads look up and commit fingerprints by `DiveComputerIdentity`: the C lookup's context is the session, and it keys on DEVINFO instead of the descriptor's name. A commit's `deviceType` is the canonical name, so a G2 Console's is "Scubapro G2". A computer that reports serial 0 gets a commit only when its locator has a stand-in, and serial 0 is never stored as a stored device's serial. A stored device a session download creates or updates gets the session's transport and locator. The `CBPeripheral` download still keys by `(deviceType, serial)`, unchanged
- Session downloads give Zeagle N2iTiON3 (and its rebadges) and Citizen Hyper Aqualand, whose drivers never send DEVINFO, the opened descriptor's identity with no serial, so `DiveDownloadResult.identity` and `deviceKey` exist. With a stand-in, the stored fingerprint is set on the device before the walk and the commit is keyed by the stand-in; without one, every download is full
- `DeviceStorage.removeDevice(uuid:)` also clears the device's identity-keyed fingerprint, including a serial-0 cable computer's, keyed by its locator's stand-in
- `StoredDevice.swift` no longer imports CoreBluetooth
- The `CBPeripheral` `retrieveDiveLogs` overload keeps its legacy contract unchanged (it saves the fingerprint itself when the walk completes, even past a dive that failed to parse, and a between-dive cancel reads as a short download) and now runs on the same download core as session downloads
- `device_data_t.have_clock`/`clock` are filled from `DC_EVENT_CLOCK`, which was subscribed but dropped
- `NauticLinkLease` is built on `DiveComputerSessionLease`; its behaviour and its own shared instance are unchanged
- macOS: libdivecomputer builds with `HAVE_IOKIT_SERIAL_IOSS_H` and `HAVE_CLOCK_GETTIME`. Serial rates with no `Bxxx` constant (Sporasub SP2 at 460800, Cochran EMC at 850000) are set with `IOSSIOSPEED` instead of failing with `DC_STATUS_UNSUPPORTED`, `DC_IOCTL_SERIAL_SET_LATENCY` sets the receive latency with `IOSSDATALAT`, and serial timeouts use the monotonic clock. iOS builds are unchanged. Details in `Docs/MACOS_BUILD_DEFINES.md`
- Suunto Nautic/Ocean: every packet from the watch goes through one receive path that checks its start byte, length and CRC and matches it to its request by sequence number, following Jef Driesen's review of libdivecomputer#73. Replies to the Suunto app's requests on the same link are skipped instead of being read as ours, which made a sync with the Suunto app still connected time out. The `/Data` stream ends on the watch's end marker with each chunk's offset checked, and `/Logbook/Entries` is parsed by its records
- GenericParser closes a profile point when the next `DC_SAMPLE_TIME` arrives (or parsing ends), so depth, events and deco land on the sample they were reported in instead of the following timestamp
- Repeated `DC_SAMPLE_TIME` callbacks with the same time continue one sample instead of adding duplicate points
- Events no longer append an extra profile point; they attach to their sample
- Deco fields are only set on samples where the computer reported `DC_SAMPLE_DECO`; safety and deep stops now fill `decoStop`/`decoTime`
- `SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY` and `SAMPLE_EVENT_GASCHANGE2` map to their `DiveEvent` cases

### Removed
- `configuredc.h`: four prototypes that had no implementation (`get_alternative_models_for_name`, `event_cb`, `reopen_ble_device_with_model`, `get_device_data_pointer`); calling any of them already failed to link

### Fixed
- `retrieveDiveLogs` appends each dive to `viewModel.dives` in that dive's own main-queue turn, so every dive is there when `completion` runs. The last dive used to land a turn after `completion` (and after `.completed`), so a host reading `dives` in `completion` missed the oldest new dive. A session download also numbers the dives, oldest first, before `completion`
- `DiveDataViewModel.updateProgress(count:)` no longer moves a finished download, or a `.cancelled` or `.failed` a host set, back to `.inProgress`. After a fast walk, a dive count could land after `.completed` or `.noNewDives` and leave the download looking unfinished
- A download's own progress reset lands in one main-queue turn, ahead of anything that download reports. It took two, so it usually cleared `lastHandshakeAcknowledged` just after the download set it, and a host could still see the previous download's end state when `completion` ran
- `DeviceFingerprintStorage` serializes its changes, so two at once (a launch-time `migrateLegacyKeys` and a commit, say) can no longer write back a list missing the other's
- `DeviceStorage` decodes stored devices one at a time, so a record this version can't read (a family or transport from a newer version, say) is dropped on its own instead of emptying the whole list
- `DeviceStorage.reconcileUUID(name:newUUID:)` moves BLE records only, so a BLE scan can no longer re-key a cable record of the same name to a peripheral UUID
- `find_descriptor_by_name` returns `DC_STATUS_INVALIDARGS` for a NULL name or output pointer instead of crashing
- `DiveLogRetriever.retrieveDiveLogs` sets `CoreBluetoothManager.isRetrievingLogs` when it starts and clears it before calling `completion`, so callers no longer have to. A caller that didn't set it (DC Tester's Explorer "Download dives (all)") had its download cancelled on the first dive and got 0 dives. A cancel issued right after the call still wins (#79)
- `openBLEDevice` closes a device that's already open and waits for its link to drop before opening another, unless an auto download session holds the link. Opening a second watch on top of the first used to run the handshake on the first watch's link, so the open succeeded and the next request timed out (-7) until the old link dropped about 80 s later. `connect(toDevice:)` also clears the previous link's ready flag and characteristics before connecting (#75)
- DC Tester: the Explorer opens only after the new watch's open succeeds (it used to open straight away on the previous watch's device), names the selected watch on its connect line and on every command and result, and logs connect failures (#75)
- Suunto Nautic/Ocean: a second dive downloaded on the same link (by id, or the 2nd+ dive of a `dc_device_foreach`) can no longer stream the first dive's profile. The `/Data` stream is subscribed on the handle its GET returned, not a fixed one, and per-id handles are released after use (#29)
- Suunto Nautic/Ocean: `dc_device_foreach` no longer skips a dive whose download fails (a dropped link, an empty read of a listed dive) and reports success. It stops at that dive with the error, having delivered only the newer dives, so the stored fingerprint can't move past dives that were never fetched. Entries listed with no data are still skipped
- `retrieveDiveLogs` never reads a Suunto Nautic/Ocean `PROTOCOL` failure as "no new dives"
- Suunto Nautic/Ocean: dives over ~1.14 MB compressed are no longer cut short at 4096 stream frames, losing the ascent and safety stop (#60)
- Suunto Nautic/Ocean: each dive stream is closed with `STREAM_STOP`, and a GET's reply must echo its message id, so a leftover stream chunk can't make the `/Summary` fetch 404 (#59)
- Suunto Nautic/Ocean: `/Summary` pages drop their 11-byte header and CRC, so no bytes are lost at page boundaries (#57)
- Suunto Nautic/Ocean: every `/Logbook/Entries` page is listed (`StartAfterId`), so the newest dives on page 2+ are downloaded (#61)
- Suunto Nautic/Ocean: downloads are checked against the size the watch lists; `SuuntoNauticExplorer.download` throws `incompleteDownload` on a mismatch (#58)
- Dive time comes from the computer's `DC_FIELD_DIVETIME` instead of the last sample time, which counted post-dive surface logging (a Suunto Ocean dive timed at 1922 s by the watch came out as 37 min); falls back to the sample span when the field is missing or runs more than 60 s past the samples
- Average depth comes from `DC_FIELD_AVGDEPTH` when plausible, else the sampled mean clipped to the dive time
- Suunto Nautic/Ocean: the sync trigger subscription comes back after an automatic reconnect that followed a drop mid-download. Message ids now carry on from the previous connection instead of restarting at 1 (the watch can keep a dropped link's session and leave a repeated request unanswered); an unanswered subscription is retried 3 times 2 s apart and again later instead of being given up for the session; unsubscribing releases a per-id handle, and a 00 slot left bound by a dropped link is released when a GET lands on the 10 slot (#29)
- Suunto Nautic/Ocean: dive time is truncated like the Suunto app's (4680.5 s is 78:00, not 78:01), and dive time and max depth come from the watch's own values in the `/Summary` when they agree with the profile; max depth was the deepest logged sample, 0.2-0.3 m shallower than the app (#29)
- `retrieveDiveLogs(useFingerprint: false)` clears a fingerprint an earlier download on the same connection set
- Suunto Nautic/Ocean: on a reconnect a few seconds after a drop, opening the device waits for the watch's handshake reply, skipping the tail of the interrupted stream, before sending anything. The first request used to go out while the watch was still flushing that stream, and the Ocean left it unanswered about two times in three (#29, #45)
- Suunto Nautic/Ocean: helium is read from the gas record as an int16 at +3; it was read from O2's high byte, so every gas had 0 % helium and trimix decoded as nitrox (#29)
- Suunto Nautic/Ocean: average depth and the water temperature range are the watch's own, as the Suunto app shows them, when the `/Summary` agrees with the profile (#29)
- Suunto Nautic/Ocean auto download: switching from one watch to another no longer crashes. Every connector opens through the one shared `CoreBluetoothManager`, and the new watch's session could open its device while the old session was still unsubscribing and closing it. Sessions now take turns (`NauticLinkLease`), a stopped session cancels its in-flight download between stream frames instead of finishing it, and a closing link never closes another session's device (#29, #45)
- Suunto Nautic/Ocean auto download: turning it off and straight back on (same watch or another) no longer crashes. DC Tester's switch closed the shared device as a leftover manual session while the stopped session was still unsubscribing on it; it now leaves a device whose session holds the lease alone. A closing link also keeps the lease until its watch has actually disconnected, so a new session can't open into the old link's delayed cancel, and a late disconnect from one watch no longer resets the manager's state for another (#29)
- Suunto Nautic/Ocean: the water temperature range comes from the `/Summary` Windows records, which every watch writes in schema order, instead of the dive record's pair that Ocean firmware writes reversed; the dive record is the fallback (#29)
- Suunto Nautic/Ocean: a dive's Descriptors schema is no longer truncated at 64 pages
- Suunto Nautic/Ocean: when the Ocean stores the water temperature pair reversed, it is ordered instead of falling back to the sampled range
- Suunto Nautic/Ocean: tank end pressure is the watch's own at the end of the dive. It was the last reading, which after a dive with the valve shut and the regulator purged on the surface came out at 0.9 bar instead of 121.5 (#52)
- DC Tester: Download Dives says "No new dives since the last download" instead of "Downloaded 0 dive(s)" when the fingerprint stops it
- DC Tester: a failed download suggests reconnecting first and only calls a dive gone when `/Logbook/Entries` no longer lists it; Capture raw on a `/Summary` path fetches every page (#56)

## [1.7.0] - 2026-07-14
### Changed
- Synced vendored libdivecomputer to upstream HEAD (`8e564eb`, `v0.9.0-74-g8e564eb`):
  - Full Shearwater Perdix 3 descriptor support (`b924092`) — closes out the discovery-only registration added in 1.6.0, so Perdix 3 devices can now actually be opened and downloaded from, not just identified over BLE
  - `dc_device_open` now passes the model number through to `shearwater_petrel_device_open`, needed to distinguish Perdix 3 behavior from earlier Petrel-family devices
  - Wider Shearwater BLE support: variable-sized packet handling, updated min/max BLE packet size limits, and the model number read directly from the device instead of inferred from the hardware descriptor
- Removed a stale duplicate `include/libdivecomputer/halcyon_symbios.h` public header left over from an earlier partial vendor of that driver; the canonical header has lived alongside the rest of the driver in `src/` since 1.6.0, this just removes the unused leftover copy

## [1.6.0] - 2026-07-11
### Added
- Seac Tablet and Halcyon Symbios HUD/Handset device support (DeviceFamily + ComputerModel entries; BLE service UUIDs were registered previously but the family/model plumbing was missing so the devices couldn't be identified or opened)
- Oceanic/Aqualung/Sherwood BLE name-based model identification (decodes the two-character model prefix from the advertised serial name, e.g. `"FH020399"`)
- Shearwater Perdix 3 UUID/ComputerModel registration for discovery (device open still pending a libdivecomputer descriptor sync)
- Opt-in device clock sync (`syncClock` parameter on `retrieveDiveLogs`) via `dc_device_timesync`, called after a successful download or a fingerprint-match check-in
- GenericParser: gas-change event synthesis from `DC_SAMPLE_GASMIX` (skips `DC_GASMIX_UNKNOWN`), salinity density precision from `dc_salinity_t.density`, `SAMPLE_EVENT_PO2` mapped to `.po2`

### Fixed
- Fingerprint buffer allocated with `malloc()` instead of Swift's allocator, fixing a crash when the C side `free()`'d it
- Download progress polling switched from `Timer.scheduledTimer` (never fires without an active RunLoop on a GCD queue) to `DispatchSourceTimer`
- `didDiscoverServices` now resets stale write/notify characteristics unconditionally, so a reconnect that finds no known service can't leave characteristics from a dead peripheral in place
- Auto-reconnect now waits 500ms before reopening the BLE link and sets `isConnecting` immediately, closing a race window with sleepy devices (e.g. Aqualung i300C) and duplicate disconnect callbacks

### Changed
- Synced libdivecomputer's `hw_ostc3` driver to upstream HEAD, which folds OSTC Frog support into the ostc3 backend (removes the standalone `hw_frog.c`/`hw_frog.h`)

### Notes
- Device support and bug fixes in this release were reported and traced against a production fork by @houle988 (issue #19) — thanks for the detailed writeup and for contributing back!

## [1.5.0] - 2026-07-03
### Added
- Cressi BLE support (characteristic read ioctl, vendor service preference, synchronous characteristic reads)
- Halcyon Symbios and Seac serial service registration
- `onLog` sink (`LogEvent`) so host apps can forward library diagnostics
- Selectable computer model IDs
- Peripheral-ready state exposed to callers

### Fixed
- Auto-reconnect no longer blocks the main thread (`openBLEDevice` was hanging the UI for 2+ seconds)
- BLE I/O robustness for uwatec_smart/Scubapro Aladin downloads (per-characteristic write type, working read-timeout wiring, write flow-control)
- Double-free in `ble_stream_close` (#17)
- Time-weighted average depth calculation
- Shearwater Peregrine tx import, device fingerprint, and GPS handling
- Fingerprint handling across device models

### Changed
- Synced libdivecomputer to upstream HEAD: adopted `DC_SAMPLE_LOCATION` (replaces `DC_FIELD_LOCATION`) for multi-point GPS during a dive; picked up descriptor/parser updates for mares_iconhd, halcyon_symbios, hw_ostc, seac, suunto, divesoft, deepsix, usb/usbhid
- Shearwater model detection now reads via `ID_MODEL` with GNSS-status GPS detection

## [1.4.1] - 2025-12-08
### Added
- Shearwater Avelo support (log parsing and device handling)
- Shearwater Peregrine support
- Seac Screen support

### Fixed
- `platform.h` unused macro definition for compatibility across toolchains

## [1.4.0] - 2025-05-08
### Added
- Halcyon Symbios: full support for downloading dive logs
- Cressi Archimede: protocol support for dive log retrieval
- Mares Sirius (new firmware/version): compatibility updates
- Mares Puck Lite: support for downloading dives
- BLE filter scan operation (thanks to @jtreml)

### Notes
- Release tag: `v1.4.0` (commit `af7ddb6`)
- Released by @latishab

## [1.3.0] - 2025-01-05
### Changed
- Improved device name normalization using libdivecomputer's descriptor system
- Removed manual device name parsing in favor of libdivecomputer's built-in filters

## [1.2.1] - 2025-01-04
### Changed
- Fixed type-casting in BLEManager

## [1.2.0] - 2025-01-04
### Changed
- Removed bridging header (as it is not supported in SPM) due to conflicts with client code using the package

## [1.1.0] - 2025-01-03
### Added
- Active download state preservation during background operations
- Improved UI state restoration when returning to device view
- Enhanced download progress tracking

## [1.0.0] - 2025-01-03
### Added
- Initial release of LibDCSwift
- Core BLE functionality in BLEManager.swift
- Dive computer communication bridge (LibDCBridge)
- Integration with libdivecomputer (Clibdivecomputer)
- Basic dive log retrieval functionality
- Models for device configuration and dive data
- Generic parser for dive computer data
- Logging system

### Components
#### LibDCSwift
- Logger implementation
- BLE management system
- Device configuration handling
- Dive data models
- Stored device management
- Sample data processing
- Dive data view model
- Generic parser implementation
- Dive log retrieval system

#### LibDCBridge
- C bridge implementation (configuredc.c)
- BLE bridge implementation (BLEBridge.m)
- Objective-C bridging header

#### Clibdivecomputer
- Core libdivecomputer integration
- Custom header configurations
- Source implementations

### Dependencies
- iOS 15.0+
- macOS 12.0+
- Swift 5.10

[1.1.0]: https://github.com/latishab/LibDCSwift/releases/tag/1.1.0
[1.0.0]: https://github.com/latishab/LibDCSwift/releases/tag/1.0.0
[1.2.0]: https://github.com/latishab/LibDCSwift/releases/tag/1.2.0
[1.2.1]: https://github.com/latishab/LibDCSwift/releases/tag/1.2.1
[1.3.0]: https://github.com/latishab/LibDCSwift/releases/tag/1.3.0
[1.4.0]: https://github.com/latishab/LibDCSwift/releases/tag/1.4.0
[1.4.1]: https://github.com/latishab/LibDCSwift/releases/tag/1.4.1
