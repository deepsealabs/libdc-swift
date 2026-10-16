#if os(macOS)
import Foundation
import Security
import Clibdivecomputer

struct EntitlementState: Hashable {
    let key: String
    let granted: Bool
}

struct EnvironmentInfo: Hashable {
    let osVersion: String
    let hardwareModel: String
    let cpu: String
    let binaryArch: String
    let translated: Bool
    let appleSilicon: Bool
    let sandboxed: Bool
    // A shell launch makes the terminal TCC's responsible process, so its grants stand in for the app's.
    let launchedByLaunchd: Bool
    let containerPath: String
    let entitlements: [EntitlementState]
    let extraEntitlements: [String]
    let libdcVersion: String
    let appVersion: String
    let probeCommit: String

    func granted(_ shortKey: String) -> Bool? {
        entitlements.first { $0.key == "com.apple.security." + shortKey }?.granted
    }

    var hardwareSummary: String {
        "\(hardwareModel), \(appleSilicon ? "Apple silicon" : "Intel"), \(cpu)"
    }

    var archSummary: String {
        translated ? "\(binaryArch) under Rosetta" : "\(binaryArch) native"
    }
}

enum EnvironmentProbe {
    static let entitlementKeys = [
        "com.apple.security.app-sandbox",
        "com.apple.security.device.serial",
        "com.apple.security.device.usb",
        "com.apple.security.device.bluetooth",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.files.bookmarks.app-scope"
    ]

    // Outside the L0 set; any of these being present changes what a run proves.
    static let extraEntitlementKeys = [
        "com.apple.security.files.user-selected.read-only",
        "com.apple.security.get-task-allow",
        "com.apple.security.network.client"
    ]

    static func collect() -> EnvironmentInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return EnvironmentInfo(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model") ?? "?",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "?",
            binaryArch: binaryArch,
            translated: sysctlInt("sysctl.proc_translated") == 1,
            appleSilicon: sysctlInt("hw.optional.arm64") == 1,
            sandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            launchedByLaunchd: getppid() == 1,
            containerPath: NSHomeDirectory(),
            entitlements: entitlementKeys.map { EntitlementState(key: $0, granted: entitled($0)) },
            extraEntitlements: extraEntitlementKeys.filter(entitled),
            libdcVersion: String(cString: dc_version(nil)),
            appVersion: "\(version) (\(build))",
            probeCommit: info["ProbeGitCommit"] as? String ?? "unknown"
        )
    }

    private static var binaryArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    // Reads what the kernel granted the running process, not what the file on disk claims.
    private static func entitled(_ key: String) -> Bool {
        let value = SecTaskCreateFromSelf(kCFAllocatorDefault).flatMap { SecTaskCopyValueForEntitlement($0, key as CFString, nil) }
        return (value as? Bool) == true
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
#endif
