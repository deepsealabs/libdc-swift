# Nautic Test App

A minimal, standalone iOS app for testing EXPERIMENTAL Suunto Nautic/Ocean
support in LibDCSwift, independent of the production Currents app.

## Status

This can connect to a Suunto Nautic/Ocean over BLE, run the (best-effort)
auth handshake, list real dives from the watch, and download + decode a
dive into a real profile (depth, temperature, tank pressure, atmospheric
pressure). It CANNOT yet:

- Decode dive events (alarms, gas switches, laps) or GPS.
- Report the exact dive date/time within a profile (the dive ID itself,
  shown in the dive list, already is the correct UNIX timestamp).

See `libdivecomputer/src/suunto_nautic.h` in the submodule for the full
technical status, and https://github.com/libdivecomputer/libdivecomputer/issues/70
for the upstream reverse-engineering thread this is based on.

## What testers should do

1. Open the app, tap **Scan**, connect to your Nautic/Ocean.
2. On the Explorer screen, tap **List Dives** and pick one — it downloads
   and decodes automatically.
3. If anything looks wrong, or you hit an alarm/gas-switch/lap on that
   dive, use **Export Raw Capture** (with a note describing what
   happened) and send it back — that's what's needed to map the
   remaining event chunks.

## Regenerating the Xcode project

This project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml` — the `.xcodeproj` itself is not committed. After
pulling changes, or after editing `project.yml`:

```sh
brew install xcodegen   # if not already installed
cd NauticTestApp
xcodegen generate
```

Then open `NauticTestApp.xcodeproj`, set your own signing team, and
build/archive for TestFlight as usual.
