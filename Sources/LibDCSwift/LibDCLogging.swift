import Clibdivecomputer
import LibDCBridge

/// How much of libdivecomputer's own logging a context passes to the console and the host sink (`set_libdc_log_sink`).
public enum LibDCLogLevel: Int, CaseIterable, Sendable {
    case error = 1
    case warning
    case info
    case debug
    case all

    var dcLevel: dc_loglevel_t { dc_loglevel_t(rawValue: UInt32(rawValue)) }
}

public enum LibDCLogging {
    /// The level each libdivecomputer context gets as it's set up: a Bluetooth connect, a cable open, a
    /// `DiveComputerSession` opened on a stream, or `configure(_:)`. A context already set up keeps its own, so a
    /// change applies from the next connection. `.warning` by default.
    ///
    /// Below `.debug` the host sink gets the lines at or above the level. At `.debug` and `.all` ("full logging") it gets
    /// every line: the iostream `Read:`/`Write:` hexdumps (INFO) and the drivers' own DEBUG dumps. That's the
    /// `DC_LOGLEVEL_ALL` log libdivecomputer's maintainers ask for, about 3 MB per Suunto Nautic dive (see
    /// `BoundedLogBuffer`). A cable's port under its tap logs at this level too once it's `.debug` or `.all`.
    public static var level: LibDCLogLevel {
        get { LibDCLogLevel(rawValue: Int(libdc_log_level().rawValue)) ?? .warning }
        set { set_libdc_log_level(newValue.dcLevel) }
    }

    /// Routes a context the host created through the bridge's logging at `level`, as a connect does for its own.
    public static func configure(_ context: OpaquePointer) {
        libdc_configure_context_logging(context)
    }

    /// The vendored libdivecomputer's version, e.g. "0.10.0-devel".
    public static var libdivecomputerVersion: String {
        dc_version(nil).map { String(cString: $0) } ?? "?"
    }
}
