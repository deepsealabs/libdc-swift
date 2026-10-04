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

### Changed
- GenericParser closes a profile point when the next `DC_SAMPLE_TIME` arrives (or parsing ends), so depth, events and deco land on the sample they were reported in instead of the following timestamp
- Repeated `DC_SAMPLE_TIME` callbacks with the same time continue one sample instead of adding duplicate points
- Events no longer append an extra profile point; they attach to their sample
- Deco fields are only set on samples where the computer reported `DC_SAMPLE_DECO`; safety and deep stops now fill `decoStop`/`decoTime`
- `SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY` and `SAMPLE_EVENT_GASCHANGE2` map to their `DiveEvent` cases

### Fixed
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
