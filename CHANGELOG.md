# Changelog
All notable changes to LibDCSwift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
