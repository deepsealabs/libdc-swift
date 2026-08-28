# Nautic Test App

A minimal, standalone iOS app for testing EXPERIMENTAL Suunto Nautic/Ocean
support in LibDCSwift, independent of the production Currents app.

## Status

This can connect to a Suunto Nautic/Ocean over BLE, run the (best-effort)
auth handshake, and issue raw RPC requests / download raw dive bytes. It
CANNOT yet:

- Automatically list which dives are on the watch (the `/Logbook/Entries`
  response format is unknown — no sample exists anywhere yet).
- Decode a downloaded dive into an actual profile (depth/time/temperature).
  The compression format is unsolved upstream.

See `libdivecomputer/src/suunto_nautic.h` in the submodule for the full
technical status, and https://github.com/libdivecomputer/libdivecomputer/issues/70
for the upstream reverse-engineering thread this is based on.

## What testers should do

1. Open the app, tap **Scan**, connect to your Nautic/Ocean.
2. On the Explorer screen, try the quick requests (`/System/Mode`,
   `/Logbook/Entries`, `/Logbook/UnsynchronisedLogs`) and note what comes
   back (or whether it errors/times out).
3. If you know a real logbook ID from your watch, try downloading it and
   export the raw capture (share sheet) — send it back so it can be used
   to reverse-engineer the missing pieces (entry listing format, chunk
   reassembly, compression).

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
