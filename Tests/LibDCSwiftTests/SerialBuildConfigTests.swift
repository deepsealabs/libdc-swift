import XCTest
import Clibdivecomputer
import LibDCBridge

/// Platform C defines, seen through `serial_posix.c` on a pty (no real line speed; that needs a cable).
final class SerialBuildConfigTests: XCTestCase {

    // 460800 has no Bxxx constant on Apple platforms, so it takes the custom-rate branch.
    private let nonStandardBaud: UInt32 = 460_800

    // DC_IOCTL_SERIAL_SET_LATENCY is a function-like macro, which Swift can't import.
    private let setLatencyRequest: UInt32 =
        (2 << 30) | (UInt32(MemoryLayout<CUnsignedInt>.size) << 16) | (UInt32(UInt8(ascii: "s")) << 8)

    private struct Pty {
        let master: Int32
        let context: OpaquePointer
        let stream: OpaquePointer
    }

    private struct SerialOpenFailed: Error {
        let path: String
        let status: Int32
    }

    private func openPty() throws -> Pty {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { Darwin.close(master) }
            throw XCTSkip("No pseudo-terminal available here (errno \(errno))")
        }
        let path = String(cString: name)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        var stream: OpaquePointer?
        let status = dc_serial_open(&stream, context, path)
        guard status == DC_STATUS_SUCCESS, let context, let stream else {
            if let context { dc_context_free(context) }
            Darwin.close(master)
            throw SerialOpenFailed(path: path, status: status.rawValue)
        }
        return Pty(master: master, context: context, stream: stream)
    }

    private func close(_ pty: Pty) {
        dc_iostream_close(pty.stream)
        dc_context_free(pty.context)
        Darwin.close(pty.master)
    }

    private func configure(_ pty: Pty, baud: UInt32) -> dc_status_t {
        dc_iostream_configure(pty.stream, baud, 8, DC_PARITY_NONE, DC_STOPBITS_ONE, DC_FLOWCONTROL_NONE)
    }

    func testCustomBaudProbeMatchesPlatform() {
        #if os(macOS)
        XCTAssertTrue(libdc_has_custom_baud())
        #else
        XCTAssertFalse(libdc_has_custom_baud())
        #endif
    }

    func testNonStandardBaudFollowsTheProbe() throws {
        let pty = try openPty()
        defer { close(pty) }

        let status = configure(pty, baud: nonStandardBaud)
        if libdc_has_custom_baud() {
            // The ioctl itself fails on a pty; what matters is that the driver tried it.
            XCTAssertNotEqual(status, DC_STATUS_UNSUPPORTED)
        } else {
            XCTAssertEqual(status, DC_STATUS_UNSUPPORTED)
        }
    }

    func testLatencyIoctlFollowsTheProbe() throws {
        let pty = try openPty()
        defer { close(pty) }

        var milliseconds: CUnsignedInt = 0
        let status = dc_iostream_ioctl(pty.stream, setLatencyRequest, &milliseconds, MemoryLayout<CUnsignedInt>.size)
        if libdc_has_custom_baud() {
            // IOSSDATALAT comes from the same header; a pty rejects it, so an error means it was sent.
            XCTAssertNotEqual(status, DC_STATUS_SUCCESS)
            XCTAssertNotEqual(status, DC_STATUS_UNSUPPORTED)
        } else {
            XCTAssertEqual(status, DC_STATUS_SUCCESS)
        }
    }

    func testStandardBaudRoundTrip() throws {
        let pty = try openPty()
        defer { close(pty) }

        XCTAssertEqual(configure(pty, baud: 9600), DC_STATUS_SUCCESS)
        XCTAssertEqual(dc_iostream_set_timeout(pty.stream, 1000), DC_STATUS_SUCCESS)

        let outbound: [UInt8] = [0x55, 0x00, 0x7E, 0xFF]
        // The driver's write ends in tcdrain, which on a pty waits until the master has read it.
        let received = ByteBox(count: outbound.count)
        let drained = DispatchSemaphore(value: 0)
        let master = pty.master
        DispatchQueue.global().async {
            received.count = Self.readFully(master, into: &received.bytes)
            drained.signal()
        }
        var written = 0
        XCTAssertEqual(dc_iostream_write(pty.stream, outbound, outbound.count, &written), DC_STATUS_SUCCESS)
        XCTAssertEqual(written, outbound.count)
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(received.count, outbound.count)
        XCTAssertEqual(received.bytes, outbound)

        let inbound: [UInt8] = [0xA5, 0x0D, 0x0A, 0x11]
        XCTAssertEqual(Darwin.write(pty.master, inbound, inbound.count), inbound.count)
        var buffer = [UInt8](repeating: 0, count: inbound.count)
        var actual = 0
        XCTAssertEqual(dc_iostream_read(pty.stream, &buffer, buffer.count, &actual), DC_STATUS_SUCCESS)
        XCTAssertEqual(actual, inbound.count)
        XCTAssertEqual(buffer, inbound)
    }

    func testReadTimeoutKeepsPartialData() throws {
        let pty = try openPty()
        defer { close(pty) }

        XCTAssertEqual(configure(pty, baud: 9600), DC_STATUS_SUCCESS)
        let timeoutMs: Int32 = 200
        XCTAssertEqual(dc_iostream_set_timeout(pty.stream, timeoutMs), DC_STATUS_SUCCESS)

        let partial: [UInt8] = [0x01, 0x02]
        XCTAssertEqual(Darwin.write(pty.master, partial, partial.count), partial.count)

        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        let start = DispatchTime.now()
        let status = dc_iostream_read(pty.stream, &buffer, buffer.count, &actual)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        XCTAssertEqual(status, DC_STATUS_TIMEOUT)
        XCTAssertEqual(actual, partial.count)
        XCTAssertEqual(Array(buffer.prefix(actual)), partial)
        XCTAssertGreaterThanOrEqual(elapsedMs, Double(timeoutMs) - 5)
        // Wide upper bound: proves the timeout fires without flaking under hosted-VM scheduling jitter.
        XCTAssertLessThan(elapsedMs, Double(timeoutMs) * 2.5)
    }

    private final class ByteBox: @unchecked Sendable {
        var bytes: [UInt8]
        var count = 0
        init(count: Int) { bytes = [UInt8](repeating: 0, count: count) }
    }

    private static func readFully(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
        var total = 0
        let deadline = Date().addingTimeInterval(1)
        while total < buffer.count, Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + total, raw.count - total)
            }
            if n > 0 {
                total += n
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                usleep(1000)
            } else {
                break
            }
        }
        return total
    }
}
