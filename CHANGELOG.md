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

### Changed
- GenericParser closes a profile point when the next `DC_SAMPLE_TIME` arrives (or parsing ends), so depth, events and deco land on the sample they were reported in instead of the following timestamp
- Repeated `DC_SAMPLE_TIME` callbacks with the same time continue one sample instead of adding duplicate points
- Events no longer append an extra profile point; they attach to their sample
- Deco fields are only set on samples where the computer reported `DC_SAMPLE_DECO`; safety and deep stops now fill `decoStop`/`decoTime`
- `SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY` and `SAMPLE_EVENT_GASCHANGE2` map to their `DiveEvent` cases

### Fixed
- Aqualung i470TC is in `supportedModels`, so it can be picked for a sync
- Oceanic/Aqualung/Sherwood BLE names resolve against libdivecomputer's descriptor table instead of `supportedModels`. An i470TC ("GC004024") used to resolve to the Oceanic Pro Plus X, and BLE models missing from the catalog didn't resolve at all
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

## [1.17.9] - 2026-10-17
### Added
- `CoreBluetoothManager.isIOCancelled()`: true while a close waits for a download to stop; the BLE iostream then answers `DC_STATUS_CANCELLED`

### Fixed
- `close(clearDevicePtr: true)` no longer frees a device `DiveLogRetriever.retrieveDiveLogs` is still downloading from. It used to close and deallocate the device while `dc_device_foreach` was still running on it, so the download's next read used freed memory and crashed (`EXC_BAD_ACCESS` in `dc_iostream_read`, seen on Suunto Nautic/Ocean right after the driver logged "Retrying the stream"). The close now cancels the download (BLE reads, writes and sleeps answer `DC_STATUS_CANCELLED`, and the device's cancel check is set) and runs, once, when `dc_device_foreach` has returned and before the retrieval's completion. That completion reports failure with the usual interrupted/incomplete status, and the fingerprint is not advanced. `openBLEDevice` waits for a close held back this way before opening another device (capped like its wait for the disconnect)
- `DeviceConfiguration.fetchDeviceInfo` is held back the same way: a close during its `dc_device_foreach` cancels it and runs once it has returned, and the completion reports `false`
- A close that cancels a download also wakes a BLE write waiting for a with-response confirmation or for the peripheral to accept a no-response write, and no further chunks of a split write go out, so the held-back close isn't kept waiting for the write timeout. A close still held back after 10 s is logged
- A download the app stops by clearing `isRetrievingLogs` no longer counts as complete. Drivers generally report a callback stop as success (the Suunto Nautic driver does), so the retrieval used to save the newest delivered dive as the fingerprint, and the next sync stopped there and never fetched the older dives the stop had left on the device. It now reports `completion(false)` with `progress` `.cancelled` and `lastDownloadStatus` `"CANCELLED"`, and keeps the fingerprint. As before, `isRetrievingLogs` has to be `true` while `retrieveDiveLogs` runs
- DC Tester: Download Dives sets `isRetrievingLogs` for the download, so it downloads the dives instead of stopping at the first one without delivering it

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
