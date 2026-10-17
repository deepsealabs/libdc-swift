#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// How errno, libdivecomputer statuses and download outcomes become `CableError`s, and what they say.
final class CableErrorTests: XCTestCase {

    func testOpenErrnoSplitsBusyFromNotPermitted() {
        XCTAssertEqual(CableError(openErrno: EBUSY), .busy)
        XCTAssertEqual(CableError(openErrno: EPERM), .permissionDenied, "a sandbox without device.serial")
        XCTAssertEqual(CableError(openErrno: EACCES), .permissionDenied)
        XCTAssertEqual(CableError(openErrno: ENOENT), .notFound)
        XCTAssertEqual(CableError(openErrno: ENXIO), .notFound)
        XCTAssertEqual(CableError(openErrno: ENODEV), .notFound)
        XCTAssertEqual(CableError(openErrno: EIO), .portError(errno: EIO))
    }

    func testThePreflightReportsErrno() throws {
        XCTAssertEqual(SerialPortPreflight.check("/dev/cu.libdcswift-no-such-port"), .notFound)
        try XCTSkipIf(getuid() == 0, "root opens anything")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("libdcswift-preflight-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0]))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SerialPortPreflight.check(url.path), .permissionDenied)
        // A file that opens isn't a tty, and TIOCEXCL's ENOTTY is left for dc_serial_open to report.
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertNil(SerialPortPreflight.check(url.path))
    }

    func testAPortOpenFailureAfterThePreflight() {
        XCTAssertEqual(CableError.portOpenFailed(DC_STATUS_NOACCESS), .busy)
        XCTAssertEqual(CableError.portOpenFailed(DC_STATUS_NODEVICE), .notFound)
        XCTAssertEqual(CableError.portOpenFailed(DC_STATUS_CANCELLED), .cancelled)
        XCTAssertEqual(CableError.portOpenFailed(DC_STATUS_IO), .protocolError(DC_STATUS_IO))
    }

    func testADeviceFailureOnAnOpenPort() {
        XCTAssertEqual(CableError.deviceFailed(DC_STATUS_TIMEOUT, family: .suuntoD9, portPresent: true), .noResponse(.suuntoD9))
        XCTAssertEqual(CableError.deviceFailed(DC_STATUS_CANCELLED, family: .suuntoD9, portPresent: true), .cancelled)
        XCTAssertEqual(CableError.deviceFailed(DC_STATUS_IO, family: .suuntoD9, portPresent: false), .unplugged)
        XCTAssertEqual(CableError.deviceFailed(DC_STATUS_NODEVICE, family: .suuntoD9, portPresent: false), .unplugged)
        XCTAssertEqual(CableError.deviceFailed(DC_STATUS_IO, family: .suuntoD9, portPresent: true), .protocolError(DC_STATUS_IO))
        XCTAssertEqual(CableError.deviceFailed(DC_STATUS_PROTOCOL, family: .suuntoD9, portPresent: true),
                       .protocolError(DC_STATUS_PROTOCOL))
    }

    // MARK: - Download outcomes

    private func session(path: String) throws -> DiveComputerSession {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        let stream = try DCCustomStream.open(backend: ProbeBackend(), transport: DC_TRANSPORT_SERIAL, context: context)
        let session = try DiveComputerSession.open(
            iostream: stream, context: try XCTUnwrap(context), family: DC_FAMILY_REEFNET_SENSUS, model: 1,
            displayName: "Reefnet Sensus", storageKey: "serial:test",
            locator: .serial(path: path, usbSerial: nil, vid: nil, pid: nil),
            deviceStorage: DeviceStorage(userDefaults: isolatedDefaults("dev")), lease: DiveComputerSessionLease())
        addTeardownBlock { session.close() }
        return session
    }

    private func result(_ outcome: DiveDownloadResult.Outcome, dives: Int = 0) -> DiveDownloadResult {
        DiveDownloadResult(outcome: outcome, divesDownloaded: dives)
    }

    func testDownloadOutcomesThatAreTheCables() throws {
        let present = try session(path: "/dev/null")
        XCTAssertNil(CableError(download: result(.completed, dives: 2), session: present))
        XCTAssertNil(CableError(download: result(.noNewDives), session: present))
        XCTAssertNil(CableError(download: result(.emptyRead), session: present))
        XCTAssertNil(CableError(download: result(.unreadableDives(1), dives: 3), session: present))
        XCTAssertEqual(CableError(download: result(.cancelled), session: present), .cancelled)
        XCTAssertEqual(CableError(download: result(.failed(DC_STATUS_TIMEOUT)), session: present), .noResponse(.reefnetSensus))
        XCTAssertEqual(CableError(download: result(.interrupted(DC_STATUS_TIMEOUT), dives: 2), session: present),
                       .protocolError(DC_STATUS_TIMEOUT), "a link that stalled after answering")
        XCTAssertEqual(CableError(download: result(.failed(DC_STATUS_IO)), session: present), .protocolError(DC_STATUS_IO))

        let gone = try session(path: "/dev/cu.libdcswift-no-such-port")
        XCTAssertEqual(CableError(download: result(.interrupted(DC_STATUS_IO), dives: 1), session: gone), .unplugged)
    }

    func testAnUnpluggedSessionReadsAsUnplugged() throws {
        let session = try session(path: "/dev/null")
        session.markUnplugged()
        XCTAssertTrue(session.isCancelled)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertEqual(CableError(download: result(.cancelled), session: session), .unplugged)
        XCTAssertEqual(CableError(download: result(.failed(DC_STATUS_IO)), session: session), .unplugged)
        XCTAssertNil(CableError(download: result(.completed, dives: 1), session: session), "it finished first")
    }

    // MARK: - Messages

    func testEveryErrorSaysSomething() {
        let all: [CableError] = [
            .unsupportedTransport(.classicBTSerial), .driverMissing, .permissionDenied, .busy, .sessionInProgress, .notFound,
            .unplugged, .noResponse(.suuntoVyper), .cancelled, .portError(errno: EIO), .protocolError(DC_STATUS_PROTOCOL),
        ]
        for error in all {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
            XCTAssertEqual(error.errorDescription, error.message)
        }
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        XCTAssertTrue(CableError.noResponse(.suuntoVyper).message.hasSuffix(DeviceCatalog.cableConnectInstructions(for: .suuntoVyper)))
    }

    func testEverySerialFamilyHasConnectInstructions() {
        let fallback = DeviceCatalog.cableConnectInstructions(for: .atomicsCobalt)
        let families = Set(DeviceCatalog.models(for: .serial).map(\.family))
        for family in families {
            XCTAssertFalse(DeviceCatalog.cableConnectInstructions(for: family).isEmpty, family.rawValue)
        }
        for family: DeviceConfiguration.DeviceFamily in [.suuntoVyper, .suuntoD9, .oceanicAtom2, .maresIconHD, .cressiLeonardo,
                                                         .hwOstc, .reefnetSensus, .uwatecMemomouse] {
            XCTAssertNotEqual(DeviceCatalog.cableConnectInstructions(for: family), fallback, "\(family) has its own")
        }
        XCTAssertTrue(DeviceCatalog.cableConnectInstructions(for: .suuntoVyper).contains("Suunto"))
    }
}
#endif
