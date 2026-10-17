# Dive computer identity, catalog and fingerprint keys

A dive computer can now be reached over more than one transport: BLE everywhere, and serial and USB HID
cables on macOS. This page covers how LibDCSwift names the computer behind a download, the model catalog
cable pickers are built from, and how stored fingerprints move from the 1.18 layout to identity keys
without forcing anyone to download their whole logbook again.

## Transports

`DCTransport` is `ble`, `serial`, `usbHID`, `usb` or `classicBTSerial`. Its raw values (`"ble"`, `"serial"`,
`"usbhid"`, `"usb"`, `"btserial"`) are storage strings and won't change. `dcValue` is the iostream transport a
download opens with. A paired classic-Bluetooth computer shows up on macOS as a serial port, so
`classicBTSerial.dcValue` is `DC_TRANSPORT_SERIAL`.

`CableSupport.transports` lists the cable transports this platform can download over. That's
`[.serial, .usbHID]` on macOS and empty on iOS. It comes from `libdc_cable_transports()`, because
`dc_context_get_transports` always reports serial.

## Catalog

`DeviceCatalog.all` is built once, at runtime, from `dc_descriptor_iterator_new`, in libdivecomputer's table order.
Each `DCModel` has a vendor, a product, a family, a model, the transports it can use, and a canonical name.
`models(for:)` filters the list by transport. With the bundled libdivecomputer that gives:

| Transport | Models | Notes |
|---|---|---|
| `.serial` | 283 | 288 `SERIAL` descriptors, minus Shearwater's 5 |
| `.classicBTSerial` | 5 | Shearwater Predator, Petrel, Petrel 2, Nerd and Perdix. Shearwater makes no cable, so their `SERIAL` flag means the paired Bluetooth SPP port |
| `.usbHID` | 10 | Suunto EON Steel family, Scubapro G2 family, Aladin Square, G3 |
| `.usb` | 2 | Atomic Aquatics Cobalt and Cobalt 2 |
| `.ble` | 117 | |

IrDA-only models and RFCOMM sockets have no `DCTransport` case, so those models list no transports.

### Canonical name

`DeviceCatalog.canonicalName(family:model:)` is the first `DeviceConfiguration.supportedModels` entry with that
family and model. If there's none, it's the first descriptor in table order, and if there's no descriptor
either, it's `"<family> model <n>"`.

The order is fixed on purpose. DEVINFO reports only a family and a model, and those don't name one product:
G2 and G2 Console are both Uwatec Smart 0x32, and Petrel and Petrel 2 are both Shearwater Petrel 3. So the
name has to come from a fixed rule. `supportedModels` comes first because stored devices, and the
fingerprints 1.18 saved, are already named from it. A G2 Console therefore has the canonical name
"Scubapro G2", over BLE and over USB.

### USB candidates

`candidates(vid:pid:transport:)` returns the models a USB HID or USB device can be. It starts from
libdivecomputer's own filter (`dc_descriptor_filter`). That filter accepts any PID of the family for
every model in it, so 1493:0030 alone would match all four EON Steel models. An exact table then narrows the
result:

| VID:PID | Models |
|---|---|
| 1493:0030 | Suunto EON Steel |
| 1493:0033 | Suunto EON Core |
| 1493:0035 | Suunto D5 |
| 1493:0036 | Suunto EON Steel Black |
| 2e6c:3201 | Scubapro G2 TEK, Scubapro G2 (the user picks, or DEVINFO decides) |
| 2e6c:3211 | Scubapro G2 Console |
| 2e6c:4201 | Scubapro G2 HUD |
| c251:2006 | Scubapro Aladin Square |
| 0471:0888 (USB) | Atomic Aquatics Cobalt, Cobalt 2 (no table entry, so the filter's answer stands) |

The G3's PID isn't in libdivecomputer's table, so nothing matches it yet. Serial descriptors carry no VID or
PID, so on serial you pick the model.

## Identity

`DiveComputerIdentity` says which physical computer a download came from: the family, the model, the
canonical name, the serial, the firmware, and the transport it was downloaded over. A session download fills
it in from DEVINFO, and you can read it on `DiveComputerSession.identity`, `DiveDownloadResult.identity` and
`FingerprintCommit.identity`. The model is the one the session parses with: the reported model when a
descriptor knows it, and otherwise the descriptor the session opened.

- **Serial**: DEVINFO's serial as `%08x`. A serial of 0, empty, or none is unknown (`nil`). Cressi Edy and
  Oceans S1 report 0 for every unit, and some families never send DEVINFO at all.
- **`deviceKey`**: `"sn:<serial>"`, or `"md:<canonical name>"` lowercased when there's no serial. These are the
  keys hosts dedupe dives on. No key includes the transport, so the same computer gets the same key over BLE
  and over a cable.
- **`storageKey(standIn:)`**: the key fingerprints are stored under.
  - With a serial, it's `"dc:<family as %08x>:<serial>"`. The family is part of it, so two families can't
    share a fingerprint just because their serials happen to match.
  - With no serial, it's `"md:<canonical name>@<standIn>"`. The stand-in is the
    `DiveComputerLocator.unitStandIn`: the cable adapter's USB serial number, or the BLE peripheral's
    identifier on this host.
  - With neither, it's nil. Nothing is stored, and every download fetches every dive. A key built from the
    model alone would be shared by every unit of that model.

`DiveComputerLocator` (`ble`, `serial`, `usbHID`, `usb`, `classicBTSerial`) records where the computer was reached
this time. It's provenance for records and logs, never identity: ports, IORegistry IDs and BLE identifiers
all change. `locatorKey` is its string form, and it's what `StoredDevice.locatorKey` holds.

## Stored devices

- **New fields.** `StoredDevice` has `transport` and `locatorKey`. A record from before this change has
  neither, decodes with `transport == nil`, and reads as BLE (`effectiveTransport`). A record stored without
  them encodes exactly as before.
- **Unreadable records.** `DeviceStorage` decodes the list one record at a time. A record this version can't
  read (a family or transport from a newer version, or a missing field) is dropped on its own, instead of
  emptying the whole list.
- **`storedDevice(family:serial:)`** finds the most recently connected record of one computer on any
  transport. An unknown serial matches nothing.
- **`reconcileUUID(name:newUUID:)`** only moves BLE records. A BLE scan that sees "Suunto D5" won't re-key a
  USB HID record that has the same name.

## Fingerprints

`DeviceFingerprint` has a `key`, the identity's storage key. Records saved by 1.18 have none.

- **Lookup.** `DeviceFingerprintStorage.getFingerprint(for:standIn:)` looks for the identity's key first. If
  there's no match, it falls back to a 1.18 record whose device type names the same family and whose serial
  matches. So a store nobody has migrated never forces a full download.
- **Saving.** `saveFingerprint(_:for:standIn:)` replaces that computer's records, keyed or from 1.18, with one
  keyed record. It keeps the device type and serial a 1.18 reader looks up, so going back to an older
  version still finds the fingerprint.
- **Migration.** `migrateLegacyKeys(storedDevices:)` (or `DeviceStorage.migrateFingerprintKeys()`) keys 1.18
  records in place. Their device type, serial, fingerprint and timestamp don't change. It's idempotent, so
  it's safe to run on every launch.
  - A record whose device type names no family stays as it is, and the 1.18 lookup still finds it.
  - A serial-0 record is keyed only when exactly one BLE stored device of its family has serial 0. That
    device's UUID becomes the stand-in.
- **Seeding.** `seedFingerprint(identity:data:standIn:)` stores the fingerprint of a dive the host already
  has, for example one another device downloaded. The first download on this host then stops there. It
  never replaces a stored fingerprint. Only seed from a download that completed: anything older than the
  seeded dive is never offered again.

Session downloads (`retrieveDiveLogs(session:)`) look up and commit by identity. The C lookup's context is
the session, and it keys on DEVINFO instead of on the descriptor's name. The `CBPeripheral` download still
uses the 1.18 `(deviceType, serial)` keys, unchanged.
