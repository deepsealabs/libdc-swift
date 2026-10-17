#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// The far end of a serial link: what the host wrote comes in, what the computer says goes out.
protocol FakeSerialDevice: AnyObject {
    func hostWrote(_ bytes: UnsafeRawBufferPointer)
    /// Copies up to `size` bytes of the computer's reply; 0 when it has nothing to say.
    func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int
}

extension SessionClockTests.FakeSensus: FakeSerialDevice {}

/// Reads everything the host sends and never answers.
final class SilentDevice: FakeSerialDevice {
    private let lock = NSLock()
    private var count = 0

    var bytesReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func hostWrote(_ bytes: UnsafeRawBufferPointer) {
        lock.lock(); defer { lock.unlock() }
        count += bytes.count
    }

    func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int { 0 }
}

/// An OSTC 3 that takes a download's INIT and then goes silent, as one lifted off its cable mid-download does.
final class FakeOSTC3: FakeSerialDevice {
    static let initCommand: UInt8 = 0xBB
    static let ready: UInt8 = 0x4D
    static let exitCommand: UInt8 = 0xFF

    private let lock = NSLock()
    private var inbox: [UInt8] = []
    private var outbox: [UInt8] = []
    private var answered = false

    var received: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return inbox
    }

    func hostWrote(_ bytes: UnsafeRawBufferPointer) {
        lock.lock(); defer { lock.unlock() }
        inbox += bytes
        guard !answered, bytes.contains(Self.initCommand) else { return }
        answered = true
        outbox = [Self.initCommand, Self.ready]
    }

    func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = min(size, outbox.count)
        guard n > 0 else { return 0 }
        outbox.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress!, byteCount: n) }
        outbox.removeFirst(n)
        return n
    }
}

/// A pseudo-terminal whose slave is the port under test and whose master a fake computer answers on.
final class PtyLink {
    let master: Int32
    /// The slave device a session opens, standing in for /dev/cu.*.
    let path: String
    private let stop = Flag()
    private var pump: Thread?
    private let pumpDone = DispatchSemaphore(value: 0)

    init() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { Darwin.close(master) }
            throw XCTSkip("No pseudo-terminal available here (errno \(errno))")
        }
        self.master = master
        path = String(cString: name)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        // The master reports no line settings until the slave has been opened once.
        let slave = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if slave >= 0 { Darwin.close(slave) }
    }

    /// Pumps bytes between the port and `device` on a thread until `close()`.
    func attach(_ device: FakeSerialDevice) {
        let master = master
        let stop = stop
        let done = pumpDone
        let thread = Thread {
            var inbox = [UInt8](repeating: 0, count: 4096)
            var outbox: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !stop.value {
                let received = Darwin.read(master, &inbox, inbox.count)
                if received > 0 {
                    inbox.withUnsafeBytes { device.hostWrote(UnsafeRawBufferPointer(rebasing: $0[0..<received])) }
                }
                if outbox.isEmpty {
                    let count = chunk.withUnsafeMutableBytes { device.hostRead(into: $0.baseAddress!, size: $0.count) }
                    outbox = Array(chunk.prefix(count))
                }
                var sent = 0
                if !outbox.isEmpty {
                    sent = Darwin.write(master, outbox, outbox.count)
                    if sent > 0 { outbox.removeFirst(sent) }
                }
                if received <= 0, sent <= 0 { usleep(500) }
            }
            done.signal()
        }
        pump = thread
        thread.start()
    }

    /// The port's line settings, as the slave sees them.
    var termios: Darwin.termios {
        var settings = Darwin.termios()
        XCTAssertEqual(tcgetattr(master, &settings), 0)
        return settings
    }

    func send(_ bytes: [UInt8]) {
        XCTAssertEqual(Darwin.write(master, bytes, bytes.count), bytes.count)
    }

    func close() {
        guard !stop.value else { return }
        stop.value = true
        if pump != nil { _ = pumpDone.wait(timeout: .now() + 2) }
        Darwin.close(master)
    }

    deinit { close() }
}

/// A `RegistrySource` serving fixtures, whose changes the test fires.
final class FakeRegistrySource: RegistrySource {
    private let lock = NSLock()
    private var current: RegistrySnapshot
    private var handler: ((RegistryChange) -> Void)?
    private var queue: DispatchQueue?
    var canWatch = true
    private(set) var snapshotCount = 0

    init(_ snapshot: RegistrySnapshot = RegistrySnapshot()) {
        current = snapshot
    }

    var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return handler != nil
    }

    func snapshot() -> RegistrySnapshot {
        lock.lock(); defer { lock.unlock() }
        snapshotCount += 1
        return current
    }

    func startWatching(on queue: DispatchQueue, changed: @escaping (RegistryChange) -> Void) -> Bool {
        guard canWatch else { return false }
        lock.lock(); defer { lock.unlock() }
        self.queue = queue
        handler = changed
        return true
    }

    func stopWatching() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    /// Sets what the next read sees, without a notification.
    func set(_ snapshot: RegistrySnapshot) {
        lock.lock(); defer { lock.unlock() }
        current = snapshot
    }

    /// Sets the registry and fires `change` on the discovery's queue, as IOKit would.
    func emit(_ change: RegistryChange, _ snapshot: RegistrySnapshot) {
        lock.lock()
        current = snapshot
        let handler = handler
        let queue = queue
        lock.unlock()
        queue?.async { handler?(change) }
    }
}

extension termios {
    var outputSpeed: speed_t {
        var settings = self
        return cfgetospeed(&settings)
    }
}

final class OpenBox: @unchecked Sendable {
    var result: Result<DiveComputerSession, Error>?
}

/// An open that never returned: a failure, so a hang can't pass as a skip.
struct CableOpenTimedOut: Error {
    let seconds: TimeInterval
}

enum CableFixtures {
    static let ftdiOSTC = RegistrySnapshot.USBDevice(registryID: 0x100, vendorID: 0x0403, productID: 0x6001,
                                                     serialNumber: "TESTADAPTER", productName: "FT232R USB UART")

    /// A USB serial port at `path` behind `device`.
    static func usbPort(_ path: String, _ device: RegistrySnapshot.USBDevice = ftdiOSTC) -> RegistrySnapshot.Port {
        RegistrySnapshot.Port(calloutPath: path, baseName: "usbserial-TESTADAPTER", parent: .usb(device))
    }

    /// The endpoint a discovery would list for a pty standing in for an FTDI adapter.
    static func endpoint(_ link: PtyLink, usbSerial: String? = "TESTADAPTER") -> CableEndpoint {
        CableEndpoint.serialPort(path: link.path, vendorID: 0x0403, productID: 0x6001, usbSerialNumber: usbSerial)
    }

    static func model(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> DCModel {
        try XCTUnwrap(DeviceCatalog.models(for: .serial).first { $0.name == name }, "no serial model \(name)", file: file, line: line)
    }
}

extension XCTestCase {
    func isolatedDefaults(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.cable.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// The async open, waited for here, with isolated storage and its own lease unless given one; `hidDevice` and `usbDevice` stand in for IOKit's.
    func openCable(_ endpoint: CableEndpoint, model: DCModel, discovery: CableDiscovering? = nil,
                   recorder: DCStreamRecorder? = nil, lease: DiveComputerSessionLease = DiveComputerSessionLease(),
                   deviceStorage: DeviceStorage? = nil, hidDevice: HIDDeviceFactory? = nil,
                   usbDevice: USBDeviceFactory? = nil, timeout: TimeInterval = 10) throws -> DiveComputerSession {
        let box = OpenBox()
        let request = CableOpenRequest(endpoint: endpoint, model: model, discovery: discovery, recorder: recorder,
                                       deviceStorage: deviceStorage ?? DeviceStorage(userDefaults: isolatedDefaults("dev")),
                                       lease: lease, cancellation: CableOpenCancellation(),
                                       hidDevice: hidDevice ?? IOKitHIDDevice.make,
                                       usbDevice: usbDevice ?? IOKitUSBDevice.make)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await DiveComputerSession.open(
                    request.endpoint, model: request.model, discovery: request.discovery, recorder: request.recorder,
                    deviceStorage: request.deviceStorage, lease: request.lease, hidDevice: request.hidDevice,
                    usbDevice: request.usbDevice))
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let result = box.result else {
            XCTFail("open did not return within \(timeout) s")
            throw CableOpenTimedOut(seconds: timeout)
        }
        let session = try result.get()
        addTeardownBlock { session.close() }
        return session
    }

    /// Polls `condition` until it holds or `timeout` passes.
    func waitFor(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { usleep(5_000) }
        return condition()
    }

    /// The `CableError` an open throws, failing the test if it opens or throws something else.
    func cableOpenError(_ endpoint: CableEndpoint, model: DCModel, lease: DiveComputerSessionLease = DiveComputerSessionLease(),
                        hidDevice: HIDDeviceFactory? = nil, usbDevice: USBDeviceFactory? = nil,
                        file: StaticString = #filePath, line: UInt = #line) -> CableError? {
        do {
            _ = try openCable(endpoint, model: model, lease: lease, hidDevice: hidDevice, usbDevice: usbDevice)
            XCTFail("the open succeeded", file: file, line: line)
            return nil
        } catch let error as CableError {
            return error
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    /// Replays `recording` through `ScriptedStream` in a session keyed as a cable's would be.
    func replayDownload(_ recording: DCRecording, displayName: String, viewModel: DiveDataViewModel? = nil) throws
        -> (result: DiveDownloadResult, dives: [DiveData], script: ScriptedStream) {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        let script = ScriptedStream(recording: recording)
        let stream = try DCCustomStream.open(backend: script, transport: script.transport, context: context)
        let locator: DiveComputerLocator
        switch recording.transport {
        case DC_TRANSPORT_USBHID: locator = .usbHID(vid: 0x1493, pid: 0x0030, registryID: 0x1)
        case DC_TRANSPORT_USB: locator = .usb(vid: 0x0471, pid: 0x0888, registryID: 0x1)
        default: locator = .serial(path: "/dev/cu.usbserial-REPLAY", usbSerial: nil, vid: 0x0403, pid: 0x6001)
        }
        let session = try DiveComputerSession.open(
            iostream: stream, context: try XCTUnwrap(context), family: try XCTUnwrap(recording.family),
            model: try XCTUnwrap(recording.model), displayName: displayName,
            storageKey: DCRecording.name(of: recording.transport) + ":replay",
            locator: locator,
            deviceStorage: DeviceStorage(userDefaults: isolatedDefaults("dev")), lease: DiveComputerSessionLease())
        defer { session.close() }
        let (result, dives) = downloadToEnd(session, viewModel: viewModel)
        return (try XCTUnwrap(result), dives, script)
    }

    /// Runs a session download to its end and lets the view model's last main-queue turns land.
    func downloadToEnd(_ session: DiveComputerSession, viewModel: DiveDataViewModel? = nil,
                       timeout: TimeInterval = 15) -> (result: DiveDownloadResult?, dives: [DiveData]) {
        let viewModel = viewModel ?? DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedDefaults("fp")))
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result = $0; done.fulfill() }
        wait(for: [done], timeout: timeout)
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        return (result, viewModel.dives)
    }
}
#endif
