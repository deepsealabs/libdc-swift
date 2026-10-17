#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Cable sessions over a real `dc_serial_open` port: a pseudo-terminal whose far end a fake computer answers.
final class SerialCableSessionTests: XCTestCase {

    private var links: [PtyLink] = []

    override func tearDown() {
        links.forEach { $0.close() }
        links.removeAll()
        super.tearDown()
    }

    private func link(_ device: FakeSerialDevice? = nil) throws -> PtyLink {
        let link = try PtyLink()
        links.append(link)
        if let device { link.attach(device) }
        return link
    }

    private func sensus(serial: UInt16 = 0x1234, devtime: UInt32 = 5_000_000) -> SessionClockTests.FakeSensus {
        SessionClockTests.FakeSensus(serial: serial, devtime: devtime, dives: [
            (100, SessionClockTests.dive(timestamp: devtime - 86_400)),
            (400, SessionClockTests.dive(timestamp: devtime - 3_600)),
        ])
    }

    // MARK: - Downloads

    func testASensusDownloadsOverARealSerialPort() throws {
        let link = try link(sensus())
        let endpoint = CableFixtures.endpoint(link)
        let session = try openCable(endpoint, model: CableFixtures.model("Reefnet Sensus"))
        XCTAssertEqual(session.transport, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(session.locator, endpoint.locator)
        XCTAssertEqual(session.displayName, "Reefnet Sensus")
        XCTAssertEqual(session.storageKey, "serial:TESTADAPTER")
        XCTAssertEqual(session.fingerprintStandIn, "adapter:0403:6001:TESTADAPTER")

        let before = Date().timeIntervalSince1970.rounded(.down)
        let (result, dives) = downloadToEnd(session)
        let after = Date().timeIntervalSince1970.rounded(.up)
        let download = try XCTUnwrap(result)
        XCTAssertEqual(download.outcome, .completed)
        XCTAssertEqual(download.divesDownloaded, 2)
        XCTAssertNil(CableError(download: download, session: session))
        // Dated from the Sensus clock through DC_EVENT_CLOCK, as over any other stream.
        let dates = dives.map(\.datetime.timeIntervalSince1970).sorted()
        XCTAssertEqual(dates.count, 2)
        XCTAssertGreaterThanOrEqual(dates[0], before - 86_400)
        XCTAssertLessThanOrEqual(dates[0], after - 86_400)
        XCTAssertGreaterThanOrEqual(dates[1], before - 3_600)
        XCTAssertLessThanOrEqual(dates[1], after - 3_600)
        let identity = try XCTUnwrap(download.identity)
        XCTAssertEqual(identity.transport, .serial)
        XCTAssertEqual(identity.deviceKey, "sn:00001234")
        XCTAssertEqual(download.fingerprintCommit?.serial, "00001234")
        XCTAssertEqual(download.fingerprintCommit?.deviceType, "Reefnet Sensus")
    }

    func testTheOpenSetsTheLineTheDriverAsksFor() throws {
        let link = try link(SilentDevice())
        let initial = link.termios
        let session = try openCable(CableFixtures.endpoint(link), model: CableFixtures.model("Heinrichs Weikamp OSTC Mk2"))
        let line = link.termios
        // hw_ostc_device_open: 115200 8N1, no flow control, raw.
        XCTAssertEqual(line.outputSpeed, speed_t(B115200))
        XCTAssertEqual(line.c_cflag & tcflag_t(CSIZE), tcflag_t(CS8))
        XCTAssertEqual(line.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertEqual(line.c_cflag & tcflag_t(CSTOPB), 0)
        XCTAssertEqual(line.c_cflag & tcflag_t(CRTSCTS), 0)
        XCTAssertNotEqual(line.c_cflag & tcflag_t(CLOCAL | CREAD), 0)
        XCTAssertEqual(line.c_lflag & tcflag_t(ICANON | ECHO), 0)
        session.close()
        // dc_serial_close puts back what the port had.
        XCTAssertEqual(link.termios.outputSpeed, initial.outputSpeed)
        XCTAssertEqual(link.termios.c_lflag, initial.c_lflag)
    }

    func testReadsThroughTheSessionKeepTheTimeoutAndThePartialCount() throws {
        let link = try link()
        let session = try openCable(CableFixtures.endpoint(link), model: CableFixtures.model("Heinrichs Weikamp OSTC Mk2"))
        let iostream = try XCTUnwrap(session.devicePtr.pointee.iostream)
        XCTAssertEqual(dc_iostream_get_transport(iostream), DC_TRANSPORT_SERIAL)
        XCTAssertEqual(dc_iostream_set_timeout(iostream, 200), DC_STATUS_SUCCESS)
        link.send([0x01, 0x02])
        var buffer = [UInt8](repeating: 0, count: 4)
        var actual = 0
        let start = DispatchTime.now()
        XCTAssertEqual(dc_iostream_read(iostream, &buffer, buffer.count, &actual), DC_STATUS_TIMEOUT)
        let elapsed = milliseconds(since: start)
        XCTAssertEqual(actual, 2)
        XCTAssertEqual(Array(buffer.prefix(actual)), [0x01, 0x02])
        XCTAssertGreaterThanOrEqual(elapsed, 190)
        // Wide upper bound for hosted-runner jitter; the point is that the timeout fires.
        XCTAssertLessThan(elapsed, 600)
    }

    func testASilentComputerIsNoResponseAfterTheDriversTimeout() throws {
        let silent = SilentDevice()
        let link = try link(silent)
        let session = try openCable(CableFixtures.endpoint(link), model: CableFixtures.model("Reefnet Sensus"))
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        let elapsed = milliseconds(since: start)
        XCTAssertEqual(download.outcome, .failed(DC_STATUS_TIMEOUT))
        XCTAssertGreaterThan(silent.bytesReceived, 0, "the handshake went out")
        // reefnet_sensus sets 3000 ms.
        XCTAssertGreaterThanOrEqual(elapsed, 2_900)
        XCTAssertLessThan(elapsed, 9_000)
        let error = try XCTUnwrap(CableError(download: download, session: session))
        XCTAssertEqual(error, .noResponse(.reefnetSensus))
        XCTAssertTrue(error.message.contains("Sensus"), error.message)
    }

    func testCancellingEndsABlockedReadPromptly() throws {
        let link = try link(SilentDevice())
        let session = try openCable(CableFixtures.endpoint(link), model: CableFixtures.model("Reefnet Sensus"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { session.cancel() }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertEqual(download.outcome, .cancelled)
        XCTAssertLessThan(milliseconds(since: start), 1_500, "well inside the driver's 3 s timeout")
        XCTAssertEqual(CableError(download: download, session: session), .cancelled)
        XCTAssertFalse(session.wasUnplugged)
    }

    func testRemovingTheEndpointCancelsTheDownloadAsAnUnplug() throws {
        let link = try link(SilentDevice())
        let endpoint = CableFixtures.endpoint(link)
        let discovery = StaticCableDiscovery(endpoints: [endpoint])
        let session = try openCable(endpoint, model: CableFixtures.model("Reefnet Sensus"), discovery: discovery)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { discovery.remove(id: endpoint.id) }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertLessThan(milliseconds(since: start), 1_500)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertEqual(download.outcome, .cancelled)
        XCTAssertEqual(CableError(download: download, session: session), .unplugged)
    }

    func testARegistryRemovalCancelsTheSessionOnThatPort() throws {
        let link = try link(SilentDevice())
        let source = FakeRegistrySource(RegistrySnapshot(ports: [CableFixtures.usbPort(link.path)],
                                                         cableDevices: [CableFixtures.ftdiOSTC]))
        let discovery = IOKitCableDiscovery(source: source)
        discovery.start()
        let endpoint = try XCTUnwrap(discovery.endpoints.first)
        XCTAssertEqual(endpoint.calloutPath, link.path)
        let session = try openCable(endpoint, model: CableFixtures.model("Reefnet Sensus"), discovery: discovery)
        XCTAssertEqual(discovery.endpoints.first?.status, .busy)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            // Pulling the cable takes its USB device and its port together.
            source.emit(.removed, RegistrySnapshot())
        }
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertEqual(download.outcome, .cancelled)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertEqual(discovery.endpoints, [])
    }

    func testAnOpenSessionShowsItsPortBusyUntilItCloses() throws {
        let link = try link()
        let endpoint = CableFixtures.endpoint(link)
        let other = CableEndpoint.serialPort(path: "/dev/cu.usbserial-OTHER", vendorID: 0x0403, productID: 0x6001)
        let discovery = StaticCableDiscovery(endpoints: [endpoint, other])
        let session = try openCable(endpoint, model: CableFixtures.model("Heinrichs Weikamp OSTC Mk2"))
        XCTAssertEqual(discovery.endpoints.map(\.status), [.busy, .ready])
        session.close()
        XCTAssertEqual(discovery.endpoints.map(\.status), [.ready, .ready])
    }

    // MARK: - Refusals

    func testAPortTheAppMayNotOpenIsPermissionDenied() throws {
        try XCTSkipIf(getuid() == 0, "root opens anything")
        let link = try link()
        XCTAssertEqual(chmod(link.path, 0), 0)
        defer { chmod(link.path, 0o620) }
        let lease = DiveComputerSessionLease()
        XCTAssertEqual(cableOpenError(CableFixtures.endpoint(link), model: try CableFixtures.model("Reefnet Sensus"), lease: lease),
                       .permissionDenied)
        XCTAssertFalse(lease.isHeld)
    }

    func testAPortThatIsGoneIsNotFound() throws {
        let endpoint = CableEndpoint.serialPort(path: "/dev/cu.libdcswift-no-such-port", vendorID: 0x0403, productID: 0x6001)
        XCTAssertEqual(cableOpenError(endpoint, model: try CableFixtures.model("Reefnet Sensus")), .notFound)
    }

    func testACableWithNoPortIsDriverMissing() throws {
        let endpoint = try XCTUnwrap(RegistrySnapshot(cableDevices: [
            RegistrySnapshot.USBDevice(registryID: 1, vendorID: 0x0403, productID: 0xF460),
        ]).endpoints.first)
        XCTAssertEqual(cableOpenError(endpoint, model: try CableFixtures.model("Oceanic Atom 2.0")), .driverMissing)
    }

    func testOnlySerialEndpointsAndSerialModelsOpen() throws {
        let link = try link()
        let initial = link.termios
        let paired = CableEndpoint(id: link.path, transport: .classicBTSerial, calloutPath: link.path,
                                   candidates: DeviceCatalog.models(for: .classicBTSerial))
        let petrel = try XCTUnwrap(DeviceCatalog.models(for: .classicBTSerial).first)
        XCTAssertEqual(cableOpenError(paired, model: petrel), .unsupportedTransport(.classicBTSerial))
        let bleOnly = try XCTUnwrap(DeviceCatalog.models(for: .ble).first { !$0.transports.contains(.serial) })
        XCTAssertEqual(cableOpenError(CableFixtures.endpoint(link), model: bleOnly), .unsupportedTransport(.serial))
        XCTAssertEqual(link.termios.c_cflag, initial.c_cflag, "the port was never configured")
    }

    func testASecondSessionIsRefusedBeforeThePortOpens() throws {
        let link = try link()
        let initial = link.termios
        let lease = DiveComputerSessionLease()
        XCTAssertTrue(lease.tryAcquire())
        XCTAssertEqual(cableOpenError(CableFixtures.endpoint(link), model: try CableFixtures.model("Heinrichs Weikamp OSTC Mk2"),
                                      lease: lease), .sessionInProgress)
        XCTAssertEqual(link.termios.outputSpeed, initial.outputSpeed)
        XCTAssertTrue(lease.isHeld, "the holder keeps it")
        lease.release()
    }

    func testFailedOpensLeaveTheLeaseFreeAndThePortUnclaimed() throws {
        let link = try link(SilentDevice())
        let lease = DiveComputerSessionLease()
        // Unknown to the descriptor table, so the C open stops before the port.
        let ghost = DCModel(vendor: "Test", product: "Ghost", family: .hwOstc, model: 99, transports: [.serial], canonicalName: "Test Ghost")
        XCTAssertEqual(cableOpenError(CableFixtures.endpoint(link), model: ghost, lease: lease), .protocolError(DC_STATUS_UNSUPPORTED))
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(SerialPortClaims.shared.claimedPaths.contains(link.path))
        // And the next open on the same lease goes through.
        let session = try openCable(CableFixtures.endpoint(link), model: CableFixtures.model("Heinrichs Weikamp OSTC Mk2"), lease: lease)
        XCTAssertTrue(lease.isHeld)
        session.close()
        XCTAssertFalse(lease.isHeld)
    }

    func testCancellingTheOpeningTaskThrowsCancelled() async throws {
        let link = try link(SilentDevice())
        let endpoint = CableFixtures.endpoint(link)
        let model = try CableFixtures.model("Heinrichs Weikamp OSTC Mk2")
        let lease = DiveComputerSessionLease()
        let storage = DeviceStorage(userDefaults: isolatedDefaults("dev"))
        let task = Task { try await DiveComputerSession.open(endpoint, model: model, deviceStorage: storage, lease: lease) }
        task.cancel()
        do {
            let session = try await task.value
            session.close()
            XCTFail("the open succeeded")
        } catch {
            XCTAssertEqual(error as? CableError, .cancelled)
        }
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(SerialPortClaims.shared.claimedPaths.contains(link.path))
    }

    func testCancellingAnOpenBlockedInAHandshakeReadThrowsCancelledPromptly() async throws {
        let silent = SilentDevice()
        let link = try link(silent)
        let endpoint = CableFixtures.endpoint(link)
        let model = try CableFixtures.model("Tecdiving DiveComputer.eu")
        let lease = DiveComputerSessionLease()
        let storage = DeviceStorage(userDefaults: isolatedDefaults("dev"))
        let task = Task { try await DiveComputerSession.open(endpoint, model: model, deviceStorage: storage, lease: lease) }
        // Once INIT is out, dc_device_open waits 1000 ms per try, several times, for the device info.
        let deadline = Date().addingTimeInterval(5)
        while silent.bytesReceived == 0, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThan(silent.bytesReceived, 0, "the handshake went out")
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = DispatchTime.now()
        task.cancel()
        do {
            let session = try await task.value
            session.close()
            XCTFail("the open succeeded")
        } catch {
            XCTAssertEqual(error as? CableError, .cancelled)
        }
        XCTAssertLessThan(milliseconds(since: cancelled), 150)
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(SerialPortClaims.shared.claimedPaths.contains(link.path))
    }

    func testACancelLandingAfterTheOpenClosesTheSessionInsteadOfReturningIt() throws {
        let link = try link()
        let lease = DiveComputerSessionLease()
        let cancellation = CableOpenCancellation()
        let session = try DiveComputerSession.openSerial(
            CableFixtures.endpoint(link), model: CableFixtures.model("Heinrichs Weikamp OSTC Mk2"), discovery: nil, recorder: nil,
            deviceStorage: DeviceStorage(userDefaults: isolatedDefaults("dev")), lease: lease, cancellation: cancellation)
        XCTAssertIdentical(try DiveComputerSession.handOver(session, cancellation: cancellation), session)
        cancellation.cancel()
        XCTAssertThrowsError(try DiveComputerSession.handOver(session, cancellation: cancellation)) {
            XCTAssertEqual($0 as? CableError, .cancelled)
        }
        XCTAssertTrue(session.isClosed)
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(SerialPortClaims.shared.claimedPaths.contains(link.path))
    }

    // MARK: - open_serial_device

    private func newContext() throws -> OpaquePointer {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        return try XCTUnwrap(context)
    }

    private final class WrapProbe {
        var calls = 0
        var inner: OpaquePointer?
        var refuse = false
    }

    private static let probeWrap: libdc_iostream_wrap_t = { _, inner, userdata in
        let probe = Unmanaged<WrapProbe>.fromOpaque(userdata!).takeUnretainedValue()
        probe.calls += 1
        probe.inner = inner
        guard !probe.refuse else {
            dc_iostream_close(inner)
            return nil
        }
        return inner
    }

    private func openDevice(_ path: String?, family: dc_family_t = DC_FAMILY_HW_OSTC, model: UInt32 = 1,
                            probe: WrapProbe?, keep: ((UnsafeMutablePointer<device_data_t>) -> Void)? = nil) throws -> dc_status_t {
        let data = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        data.initialize(to: device_data_t())
        defer {
            libdc_close_device_data(data)
            data.deinitialize(count: 1)
            data.deallocate()
        }
        data.pointee.context = try newContext()
        let status: dc_status_t
        if let probe {
            status = withExtendedLifetime(probe) {
                open_serial_device(data, path, family, model, Self.probeWrap, Unmanaged.passUnretained(probe).toOpaque())
            }
        } else {
            status = open_serial_device(data, path, family, model, nil, nil)
        }
        if status == DC_STATUS_SUCCESS { keep?(data) } else {
            XCTAssertNil(data.pointee.context, "the context is released on failure")
            XCTAssertNil(data.pointee.iostream)
            XCTAssertNil(data.pointee.device)
        }
        return status
    }

    func testOpenSerialDeviceRejectsMissingArguments() throws {
        XCTAssertEqual(open_serial_device(nil, "/dev/null", DC_FAMILY_HW_OSTC, 1, nil, nil), DC_STATUS_INVALIDARGS)
        var empty = device_data_t()
        XCTAssertEqual(open_serial_device(&empty, "/dev/null", DC_FAMILY_HW_OSTC, 1, nil, nil), DC_STATUS_INVALIDARGS)
        let probe = WrapProbe()
        XCTAssertEqual(try openDevice(nil, probe: probe), DC_STATUS_INVALIDARGS)
        XCTAssertEqual(probe.calls, 0)
    }

    func testOpenSerialDeviceResolvesTheModelBeforeThePort() throws {
        let link = try link()
        let initial = link.termios
        let probe = WrapProbe()
        XCTAssertEqual(try openDevice(link.path, model: 99, probe: probe), DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(link.termios.c_cflag, initial.c_cflag)
        // A missing port fails in dc_serial_open, before any wrap.
        XCTAssertEqual(try openDevice("/dev/cu.libdcswift-no-such-port", probe: probe), DC_STATUS_NODEVICE)
        XCTAssertEqual(probe.calls, 0)
    }

    func testOpenSerialDeviceWrapsThePortOnceAndOpensOnTheWrapper() throws {
        let link = try link()
        let probe = WrapProbe()
        var opened: (iostream: OpaquePointer?, model: String?, attemptsTransport: dc_transport_t?) = (nil, nil, nil)
        XCTAssertEqual(try openDevice(link.path, probe: probe) { data in
            opened = (data.pointee.iostream, data.pointee.model.map { String(cString: $0) },
                      data.pointee.iostream.map { dc_iostream_get_transport($0) })
            XCTAssertNotNil(data.pointee.device)
            XCTAssertNotNil(data.pointee.context)
        }, DC_STATUS_SUCCESS)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(opened.iostream, probe.inner)
        XCTAssertEqual(opened.attemptsTransport, DC_TRANSPORT_SERIAL)
        XCTAssertEqual(opened.model, "Heinrichs Weikamp OSTC Mk2")
    }

    func testOpenSerialDeviceWithoutAWrapOpensOnThePort() throws {
        let link = try link()
        XCTAssertEqual(try openDevice(link.path, probe: nil) { data in
            XCTAssertEqual(data.pointee.iostream.map { dc_iostream_get_transport($0) }, DC_TRANSPORT_SERIAL)
            XCTAssertEqual(link.termios.outputSpeed, speed_t(B115200), "configured by hw_ostc_device_open")
        }, DC_STATUS_SUCCESS)
    }

    func testAWrapThatFailsIsNoMemory() throws {
        let link = try link()
        let probe = WrapProbe()
        probe.refuse = true
        XCTAssertEqual(try openDevice(link.path, probe: probe), DC_STATUS_NOMEMORY)
        XCTAssertEqual(probe.calls, 1)
    }

    func testSerialOpensMakeOneAttempt() {
        XCTAssertEqual(LIBDC_SERIAL_OPEN_ATTEMPTS, 1)
    }
}
#endif
