# DC Tester

A minimal, standalone iOS app for testing dive-computer support in
LibDCSwift, independent of the production Currents app. The internal Xcode
target and bundle id are still `NauticTestApp` (unchanged so the existing
TestFlight build is unaffected); the app presents as **DC Tester**.

## Status

The most complete device is the Suunto Nautic/Ocean. For it, this can
connect over BLE, run the (best-effort) auth handshake, list real dives
from the watch, and download + decode a dive into a full profile: depth,
temperature, tank pressure, atmospheric pressure, dive events (with Suunto
labels), gas switches, GPS, dive date/time, deco status (NDL/TTS/ceiling),
gradient factors, battery, GPS accuracy, and the 9-axis IMU. Other device
families connect through the shared LibDCSwift stack.

See `libdivecomputer/src/suunto_nautic.h` in the submodule for the full
technical status, and https://github.com/deepsealabs/libdc-swift/issues/29
for the reverse-engineering thread this is based on.

## What testers should do

1. Open the app, tap **Scan**, connect to your dive computer.
2. On the Device Explorer screen, tap **List Dives** and pick one — it
   downloads and decodes automatically.
3. If anything looks wrong, use **Export Raw Capture** (with a note
   describing what happened on the dive) and send it back — raw captures
   are what extend and validate support.

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
