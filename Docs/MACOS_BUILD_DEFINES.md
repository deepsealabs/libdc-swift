# macOS build defines

LibDCSwift builds libdivecomputer from source as the `Clibdivecomputer` target, without running its
`./configure`. Every feature macro that `configure` would normally detect is set by hand in
`Package.swift`. This page lists the macros that differ between iOS and macOS, what each one changes,
and how to check that iOS builds stay the same.

## What macOS adds

Both macros are set with `.when(platforms: [.macOS])`, so iOS (device and Simulator) is compiled exactly
as before.

| Macro | Where libdivecomputer uses it | Effect on macOS |
|---|---|---|
| `HAVE_IOKIT_SERIAL_IOSS_H` | `serial_posix.c` includes `<IOKit/serial/ioss.h>` | Serial rates with no `Bxxx` constant are set with the `IOSSIOSPEED` ioctl instead of failing with `DC_STATUS_UNSUPPORTED`. That covers the Sporasub SP2 (460800) and the Cochran EMC models (850000). `DC_IOCTL_SERIAL_SET_LATENCY` also sets the receive latency with `IOSSDATALAT` instead of doing nothing; no driver in the bundled libdivecomputer calls it. Header only: nothing new is linked. |
| `HAVE_CLOCK_GETTIME` | `timer.c` | Serial read timeouts are measured with `clock_gettime(CLOCK_MONOTONIC)` instead of `gettimeofday`, so a wall-clock change can't stretch or cut a timeout. |

`dc_serial_open` and the rest of `serial_posix.c` were already compiled on every platform; these
macros only change which branches inside it are built.

## What stays unset, and why

- **`HAVE_CONFIG_H`**: never defined. A local `./configure` run inside the `libdivecomputer`
  submodule leaves an untracked `config.h` with whatever that machine detected (for
  example `HAVE_LIBUSB`). Defining `HAVE_CONFIG_H` would quietly pull it into some builds and not others.
- **Date and time macros** (`HAVE_LOCALTIME_R`, `HAVE_GMTIME_R`, `HAVE_TIMEGM`,
  `HAVE_STRUCT_TM_TM_GMTOFF`): unset on both platforms, so `datetime.c` converts dive times with the
  same code on iOS and macOS and a dive parses to the same date on either.
- **`HAVE_HIDAPI` and `HAVE_LIBUSB`**: unset, so `usbhid.c` and `usb.c` stay stubs and no third-party
  USB library is bundled.

Mac Catalyst hasn't been built or tested with these macros.

## Runtime probe

`libdc_has_custom_baud()` (declared in `configuredc.h`, exported by LibDCBridge) returns true when the
serial driver was built with `IOSSIOSPEED`. `Package.swift` passes the same `CSetting` to
`Clibdivecomputer` and to `LibDCBridge`, so the probe and the driver can't disagree. An app can use it
to hide computers that need a custom rate when it isn't available.

## Tests

`Tests/LibDCSwiftTests/SerialBuildConfigTests.swift` opens libdivecomputer's own serial driver on a
pseudo-terminal. A pty has no real line speed, so these tests check what was compiled in, not that a
cable runs at the rate.

| Test | macOS | iOS |
|---|---|---|
| `testCustomBaudProbeMatchesPlatform` | probe is true | probe is false |
| `testNonStandardBaudFollowsTheProbe` | `configure(460800)` tries the ioctl (the pty rejects it), so not `UNSUPPORTED` | `UNSUPPORTED` |
| `testLatencyIoctlFollowsTheProbe` | `DC_IOCTL_SERIAL_SET_LATENCY` sends `IOSSDATALAT` (the pty rejects it) | no-op, `SUCCESS` |
| `testStandardBaudRoundTrip` | 9600 8N1, 4 bytes each way | same |
| `testReadTimeoutKeepsPartialData` | a 200 ms read returns `TIMEOUT` with the 2 bytes that arrived, within 50 ms of the deadline | same |

Negative controls, run on macOS:

- Define removed from `Clibdivecomputer` only: the probe says true but the driver returns
  `UNSUPPORTED` for 460800 and `SUCCESS` for the latency ioctl, so `testNonStandardBaudFollowsTheProbe`
  and `testLatencyIoctlFollowsTheProbe` fail.
- Define removed from both targets: only `testCustomBaudProbeMatchesPlatform` fails. The other four
  pass with the iOS expectations, which checks those branches on the same kernel.

## Checking that iOS is unchanged

Build the `LibDCSwift` scheme for each platform into one derived data folder, then compare the
exported and imported symbols of the three objects with a build of the previous release:

```sh
xcodebuild -scheme LibDCSwift -destination 'generic/platform=iOS' -derivedDataPath <dd> build
xcodebuild -scheme LibDCSwift -destination 'generic/platform=iOS Simulator' -derivedDataPath <dd> build
xcodebuild -scheme LibDCSwift -destination 'generic/platform=macOS' -derivedDataPath <dd> build

for m in Clibdivecomputer LibDCBridge LibDCSwift; do
  nm -gU <dd>/Build/Products/Debug-iphoneos/$m.o | grep -v -E '^$|\(for architecture ' | awk '{print $NF}' | sort -u > $m.txt
  nm -u  <dd>/Build/Products/Debug-iphoneos/$m.o | grep -v -E '^$|\(for architecture ' | awk '{print $NF}' | sort -u > $m.undef.txt
done
```

Results against this branch's base commit, Xcode 26.4 SDKs, 2026-10-17 (`generic/platform=iOS`
and `generic/platform=macOS`, same derived data root rebuilt for each side so the `.o` paths line
up):

| Target | Exports (`nm -gU`) before → after |
|---|---|
| Clibdivecomputer (iOS, macOS) | 372 → 372, no diff |
| LibDCBridge (iOS, macOS) | 21 → 22, the one addition is `_libdc_has_custom_baud` on both platforms |
| LibDCSwift (iOS, macOS) | 2498 → 2498, no diff |

`grep -i iokit` over `nm -gU` for all three iOS objects returns nothing on either side of the
change; over `nm -u` it returns nothing after the change (not separately checked before, since the
exports diff above already shows the only addition).

On macOS, `nm -gU` on `Clibdivecomputer.o` after the change exports `_dc_serial_open` (not exported
on iOS either side), and `LibDCBridge.o` exports `_libdc_has_custom_baud` alongside it.

`swift test` on macOS: 132 tests, 1 skipped (`testCaptureCorpus`, needs local captures), 0 failures.
127 of those 132 pass on the base commit (the 5 new ones are `SerialBuildConfigTests`).

`NauticTestApp` (`xcodegen generate`, then `xcodebuild -scheme NauticTestApp -destination
'generic/platform=iOS'`) still builds against the updated package.

## Not covered yet

- Real line speeds at 460800 and 850000 need the cable and the computer. A pty only shows that the
  ioctl is issued.
- The pty tests haven't run on an iOS Simulator for this change; the iOS test bundle builds and links.
