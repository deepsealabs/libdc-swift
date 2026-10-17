#if os(macOS)
import Foundation

/// Markdown for Docs/MAC_SANDBOX_PROBE.md. Scrubbed for a public repo: no USB serials, home path or BLE/SPP serial names.
enum ProbeReport {
    @MainActor
    static func markdown(_ model: ProbeModel) -> String {
        var out: [String] = ["# DC Tester Mac probe report", ""]
        environment(model, into: &out)
        out += ["", "## Matrix", ""]
        out += [
            "| Family / device | Transport | Entitlement | Enumerate | Open | Line control / read | Error |",
            "|---|---|---|---|---|---|---|"
        ]
        serialRows(model, into: &out)
        hidRows(model, into: &out)
        usbRows(model, into: &out)
        bleRow(model, into: &out)
        garminRow(model, into: &out)
        details(model, into: &out)
        return scrub(out.joined(separator: "\n") + "\n", model)
    }

    @MainActor
    private static func environment(_ model: ProbeModel, into out: inout [String]) {
        out += ["| Key | Value |", "|---|---|"]
        func row(_ key: String, _ value: String) { out.append("| \(key) | \(cell(value)) |") }
        row("Date", ISO8601DateFormatter().string(from: Date()))
        if let env = model.environment {
            row("macOS", env.osVersion)
            row("Hardware", env.hardwareSummary)
            row("Binary slice", env.archSummary)
            row("App", "DC Tester Mac \(env.appVersion)")
            row("Probe commit", env.probeCommit)
            row("libdivecomputer", env.libdcVersion)
            row("Sandboxed", env.sandboxed ? "yes, container \(env.containerPath)" : "NO")
            row("Launched", env.launchedByLaunchd
                ? "by LaunchServices (Finder or open): TCC state is the app's own"
                : "from a shell: TCC checks and prompts belong to the terminal, rerun with open for Input Monitoring and Bluetooth")
            row("Entitlements granted", short(env.entitlements.filter(\.granted).map(\.key)))
            let missing = env.entitlements.filter { !$0.granted }.map(\.key)
            row("Entitlements missing", missing.isEmpty ? "none" : short(missing))
            row("Other entitlements present", env.extraEntitlements.isEmpty ? "none" : short(env.extraEntitlements))
        }
        let dev = model.devListing
        row("opendir /dev", dev.error.map { "FAILED \($0)" } ?? "ok, \(dev.cu.count) cu.*, \(dev.tty.count) tty.*")
        if let iteration = model.libdcIteration {
            row("libdc dc_serial_iterator", "\(iteration.status), \(iteration.names.count): \(iteration.names.joined(separator: ", "))")
        }
        row("Hot-plug", model.hotplugErrors.isEmpty ? "IOKit notifications armed (serial, USB)" : model.hotplugErrors.joined(separator: "; "))
        row("Input Monitoring (IOHIDCheckAccess ListenEvent)",
            "\(model.inputMonitoringAtLaunch) at launch, \(model.inputMonitoringAfterHID.map { "\($0) after HID tests" } ?? "no HID test run")")
        row("Built-in serial drivers", model.builtInDrivers.map(\.summary).joined(separator: "; "))
        row("Known cable PIDs", coverageSummary(model.cableCoverage))
        row("Bluetooth authorization", model.ble.authorization)
    }

    private static func coverageSummary(_ coverage: [CableCoverage]) -> String {
        let missing = coverage.filter { $0.coveredBy.isEmpty }
        let offInterface = coverage.filter { !$0.coveredBy.isEmpty && !$0.matchesInterfaceZero }
        var parts = ["\(coverage.count - missing.count) of \(coverage.count) covered"]
        if !missing.isEmpty { parts.append("NOT covered: " + missing.map { ProbeText.vidPid($0.vendorID, $0.productID) }.joined(separator: ", ")) }
        if !offInterface.isEmpty { parts.append("matched only on a later interface: " + offInterface.map(\.summary).joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }

    @MainActor
    private static func serialRows(_ model: ProbeModel, into out: inout [String]) {
        let entitlement = entitlement(model, "device.serial")
        if model.serial.ports.isEmpty {
            out.append(matrix("(no serial ports)", "serial", entitlement, model.serial.error ?? "IOKit: 0 ports", "-", "-", "-"))
        }
        for port in model.serial.ports {
            var transport = "serial, \(port.kind.rawValue)"
            if port.hiddenInProductUI { transport += ", hidden in product UI" }
            let enumerate = "IOKit \(scrubPort(port))"
            let identify = model.serialIdentify[port.id]
            guard let result = model.serialResults[port.id] else {
                let notRun = port.autoTestable ? "not run" : "not run (not auto-opened: manual Open test only)"
                out.append(matrix(name(port), transport, entitlement, enumerate, notRun, identify.map(identifySummary) ?? "-",
                                  identify?.steps.firstFailure?.line ?? "-"))
                continue
            }
            let open: String
            if !result.opened {
                open = "FAILED"
            } else if let failure = result.openSteps.firstFailure {
                open = "ok, then FAILED at \(failure.name)"
            } else {
                open = "ok"
            }
            let line = [lineSummary(result), identify.map(identifySummary)].compactMap { $0 }.joined(separator: "; ")
            // Named, as the first failure can be any of the open, custom-baud, libdc or identify steps.
            let error = result.steps.firstFailure?.line ?? identify?.steps.firstFailure?.line ?? "-"
            out.append(matrix(name(port), transport, entitlement, enumerate, open, line, error))
        }
        for device in model.bridgeDevices where device.driverMissing {
            out.append(matrix(device.displayName, "serial, USB bridge", entitlement, "USB only, no IOSerialBSDClient", "-", "-",
                              "driverMissing: " + device.driverLines.joined(separator: "; ")))
        }
    }

    private static func lineSummary(_ result: SerialOpenResult) -> String {
        guard result.opened else { return "-" }
        var parts: [String] = []
        if let libdc = result.libdc {
            parts.append(libdcSummary(libdc, kind: result.kind))
        } else {
            parts.append("skipped, system port")
        }
        if !result.customBaud.isEmpty {
            parts.append("custom baud: " + result.customBaud.map { step in
                "\(step.name.replacingOccurrences(of: "IOSSIOSPEED ", with: "")) \(step.outcome == .ok ? "ok" : "FAILED") [\(SerialProbe.families(needing: step.name) ?? "?")]"
            }.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    // Each failure names the families whose open needs that step; SPP is judged on Shearwater's steps alone.
    private static func libdcSummary(_ libdc: [ProbeStep], kind: SerialPort.Kind) -> String {
        guard libdc.first?.outcome == .ok else { return "libdc dc_serial_open FAILED" }
        func tagged(_ step: ProbeStep) -> String {
            SerialProbe.families(needing: step.name).map { "\(step.name) [\($0)]" } ?? step.name
        }
        let read = libdc.first { $0.name == "read 1 byte" }.map { "read \($0.detail)" } ?? "read not reached"
        let failed = libdc.filter { $0.outcome == .failed }
        var summary: String
        if !failed.isEmpty {
            summary = "libdc FAILED at \(failed.map(tagged).joined(separator: ", ")); \(read)"
        } else if kind == .bluetoothSPP {
            summary = "libdc ok for Shearwater: 115200 8N1, set_timeout, purge, \(read), close"
        } else {
            summary = "libdc ok: 2400 8O1, 9600/38400/115200 8N1, 115200 8E1, DTR, RTS 1/0, purge, break, set_timeout, \(read), close"
        }
        let notes = libdc.filter { $0.outcome == .informational }
        if !notes.isEmpty {
            summary += "; informational failures: " + notes.map(tagged).joined(separator: ", ")
        }
        return summary
    }

    private static func identifySummary(_ result: SerialIdentifyResult) -> String {
        let open = result.steps.first { $0.name.hasPrefix("dc_device_open") }
        let outcome = open.map { "\($0.outcome == .ok ? "ok" : "FAILED"), \($0.detail)" } ?? (result.steps.firstFailure?.line ?? "not reached")
        return "identify as \(result.target.title) (\(result.target.openBehaviour)): \(outcome)"
    }

    @MainActor
    private static func hidRows(_ model: ProbeModel, into out: inout [String]) {
        let entitlement = entitlement(model, "device.usb")
        if model.hidDevices.isEmpty {
            out.append(matrix("(no HID device for VID 1493/2e6c/c251)", "USB-HID", entitlement, "IOHIDManager: 0 matched", "-", "-", "-"))
        }
        for device in model.hidDevices {
            let enumerate = "IOHIDManager, \(device.usageSummary), \(device.reportSummary)"
            let results = model.hidResults[device.id] ?? []
            for mode in HIDOpenMode.allCases {
                let transport = "USB-HID, \(mode.rawValue)"
                let listen = results.first { $0.mode == mode && $0.identify == nil }
                let identify = results.first { $0.mode == mode && $0.identify != nil }
                guard let primary = identify ?? listen else {
                    let notRun = device.autoSkipReason.map { "not run (manual Open test only: \($0))" } ?? "not run"
                    out.append(matrix(device.displayName, transport, entitlement, enumerate, notRun, "-", "-"))
                    continue
                }
                let error = identify?.steps.firstFailure?.detail ?? listen?.steps.firstFailure?.detail ?? "-"
                out.append(matrix(device.displayName, transport, entitlement, enumerate,
                                  primary.opened ? "ok" : "FAILED", primary.readSummary, error))
            }
        }
    }

    @MainActor
    private static func usbRows(_ model: ProbeModel, into out: inout [String]) {
        let entitlement = entitlement(model, "device.usb")
        let cobalts = model.cobaltDevices
        if cobalts.isEmpty {
            let enumerate = model.usb.error ?? "IOKit \(model.usb.className): \(model.usb.devices.count) devices, no 0471:0888"
            out.append(matrix("(no Atomic Cobalt)", "USB raw", entitlement, enumerate, "-", "-", "-"))
        }
        for device in cobalts {
            let enumerate = "IOKit, " + device.driverLines.joined(separator: "; ")
            guard let steps = model.usbResults[device.id] else {
                out.append(matrix(device.displayName, "USB raw", entitlement, enumerate, "not run", "-", "-"))
                continue
            }
            out.append(usbRow(device.displayName, "USB raw, IOUSBLib", entitlement, enumerate, steps))
            if let second = model.usbSecondRuns[device.id] {
                out.append(usbRow(device.displayName, "USB raw, IOUSBLib, second run (configured)", entitlement, enumerate, second))
            }
        }
    }

    private static func usbRow(_ name: String, _ transport: String, _ entitlement: String, _ enumerate: String, _ steps: [ProbeStep]) -> String {
        func outcome(_ name: String) -> String? {
            steps.first { $0.name == name }.map { "\(name) \($0.outcome == .ok ? "ok" : "FAILED")" }
        }
        let open = [outcome("USBDeviceOpen"), outcome("SetConfiguration"), outcome("USBInterfaceOpen")].compactMap { $0 }
        let pipes = steps.first { $0.name == "Cobalt pipes" }.map(\.detail) ?? "pipes not reached"
        return matrix(name, transport, entitlement, enumerate, open.isEmpty ? "FAILED" : open.joined(separator: ", "), pipes,
                      steps.firstFailure?.detail ?? "-")
    }

    @MainActor
    private static func bleRow(_ model: ProbeModel, into out: inout [String]) {
        let ble = model.ble
        let enumerate: String
        if !ble.started {
            enumerate = "not run"
        } else if ble.scanned {
            let names = ble.diveComputers.map(scrubName).joined(separator: ", ")
            enumerate = "\(ble.peripheralsSeen) peripherals, \(ble.diveComputers.count) dive computers" + (names.isEmpty ? "" : ": \(names)")
        } else {
            enumerate = "no scan"
        }
        let error = ble.state == "poweredOn" ? (ble.note ?? "-") : "state \(ble.state)" + (ble.note.map { ", \($0)" } ?? "")
        out.append(matrix("BLE scan, 10 s", "BLE", entitlement(model, "device.bluetooth"), enumerate, "-", "-", ble.started ? error : "-"))
    }

    @MainActor
    private static func garminRow(_ model: ProbeModel, into out: inout [String]) {
        let entitlement = garminEntitlement(model)
        if let garmin = model.garmin {
            let read = garmin.bookmarkResolve.map { $0.outcome == .ok ? "bookmark resolve ok" : "bookmark resolve FAILED" } ?? "-"
            let resolved = garmin.resolvedListing.map { ", \($0.fitCount) .fit after resolve" } ?? ""
            let error = [garmin.bookmarkCreate, garmin.bookmarkResolve].compactMap { $0 }.firstFailure?.detail ?? garmin.listing.error ?? "-"
            out.append(matrix("Garmin volume", "mass storage", entitlement, garmin.listing.summary,
                              garmin.bookmarkCreate.outcome == .ok ? "bookmark create ok" : "bookmark create FAILED",
                              read + resolved, error))
        } else if let saved = model.savedBookmarkResolve {
            out.append(matrix("Garmin volume (saved bookmark)", "mass storage", entitlement, saved.listing?.summary ?? "-",
                              "-", saved.step.outcome == .ok ? "bookmark resolve ok" : "bookmark resolve FAILED",
                              saved.step.outcome == .ok ? "-" : saved.step.detail))
        } else {
            out.append(matrix("Garmin volume", "mass storage", entitlement, "not run", "-", "-", "-"))
        }
    }

    @MainActor
    private static func details(_ model: ProbeModel, into out: inout [String]) {
        out += ["", "## Serial ports", ""]
        for port in model.serial.ports {
            let usb = port.hasUSBParent
                ? ", USB \(ProbeText.vidPid(port.vendorID, port.productID)) \(port.usbProduct ?? "?"), serial \(port.usbSerial == nil ? "none" : "present")"
                : ""
            out.append(scrub("- `\(port.calloutPath)` \(port.kind.rawValue)\(usb); providers: \(port.ancestry.joined(separator: " < "))", for: port))
            for step in model.serialResults[port.id]?.steps ?? [] { out.append("  - \(step.line)") }
            if let identify = model.serialIdentify[port.id] {
                out.append("  - identify as \(identify.target.title):")
                for step in identify.steps { out.append("    - \(step.line)") }
            }
        }
        out += ["", "## Known cable PIDs vs built-in drivers", ""]
        for table in model.builtInDrivers { out.append("- \(table.summary)") }
        for entry in model.cableCoverage { out.append("- \(entry.summary)") }
        out += ["", "## HID devices", ""]
        for device in model.hidDevices {
            out.append("- \(device.displayName), \(device.transport ?? "?"), \(device.usageSummary), \(device.reportSummary)")
            for result in model.hidResults[device.id] ?? [] {
                let kind = result.identify.map { "identify (\($0.rawValue))" } ?? "listen"
                out.append("  - \(result.mode.rawValue) \(kind): " + result.steps.map(\.line).joined(separator: "; "))
            }
        }
        out += ["", "## USB devices (\(model.usb.className))", ""]
        for device in model.usb.devices {
            let callouts = device.calloutPaths.isEmpty ? "" : ", BSD \(device.calloutPaths.joined(separator: " "))"
            out.append("- \(device.displayName)\(callouts); " + device.driverLines.joined(separator: "; "))
            for step in model.usbResults[device.id] ?? [] { out.append("  - \(step.line)") }
            if let second = model.usbSecondRuns[device.id] {
                out.append("  - second run (configured):")
                for step in second { out.append("    - \(step.line)") }
            }
        }
        out += ["", "## Events (newest first)", ""]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        for event in model.events.prefix(40) {
            out.append("- \(formatter.string(from: event.date)) \(event.text)")
        }
    }

    private static func matrix(_ cells: String...) -> String {
        "| " + cells.map(cell).joined(separator: " | ") + " |"
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func short(_ keys: [String]) -> String {
        keys.map { $0.replacingOccurrences(of: "com.apple.security.", with: "") }.joined(separator: ", ")
    }

    @MainActor
    private static func entitlement(_ model: ProbeModel, _ shortKeys: String...) -> String {
        shortKeys.map { key in
            model.environment?.granted(key) == false ? "\(key) (MISSING)" : key
        }.joined(separator: ", ")
    }

    // A read-only control run swaps the user-selected entitlement; name the one that was actually in force.
    @MainActor
    private static func garminEntitlement(_ model: ProbeModel) -> String {
        let readOnly = model.environment?.extraEntitlements.contains("com.apple.security.files.user-selected.read-only") == true
        let userSelected = model.environment?.granted("files.user-selected.read-write") == false && readOnly
            ? "files.user-selected.read-only"
            : entitlement(model, "files.user-selected.read-write")
        return userSelected + ", " + entitlement(model, "files.bookmarks.app-scope")
    }

    // Short serials identify nothing and would over-match ordinary text.
    private static let minimumSerialLength = 4

    private static func scrubPort(_ port: SerialPort) -> String {
        scrub(port.calloutPath, for: port)
    }

    // FTDI and usbmodem callout names embed the chip serial; SPP names come from the paired device's name.
    private static func scrub(_ text: String, for port: SerialPort) -> String {
        var out = text
        if let serial = port.usbSerial, serial.count >= minimumSerialLength {
            out = out.replacingOccurrences(of: serial, with: "<serial>")
        }
        if port.kind == .bluetoothSPP {
            out = out.replacingOccurrences(of: port.baseName, with: scrubName(port.baseName))
        }
        return out
    }

    private static func name(_ port: SerialPort) -> String {
        port.kind == .bluetoothSPP ? "Bluetooth SPP \(scrubName(port.baseName))" : port.displayName
    }

    /// Last pass over the whole report, so events and registry names about long-gone ports are covered too.
    @MainActor
    private static func scrub(_ text: String, _ model: ProbeModel) -> String {
        var out = text.replacingOccurrences(of: realHome, with: "~")
        let serials = model.seenUSBSerials.filter { $0.count >= minimumSerialLength }.sorted { $0.count > $1.count }
        for serial in serials { out = out.replacingOccurrences(of: serial, with: "<serial>") }
        for name in model.seenSPPNames { out = out.replacingOccurrences(of: name, with: scrubName(name)) }
        return out
    }

    // NSHomeDirectory() is the container inside the sandbox; the passwd entry is the real home.
    private static let realHome: String = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()

    // BLE and SPP names often carry the device serial, e.g. Pelagic "FH020399".
    private static func scrubName(_ name: String) -> String {
        var out = ""
        var token = ""
        func flush() {
            out += token.filter(\.isNumber).count > 2 ? "#" : token
            token = ""
        }
        for character in name {
            if character.isLetter || character.isNumber {
                token.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }
}
#endif
