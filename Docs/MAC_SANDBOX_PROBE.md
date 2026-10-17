# Mac sandbox probe (L0)

`DC Tester Mac` is a native macOS build of DC Tester that does one job: show,
on real hardware, whether a sandboxed, hardened-runtime Mac app on macOS 26 can
find, open and talk to each dive-computer cable transport. Its results decide
which cable families a sandboxed Mac App Store app can support, and which
entitlements it needs.

The probe lives only in `NauticTestApp/MacProbe/` (all `#if os(macOS)`). It
doesn't change the library. It calls IOKit, CoreBluetooth and AppKit directly,
and calls libdivecomputer through `Clibdivecomputer` for the serial line test,
the serial identify and libdc's own serial iterator. LibDCSwift supplies the
BLE service list. The iOS DC Tester target is unchanged.

## Build and run

```sh
cd NauticTestApp
xcodegen generate
xcodebuild -project NauticTestApp.xcodeproj -scheme 'DC Tester Mac' -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/mac build
open "build/mac/Build/Products/Release/DC Tester Mac.app"
```

- **Use Release for HIL runs.** A Release build carries exactly the six L0
  entitlements. Debug builds also carry `get-task-allow`, which lets lldb
  attach. It doesn't change the sandbox's device checks, but it isn't the
  shipping shape, and the report lists it under "Other entitlements present".
- The build is universal (arm64 + x86_64), ad-hoc signed, with the App Sandbox
  and hardened runtime on. The entitlement set lives in `project.yml` and is
  written to `Generated/DCTesterMac.entitlements`. To check the built app:
  `codesign -d --entitlements :- "build/mac/Build/Products/Release/DC Tester Mac.app"`.
- A build phase stamps `git rev-parse --short HEAD` into the app's Info.plist,
  with `-dirty` when the worktree has changes. The report prints it as
  "Probe commit".
- **Intel Mac:** zip the app with
  `ditto -c -k --keepParent "DC Tester Mac.app" probe.zip` and copy it over. On
  the Intel Mac, run `xattr -dr com.apple.quarantine "DC Tester Mac.app"`, then
  open it. It's ad-hoc signed, so Gatekeeper blocks it until the quarantine flag
  is removed.
- **Rosetta:** `arch -x86_64 "…/DC Tester Mac.app/Contents/MacOS/DC Tester Mac" --autorun`
  runs the x86_64 slice on Apple silicon, and the report shows "x86_64 under
  Rosetta". It's a quick check of the Intel slice, but it doesn't replace a real
  Intel Mac, where USB and Bluetooth sit differently in the registry and the
  drivers aren't the same.
- **Autorun:** `--autorun` enumerates everything, runs the open tests, prints
  the markdown report to stdout and exits. `--identify` adds the HID identify
  round trip on every HID device whose VID:PID is a known model. `--ble` adds a
  10 s BLE scan before the report.
- **Launch with `open`, not from a shell.** When Terminal starts the binary,
  macOS treats Terminal as the responsible process for privacy (TCC), so
  Terminal's Bluetooth and Input Monitoring grants and prompts stand in for the
  app's. The report's "Launched" row says which happened. To launch through
  LaunchServices and still capture the report:
  `open -W -n --stdout report.md "DC Tester Mac.app" --args --autorun --identify`.
- **What "Run open tests" opens:** USB serial ports whose VID:PID is a known
  cable or bridge chip, Bluetooth SPP ports, and the two system ports (raw open
  only, no termios change). Any other USB serial device, such as an Arduino, a
  3D printer or a UPS, is skipped, because the DTR drop on close resets some of
  them. So are FTDI's multi-channel and MPSSE chips (0403:6010, 6011 and 6014),
  which JTAG/SWD adapters use and no known dive cable does. On HID, it opens
  any Suunto (0x1493) or Scubapro (0x2e6c) device, and c251 only as c251:2006
  (Aladin Square), since 0xc251 is Keil's VID and also covers ULINK2 and
  CMSIS-DAP probes. It never opens a device on the keyboard and mouse usage
  page (0x0001), whose open can raise the Input Monitoring prompt. Every
  skipped port or device keeps its own **Open test** button, with a warning
  line saying why it was skipped.
- **Before "Run open tests", unplug any dev board or debug adapter that uses an
  FTDI, CP210x, PL2303 or CH34x chip,** such as ESP32 and ESP8266 boards,
  Arduino clones, and JTAG/SWD probes. The run opens every port on those chips
  apart from FTDI's multi-channel ones, so it toggles DTR and RTS on them, and
  boards with auto-reset wiring reset or drop into their bootloader. The
  toolbar button's help says the same.
- **Logs:** `/usr/bin/log stream --predicate 'subsystem == "com.deepsealabs.DCTesterMac"'`.
  For sandbox denials: `/usr/bin/log stream --predicate 'sender == "Sandbox"'`.
  The container is `~/Library/Containers/com.deepsealabs.DCTesterMac`.

## What it probes

| Section | What runs | Entitlement |
|---|---|---|
| Environment | macOS version and build, Mac model, Apple silicon or Intel, binary slice and whether Rosetta is translating it, how it was launched, sandbox container, each entitlement as the kernel granted it (`SecTaskCopyValueForEntitlement`) plus any extra ones present, libdivecomputer version, probe commit, Input Monitoring state | |
| Serial ports | IOKit `IOSerialBSDClient` enumeration (`kIOCalloutDeviceKey`). Parent USB VID/PID/serial/product come from `IORegistryEntrySearchCFProperty` (recursive, parents). Hot-plug uses `kIOFirstMatchNotification` and `kIOTerminatedNotification`. Each port is classified by walking its providers as USB, Bluetooth SPP, Bluetooth incoming or built-in. Ports with no USB parent are marked hidden in the product UI. The section also lists `/dev` and runs libdc's own `dc_serial_iterator` | device.serial |
| Serial open test, raw | `open(O_RDWR\|O_NOCTTY\|O_NONBLOCK)`, `TIOCEXCL`, `tcgetattr`, then on USB and SPP ports `cfsetspeed(9600)`, `tcsetattr` and a `tcsetattr` back to the saved termios, then `TIOCNXCL` and `close`. This is the POSIX half of `dc_serial_open` and `dc_serial_close`, step by step, so each failure has its errno. On USB ports only, between the 9600 `tcsetattr` and the restore, it also sends `IOSSIOSPEED` (`0x80085402`, since Swift can't import the macro) at 460800 (Sporasub SP2) and 850000 (Cochran). That's the ioctl `serial_posix.c` uses for custom rates once L1 defines `HAVE_IOKIT_SERIAL_IOSS_H`, so this is the L0 evidence for L1's custom-baud check | device.serial |
| Serial open test, libdc line control | On USB and SPP ports only: libdc's own `dc_serial_open`, then `dc_iostream_configure` at each framing the HIL families use: 2400 8O1 (Suunto Vyper), 9600 8N1 (Suunto D9/Vyper 2), 38400 8N1 (Oceanic Atom 2), 115200 8E1 (Mares Icon HD) and 115200 8N1 (Shearwater, HW OSTC/OSTC3, Cressi Leonardo, iDive, Pelagic VTX/i750TC/Pro Plus X/i770R). Then `set_dtr(1)`, `set_rts(1)`, `set_rts(0)` (on the Suunto interface DTR powers the cable and RTS sets the direction), `purge(ALL)`, `set_break(1)` and `set_break(0)` (Cochran, Reefnet), `set_timeout(300)`, a 1-byte read that should time out, then `dc_iostream_close`, which restores termios. Each step reports its `dc_status_t` and the errno text libdc logged for it. On a Bluetooth SPP port the result rests on Shearwater's sequence alone (115200 8N1, `set_timeout`, `purge`, the read), and any other failed step is reported as informational | device.serial |
| Serial identify | Manual, per port: `dc_device_open` with the descriptor picked in **Identify as**. The picker lists every libdc descriptor with a serial transport, HIL models first, and **Find model** filters it. Each entry says whether its family's open reads the version: Suunto D9/Vyper 2, the Oceanic Atom 2 family (Aqualung i770R included) and Mares Icon HD do, so a success is a real round trip; Suunto Vyper, HW OSTC, Cressi Leonardo and Shearwater Petrel only configure the line. Families nobody has checked show "open behaviour unknown". Pick the exact model: the Oceanic Atom 2 family opens at 38400 or 115200 depending on it | device.serial |
| Built-in serial drivers | Reads `IOKitPersonalities` from the AppleUSBFTDI, SLCOM, PLCOM, CHCOM and Serial dexts in `/System/Library/DriverExtensions`, and marks each known cable VID:PID as covered or not, including which interface the personality binds. It needs no cable, so every Mac records its table | |
| USB-serial bridges | Every FTDI, CP210x, PL2303 or CH34x USB device, with its device and interface drivers. A device with no `IOSerialBSDClient` under it is flagged **driverMissing** (expected for Pelagic 0403:F460) | device.serial |
| USB-HID | `IOHIDManager` matching by VID only (0x1493, 0x2e6c and 0xc251), so anything else on those VIDs, such as a Suunto Ambit watch or a Keil debug probe, is listed too. Only known PIDs are opened automatically (see "Run open tests" above). Never calls `IOHIDManagerOpen`. Lists VID/PID, product, usage page and max report sizes | device.usb |
| HID open test | Runs in seize mode, then shared, each on a fresh `IOHIDDevice`. The sequence is `IOHIDDeviceOpen`, input-report and removal callbacks, `IOHIDDeviceSetDispatchQueue`, cancel handler, `IOHIDDeviceActivate`, a 2 s listen, `IOHIDDeviceCancel`, waiting for the cancel handler, then `IOHIDDeviceClose` and `IOHIDCheckAccess`. IOReturn codes are reported as text | device.usb |
| HID identify | Offered only for the VID:PIDs in the model table. **Send identify** (or `--identify`) swaps the passive listen for libdc's first read-only commands, sent with a synchronous `IOHIDDeviceSetReport(Output)` as hidapi does. EON Steel family: `CMD_INIT` built as in `suunto_eonsteel_send` (byte-identical to libdc's, CRC included), sent as report ID 0x3f with the full 64 bytes; the reply must start with 0x3f and echo seq 0. G2 family and Aladin Square: the open handshake (`0x1B`, then `0x1C 10 27 00 00`) and `CMD_MODEL 0x10`, each sent as report ID 0 with the 32 bytes after it; the reply's byte 0 is its length. Each command records the SetReport IOReturn, the time to its reply and the reply's first 16 bytes. Reports that can't be the reply (an EON Steel report without 0x3f or with another seq, a G2 packet whose length byte isn't 1) are skipped and counted. If none could be, the first one is shown anyway, so a missing report-ID byte still shows up | device.usb |
| USB raw | `IOUSBHostDevice` enumeration, with device-level drivers (hub, composite or a vendor dext), user clients (named after the process holding them) and interface drivers. An Atomic Cobalt (0471:0888) gets a plug-in test: `USBDeviceOpen`, `GetConfiguration` (and, if it's 0, `SetConfiguration` from configuration descriptor 0, on a Cobalt only), `CreateInterfaceIterator`, an `IOUSBInterfaceInterface` on interface 0, `USBInterfaceOpen`, `GetNumEndpoints` and `GetPipeProperties` for each pipe, a check for bulk 0x82 in and 0x02 out, then both closes. Two seconds after the test the probe refreshes, so the Enumerate cell shows the interfaces and drivers a new configuration created. A test that set the configuration then runs once more, as "second run (configured)", whose `USBInterfaceOpen` shows whether a driver claimed interface 0 once matching settled. Any listed USB device can be tested by hand under "All USB devices" | device.usb |
| Bluetooth LE | Creates a `CBCentralManager` only when **Scan 10 s** is pressed (or with `--ble`), which raises the permission prompt. Reports the state, authorization, peripherals seen, and dive computers (known service UUID or a name LibDCSwift recognizes) | device.bluetooth |
| Garmin volume | `NSOpenPanel` to pick the volume, a count of `GARMIN/Activity/*.fit`, then an app-scoped, read-only security bookmark is created and resolved. **Resolve saved bookmark** after relaunching the same binary tests that it persists. The listing runs off the main thread | files.user-selected.read-write, files.bookmarks.app-scope |
| Copy report | Markdown: environment, the matrix, per-port and per-device steps, events. It's scrubbed for this public repo: every USB serial seen this session becomes `<serial>` (FTDI and usbmodem port names embed it), `~` replaces the home path, and digit-heavy BLE and SPP names, which usually carry the device serial, are masked | |

The open test's HID listen is passive, and the EON Steel and G2 family only
send when commanded, so 0 reports in 2 s is normal. **Send identify** is the
round trip: it shows `IOHIDDeviceSetReport` works under the sandbox and that
input reports arrive with the report-ID byte L8 expects.

## Reading results

| Result | Meaning |
|---|---|
| Serial open `EPERM` | `device.serial` is missing or not honoured |
| Serial open `EBUSY`, or `TIOCEXCL` fails | Another process holds the port, e.g. SuuntoLink, Suunto DM5, Oceanlog, DiverLog+ |
| `ENOENT` / `ENXIO` | The cable was unplugged mid-test |
| libdc `configure 2400 8O1` FAILED | The driver rejects odd parity, so Suunto Vyper-family downloads can't run |
| libdc `set_dtr` / `set_rts` FAILED, usually `ENOTTY` | The driver rejects modem-line ioctls. The Suunto interface can't be powered or switched, and the Pelagic, Mares and Cressi opens can't set the lines they need. A pseudo-terminal shows this same failure, since ptys have no modem lines |
| A family list in brackets after a failed libdc step, e.g. `set_dtr(1) [Suunto, Pelagic, Mares, Cressi]` | Only those families' opens need that step, so it's a no-go for them and not for the others. On a Bluetooth SPP port only Shearwater's steps count, and the rest are listed as informational failures |
| `custom baud: 460800 FAILED [Sporasub SP2]` / `850000 FAILED [Cochran]` | The driver refuses `IOSSIOSPEED` at that rate, so that family can't run even with `HAVE_IOKIT_SERIAL_IOSS_H` defined. Record the errno |
| libdc `read 1 byte` `DC_STATUS_TIMEOUT` | Expected: nothing on the line answers an idle port |
| Serial identify `DC_STATUS_TIMEOUT` | The line works but nothing answered: wrong descriptor (pick the exact model, since Pelagic baud rates differ by model), computer not in PC mode, or the cable's IR window isn't aligned |
| driverMissing | The USB device is present but no serial driver bound. For 0403:F460, FTDI's VCP driver is required |
| Known cable PIDs "matched only on a later interface" | Apple's personality binds interface 1 or higher. A single-interface cable with that PID gets no driver, so check its row for driverMissing |
| HID seize or shared `kIOReturnExclusiveAccess` | Another app has seized the device, e.g. SuuntoLink or Scubapro LogTRAK. A shared open returns the same code, and its reports are dropped until the seizing app closes. Quit the other app and rerun. A seize also succeeds over another app's non-exclusive open and silently cuts it off |
| HID identify `SetReport FAILED` | The sandbox or the driver refused the output report. Record the IOReturn |
| HID identify `no reply` | SetReport worked but no input report came back within 2 s. Check the computer is awake and in USB mode |
| HID identify `byte 0 is …, expected report ID 0x3f` | The report-ID byte isn't in the buffer where L8's EON Steel reader expects it |
| HID or USB `kIOReturnNotPermitted` / `kIOReturnNotPrivileged` | The sandbox refused it (`device.usb`) or Input Monitoring denied it. Check System Settings > Privacy & Security |
| Input Monitoring `unknown` before and after | No TCC request happened. A change to `granted` or `denied` after a HID test means the open asked for Input Monitoring |
| USB plug-in fails at `IOCreatePlugInInterfaceForService` | The sandbox blocked the IOUSBLib user client. Record the IOReturn |
| `USBDeviceOpen` ok, then `USBInterfaceOpen` `kIOReturnExclusiveAccess` | A kernel driver or dext owns interface 0, so L9 can't claim it. The interface line names the driver |
| `device held by …` on an interface line | A device-level driver, such as a hub driver or a vendor dext, owns the whole device. Composite drivers only pick the configuration, so they don't count |
| Cobalt `if0 class 0xff: no driver`, `USBInterfaceOpen` ok, `0x82 bulk in present, 0x02 bulk out present` | Nothing owns the vendor-class interface and the pipes match `atomics_cobalt.c`: the L9 assumption holds. If the Cobalt arrived unconfigured, read this from the "second run (configured)" row |
| Cobalt `SetConfiguration` FAILED | The device came up unconfigured and couldn't be configured, so no interfaces exist |
| BLE `unauthorized` | Bluetooth permission denied, or `device.bluetooth` missing |
| Bookmark create fails | `files.bookmarks.app-scope` is missing. A stale resolve means the volume was renamed or reformatted |

## Negative controls

Each control re-signs a copy of the Release app without one entitlement (or,
for the last one, with `user-selected.read-only` in place of read-write), then
runs it. The report marks the dropped entitlement `(MISSING)` in every row that
depends on it, so each control's report stands on its own.

```sh
cd NauticTestApp
app="build/mac/Build/Products/Release/DC Tester Mac.app"
ent=Generated/DCTesterMac.entitlements
out=/tmp/dctester-controls
for control in device.serial device.usb device.bluetooth files.bookmarks.app-scope user-selected.read-only; do
  dir="$out/$control"
  rm -rf "$dir" && mkdir -p "$dir"
  cp -R "$app" "$dir/"
  cp "$ent" "$dir/control.entitlements"
  if [ "$control" = user-selected.read-only ]; then
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.files.user-selected.read-write" \
      -c "Add :com.apple.security.files.user-selected.read-only bool true" "$dir/control.entitlements"
  else
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.$control" "$dir/control.entitlements"
  fi
  codesign --force --sign - --options runtime --entitlements "$dir/control.entitlements" "$dir/DC Tester Mac.app"
done

# Unattended. Attach a serial cable and a HID dive computer first.
for control in device.serial device.usb; do
  open -W -n --stdout "$out/$control/report.md" "$out/$control/DC Tester Mac.app" --args --autorun --identify
done

# Needs a person to answer the Bluetooth prompt if one appears.
open -W -n --stdout "$out/device.bluetooth/report.md" "$out/device.bluetooth/DC Tester Mac.app" --args --autorun --ble
```

Then for the Garmin controls, run `open -n "$out/files.bookmarks.app-scope/DC Tester Mac.app"`
and the same for `user-selected.read-only`. In each one, press **Choose
volume…**, pick the Garmin volume, then **Copy report**.

With no HID dive computer or Cobalt attached, the `device.usb` control can't
open anything on its own. In that case, launch its copy with `open -n`, expand
"All USB devices", and press **Plug-in test** on any listed device.
`IOCreatePlugInInterfaceForService` failing there, while the full build passes
it, shows that `device.usb` gates IOUSBLib.

A saved bookmark only resolves in the exact binary that created it: an
ad-hoc build is identified by its cdhash, which changes with every re-sign and
rebuild. So press **Choose volume…** in each control copy, and run **Resolve
saved bookmark** only after relaunching that same binary. Each copy also has a
new code signature, so macOS asks again for any TCC permission.

## Baseline run, no dive hardware (2026-10-16)

This was a Mac16,12 (Apple M4) on macOS 26.4 (25E246). It ran the Release
build's arm64 slice, launched with `open … --args --autorun` and from Terminal,
at probe commit `dc1d5e2-dirty` (the probe wasn't committed yet).

- The app is sandboxed and holds exactly the six L0 entitlements, with nothing
  else present. `--autorun` printed the report and exited 0 within 3 s. The
  full build logged no sandbox denials. The only denials all session were the
  two expected `deny file-read-data /dev/cu.*` in the `device.serial` control.
- IOKit serial found two ports, `cu.Bluetooth-Incoming-Port` (Bluetooth
  incoming) and `cu.debug-console` (built-in). Both are flagged hidden in the
  product UI. On both, `open`, `TIOCEXCL`, `tcgetattr`, `TIOCNXCL` and `close`
  worked. Their termios was left alone, and the libdc line test was skipped
  because they're system ports.
- The libdc line test and the serial identify had no USB or SPP port to run on.
  Outside the sandbox, against a pseudo-terminal, every step returned its
  status with libdc's errno text. The read timed out after 305 ms with nothing
  writing, and returned the byte when the other side wrote one. `set_dtr` and
  `set_rts` failed with `ENOTTY (25)`, as they must on a pty.
- opendir `/dev` worked (2 `cu.*`, 2 `tty.*`), and libdc's `dc_serial_iterator`
  returned `DC_STATUS_SUCCESS` with the 2 `tty.*` ports.
- **Built-in drivers** (all dexts at CFBundleVersion 1, build 25E226): 13 of the
  14 known cable PIDs are covered. 0403:F460 (Pelagic) isn't. 0403:F680
  (Suunto) is matched on interface 0. 0403:87D0 (Cressi) is matched only on
  **interface 1** ("FTDI CRESSI"), so a single-interface Cressi cable with that
  PID would get no driver. The Cressi HIL row has to check for driverMissing.
- IOKit USB saw 5 `IOUSBHostDevice`s. Each hub is held at device level by
  `AppleUSB20Hub` or `AppleUSB30Hub`. The card reader and the Ethernet adapter
  carry composite drivers, with `IOUSBMassStorageInterfaceNub` and the
  `AppleUserECM` dexts on their interfaces. Chrome held user clients on every
  device. Outside the sandbox, the card reader showed why the interface step
  matters: `USBDeviceOpen` succeeded, then `USBInterfaceOpen` returned
  `kIOReturnExclusiveAccess`. The hub was refused at `USBDeviceOpen`.
- No HID device matched the three VIDs, and there was no Cobalt.
- Input Monitoring was `unknown` from the `open` launch and `granted` from the
  Terminal launch. That second value is Terminal's own grant, which is why the
  report records how the probe was launched.
- **Negative controls:** without `device.serial`, `open` failed with `EPERM` on
  both ports, while the `/dev` listing and IOKit enumeration still worked. So
  `device.serial` is enforced, and it's required for opening a port, not for
  finding one. Without `device.usb`, USB and HID enumeration still worked, and
  with no HID device or Cobalt attached nothing else could be tested. The
  Bluetooth and Garmin controls need a person.
- BLE, Garmin and Intel weren't run, because they need a person at a Mac.

## HIL matrix

Fill in one machine block per Mac, then the matrix. In the arm64 and Intel
columns, put enumerate / open / line control and read for each, using the
values in the report's matrix row. For HID, run **Send identify** and use its
row. Paste the full report under "Raw reports".

| Machine | Model | macOS | Slice | Probe commit | Date | Tester |
|---|---|---|---|---|---|---|
| arm64 | | | arm64 native | | | |
| Intel | | | x86_64 native | | | |

| Family / device | Transport (VID:PID) | Entitlement | arm64 enum / open / line + read | arm64 error | Intel enum / open / line + read | Intel error | Decision |
|---|---|---|---|---|---|---|---|
| Suunto USB-serial cable (Vyper, D-series, Novo) | serial, FTDI 0403:f680 | device.serial | | | | | |
| Suunto EON Steel (USB) | USB-HID 1493:0030 | device.usb | | | | | |
| Suunto EON Core (USB) | USB-HID 1493:0033 | device.usb | | | | | |
| Suunto D5 (USB) | USB-HID 1493:0035 | device.usb | | | | | |
| Scubapro G2 / G2 TEK (USB) | USB-HID 2e6c:3201 | device.usb | | | | | |
| Scubapro Aladin Square (USB) | USB-HID c251:2006 | device.usb | | | | | |
| Heinrichs Weikamp OSTC (USB) | serial, FTDI 0403:6015 / 6001 | device.serial | | | | | |
| Pelagic: Oceanic / Aqualung / Sherwood (USB) | serial, 0403:f460 (vendor driver) or CP210x / PL2303 | device.serial | | | | | |
| Mares (USB / IR-USB) | serial, chip to confirm | device.serial | | | | | |
| Cressi (USB) | serial, FTDI 0403:87d0 (Apple binds interface 1 only) | device.serial | | | | | |
| Shearwater, paired classic BT (Predator, Petrel 1, Nerd) | serial over Bluetooth SPP `/dev/cu.*` | device.serial | | | | | |
| Atomic Aquatics Cobalt / Cobalt 2 | USB raw 0471:0888 | device.usb | | | | | |
| Garmin Descent volume | mass storage, `GARMIN/Activity/*.fit` | files.user-selected.read-write, files.bookmarks.app-scope | | | | | |
| BLE scan (any BLE dive computer) | BLE | device.bluetooth | | | | | |

Decision: **v1** ships on, **flagged** ships labelled Beta behind the
RemoteConfig kill switch, **dropped** doesn't ship. Record a vendor driver or a
vendor app that had to be quit in the error column.

### Minimal entitlement set (feeds M49)

Fill "Confirmed by" from the negative controls above.

| Entitlement | Needed for | Confirmed by | M49 |
|---|---|---|---|
| com.apple.security.app-sandbox | Mac App Store | | |
| com.apple.security.device.serial | Serial cables, Bluetooth SPP | `EPERM` on open without it (baseline above) | |
| com.apple.security.device.usb | USB-HID, IOUSBLib | `device.usb` control, with a HID device attached or a manual Plug-in test | |
| com.apple.security.device.bluetooth | BLE | `device.bluetooth` control | |
| com.apple.security.files.user-selected.read-write | Garmin volume pick | `user-selected.read-only` control: if it passes, read-only is enough | |
| com.apple.security.files.bookmarks.app-scope | Garmin volume across launches | `files.bookmarks.app-scope` control: may not be needed on current macOS | Recheck bookmark persistence with a team-signed app build: an ad-hoc bookmark is bound to that build's cdhash, so its result doesn't carry over |
| com.apple.security.network.client | Not in the probe build; a consumer app needs it for its own backend | | |

### Raw reports

<!-- Paste each machine's "Copy report" output here. -->
