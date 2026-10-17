#if os(macOS)
import XCTest
import IOKit
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `DiveComputerSession.open` on USB HID endpoints, with libdivecomputer's own EON Steel and G2 drivers talking to emulated computers through `HIDStream`.
final class HIDCableSessionTests: XCTestCase {
    typealias Wire = EONSteelWire

    private func factory(_ eonSteel: FakeEONSteel) -> FakeHIDFactory {
        FakeHIDFactory {
            let device = FakeHIDDevice()
            eonSteel.attach(to: device)
            return device
        }
    }

    private func factory(_ g2: FakeG2) -> FakeHIDFactory {
        FakeHIDFactory {
            let device = FakeHIDDevice()
            g2.attach(to: device)
            return device
        }
    }

    // MARK: - Downloads through the real drivers

    func testAnEONSteelOpensAndDownloadsOverUSBHID() throws {
        let computer = FakeEONSteel(serialDigits: "0001234567")
        let devices = factory(computer)
        let session = try openCable(HIDFixtures.eonSteel, model: HIDFixtures.model("Suunto EON Steel"), hidDevice: devices.factory)
        XCTAssertEqual(session.transport, DC_TRANSPORT_USBHID)
        XCTAssertEqual(session.locator, .usbHID(vid: 0x1493, pid: 0x0030, registryID: HIDFixtures.eonSteelID))
        XCTAssertEqual(session.storageKey, "usbhid:1493:0030:" + String(HIDFixtures.eonSteelID, radix: 16))
        XCTAssertEqual(session.displayName, "Suunto EON Steel")

        let (result, dives) = downloadToEnd(session)
        XCTAssertEqual(result?.outcome, .completed, "an empty logbook, with no fingerprint stored")
        XCTAssertEqual(result?.divesDownloaded, 0)
        XCTAssertEqual(dives.count, 0)
        let identity = try XCTUnwrap(result?.identity)
        XCTAssertEqual(identity.family, .suuntoEonSteel)
        XCTAssertEqual(identity.model, 0)
        XCTAssertEqual(identity.canonicalName, "Suunto EON Steel")
        XCTAssertEqual(identity.serial, String(format: "%08x", 1_234_567), "DEVINFO's serial is the version block's ASCII digits")
        XCTAssertEqual(identity.transport, .usbHID)
        XCTAssertEqual(computer.commands, [Wire.cmdInit, Wire.cmdDirOpen, Wire.cmdDirReaddir, Wire.cmdDirClose])
        XCTAssertEqual(computer.malformed, [], "every command arrived as suunto_eonsteel_send built it, CRC included")

        let device = try XCTUnwrap(devices.devices.first)
        XCTAssertFalse(device.reportsSent.isEmpty)
        for report in device.reportsSent {
            XCTAssertEqual(report.id, 0x3f)
            XCTAssertEqual(report.bytes.count, 64)
            XCTAssertEqual(report.bytes.first, 0x3f, "a non-zero report ID goes out as the report's first byte")
        }
        session.close()
        XCTAssertEqual(Array(device.calls.prefix(6)), [.open(seize: true), .registerInputReport(length: 64), .registerRemoval,
                                                       .setDispatchQueue, .setCancelHandler, .activate])
        XCTAssertEqual(Array(device.calls.suffix(3)), [.cancel, .cancelHandlerRan, .close(seize: true)])
        XCTAssertEqual(device.violations, [])
    }

    func testAG2OpensWithItsHandshakeAndDownloadsWithItsDEVINFO() throws {
        let computer = FakeG2(model: 0x32, serial: 0x0012_D687)
        let devices = factory(computer)
        let session = try openCable(HIDFixtures.g2, model: HIDFixtures.model("Scubapro G2"), hidDevice: devices.factory)
        let (result, _) = downloadToEnd(session)
        XCTAssertEqual(result?.outcome, .completed)
        XCTAssertEqual(result?.divesDownloaded, 0)
        let identity = try XCTUnwrap(result?.identity)
        XCTAssertEqual(identity.family, .uwatecSmart)
        XCTAssertEqual(identity.model, 0x32)
        XCTAssertEqual(identity.canonicalName, "Scubapro G2")
        XCTAssertEqual(identity.serial, "0012d687")
        XCTAssertNotEqual(session.devicePtr.pointee.have_clock, 0, "the dump's clock event arrived")
        XCTAssertEqual(computer.commands, [0x1B, 0x1C, 0x10, 0x11, 0x13, 0x14, 0x1A, 0xC6])
        XCTAssertEqual(computer.malformed, [])

        let device = try XCTUnwrap(devices.devices.first)
        for report in device.reportsSent {
            XCTAssertEqual(report.id, 0, "the G2 family's reports are unnumbered")
            XCTAssertEqual(report.bytes.count, 32, "the zero report ID isn't sent, so 32 of the driver's 33 bytes go out")
        }
        XCTAssertEqual(Array(device.reportsSent[0].bytes.prefix(2)), [0x01, 0x1B])
        XCTAssertEqual(Array(device.reportsSent[1].bytes.prefix(6)), [0x05, 0x1C, 0x10, 0x27, 0x00, 0x00])
        XCTAssertEqual(device.violations, [])
    }

    func testTheSharedG2PIDOpensAsEitherModelAndDEVINFONamesTheComputer() throws {
        let endpoint = HIDFixtures.g2
        XCTAssertEqual(Set(endpoint.candidates.map(\.name)), ["Scubapro G2", "Scubapro G2 TEK"])
        XCTAssertEqual(endpoint.displayName, "G2", "the device's own product name")
        let unnamed = try XCTUnwrap(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x2e6c, productID: 0x3201))
        XCTAssertEqual(unnamed.displayName, unnamed.candidates.map(\.name).joined(separator: " or "))

        // Picked as a G2 TEK, the computer says it is a G2.
        let g2 = FakeG2(model: 0x32)
        let asTEK = try openCable(endpoint, model: HIDFixtures.model("Scubapro G2 TEK"), hidDevice: factory(g2).factory)
        let first = try XCTUnwrap(downloadToEnd(asTEK).result?.identity)
        asTEK.close()
        XCTAssertEqual(first.model, 0x32)
        XCTAssertEqual(first.canonicalName, "Scubapro G2")

        let tek = FakeG2(model: 0x31)
        let asG2 = try openCable(endpoint, model: HIDFixtures.model("Scubapro G2"), hidDevice: factory(tek).factory)
        let second = try XCTUnwrap(downloadToEnd(asG2).result?.identity)
        asG2.close()
        XCTAssertEqual(second.model, 0x31)
        XCTAssertEqual(second.canonicalName, "Scubapro G2 TEK")
    }

    func testFilesSpanningManyReportsArriveWhole() throws {
        // 700 bytes takes 12 reports; 1500 bytes takes two FILE_READs of up to 1024.
        let small = (0..<700).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let large = (0..<1_500).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
        let computer = FakeEONSteel(dives: [(name: "5F5E1000.LOG", bytes: small), (name: "5F5E2000.LOG", bytes: large)])
        let session = try openCable(HIDFixtures.eonSteel, model: HIDFixtures.model("Suunto EON Steel"),
                                    hidDevice: factory(computer).factory)

        final class Dives { var all: [[UInt8]] = [] }
        let received = Dives()
        let status = withExtendedLifetime(received) {
            dc_device_foreach(session.devicePtr.pointee.device, { data, size, _, _, userdata in
                guard let data, let userdata else { return 0 }
                Unmanaged<Dives>.fromOpaque(userdata).takeUnretainedValue().all.append(Array(UnsafeBufferPointer(start: data, count: Int(size))))
                return 1
            }, Unmanaged.passUnretained(received).toOpaque())
        }
        XCTAssertEqual(status, DC_STATUS_SUCCESS)
        XCTAssertEqual(computer.malformed, [])
        // Newest first, each led by its 4-byte timestamp fingerprint.
        XCTAssertEqual(received.all.count, 2)
        XCTAssertEqual(received.all.first, Wire.le32(0x5F5E_2000) + large)
        XCTAssertEqual(received.all.last, Wire.le32(0x5F5E_1000) + small)
        XCTAssertEqual(computer.commands.filter { $0 == Wire.cmdFileRead }.count, 3)
    }

    func testAReportWithoutThe3FReportIDByteIsAProtocolError() throws {
        let devices = FakeHIDFactory {
            let device = FakeHIDDevice()
            // As if IOKit had stripped the report ID: the EON Steel driver checks byte 0.
            device.computer = { _, _ in
                FakeEONSteel.packets(command: 0, magic: 0, sequence: 0, payload: [UInt8](repeating: 0, count: 0x30))
                    .map { [0x00] + $0.dropFirst() }
            }
            return device
        }
        let error = cableOpenError(HIDFixtures.eonSteel, model: try HIDFixtures.model("Suunto EON Steel"), hidDevice: devices.factory)
        XCTAssertEqual(error, .protocolError(DC_STATUS_PROTOCOL))
        XCTAssertEqual(devices.devices.first?.calls.last, .close(seize: true), "a failed open closes the device")
    }

    func testAHIDDownloadRecordedThroughTheTapReplays() throws {
        let computer = FakeG2(serial: 0x0000_4D2E)
        let recorder = DCStreamRecorder()
        let model = try HIDFixtures.model("Scubapro G2")
        let session = try openCable(HIDFixtures.g2, model: model, recorder: recorder, hidDevice: factory(computer).factory)
        let live = try XCTUnwrap(downloadToEnd(session).result)
        session.close()
        let recording = recorder.recording(family: model.dcFamily, model: model.model)
        XCTAssertEqual(recording.transport, DC_TRANSPORT_USBHID)
        XCTAssertTrue(recording.exchanges.contains { $0.operation == .write }, "writes are recorded with the report-ID byte")

        let (replayed, _, script) = try replayDownload(recording, displayName: model.name)
        XCTAssertNil(script.deviation)
        XCTAssertEqual(replayed.outcome, live.outcome)
        XCTAssertEqual(replayed.identity?.serial, live.identity?.serial)
        XCTAssertEqual(replayed.identity?.canonicalName, "Scubapro G2")
    }

    // MARK: - Refusals

    func testAnOpenFailureMapsItsIOReturn() throws {
        let model = try HIDFixtures.model("Suunto EON Steel")
        for (result, expected) in [(kIOReturnExclusiveAccess, CableError.busy), (kIOReturnNotPermitted, .permissionDenied),
                                   (kIOReturnNoDevice, .notFound), (kIOReturnError, .usbError(ioReturn: kIOReturnError))] {
            let devices = FakeHIDFactory {
                let device = FakeHIDDevice()
                device.openResult = result
                return device
            }
            let lease = DiveComputerSessionLease()
            XCTAssertEqual(cableOpenError(HIDFixtures.eonSteel, model: model, lease: lease, hidDevice: devices.factory), expected)
            XCTAssertFalse(lease.isHeld)
            XCTAssertEqual(devices.devices.first?.calls, [.open(seize: true)])
        }
        XCTAssertTrue(CableError.busy.message.contains("dive computer"))
        XCTAssertEqual(CableError(hidOpen: kIOReturnNotPrivileged), .permissionDenied)
        XCTAssertEqual(CableError(hidOpen: kIOReturnNotAttached), .notFound)
        XCTAssertEqual(CableError(hidOpen: kIOReturnNotFound), .notFound)
        XCTAssertEqual(CableError(hidOpen: kIOReturnOffline), .notFound)
    }

    func testADeviceGoneBeforeTheOpenIsNotFound() throws {
        let devices = FakeHIDFactory { nil }
        let lease = DiveComputerSessionLease()
        XCTAssertEqual(cableOpenError(HIDFixtures.eonSteel, model: try HIDFixtures.model("Suunto EON Steel"), lease: lease,
                                      hidDevice: devices.factory), .notFound)
        XCTAssertEqual(devices.requests, [HIDFixtures.eonSteel.id])
        XCTAssertFalse(lease.isHeld)
    }

    func testAModelThisDeviceCantBeIsRefusedBeforeTheDeviceIsMade() throws {
        let devices = FakeHIDFactory { FakeHIDDevice() }
        // EON Steel reports the opened model as its own, so an EON Core picked for an EON Steel would be stored as one.
        XCTAssertEqual(cableOpenError(HIDFixtures.eonSteel, model: try HIDFixtures.model("Suunto EON Core"), hidDevice: devices.factory),
                       .unsupportedTransport(.usbHID))
        XCTAssertEqual(cableOpenError(HIDFixtures.eonSteel, model: try CableFixtures.model("Heinrichs Weikamp OSTC Mk2"),
                                      hidDevice: devices.factory), .unsupportedTransport(.usbHID))
        XCTAssertEqual(cableOpenError(HIDFixtures.g2, model: try HIDFixtures.model("Scubapro G2 Console"), hidDevice: devices.factory),
                       .unsupportedTransport(.usbHID), "the G2 Console is 2e6c:3211")
        XCTAssertEqual(devices.requests, [])
    }

    func testAnotherSessionHoldingTheLeaseIsSessionInProgress() throws {
        let devices = FakeHIDFactory { FakeHIDDevice() }
        let lease = DiveComputerSessionLease()
        XCTAssertTrue(lease.tryAcquire())
        XCTAssertEqual(cableOpenError(HIDFixtures.eonSteel, model: try HIDFixtures.model("Suunto EON Steel"), lease: lease,
                                      hidDevice: devices.factory), .sessionInProgress)
        XCTAssertEqual(devices.requests, [], "the device isn't touched")
        lease.release()
    }

    // MARK: - Unplug, cancel, close

    func testPullingTheComputerMidDownloadEndsItAsUnplugged() throws {
        let computer = FakeEONSteel()
        computer.silentAfterInit = true
        let devices = factory(computer)
        let session = try openCable(HIDFixtures.eonSteel, model: HIDFixtures.model("Suunto EON Steel"), hidDevice: devices.factory)
        let device = try XCTUnwrap(devices.devices.first)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { device.remove() }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertLessThan(milliseconds(since: start), 1_500, "well inside the driver's 5 s timeout")
        XCTAssertTrue(session.wasUnplugged, "the device's own removal callback says so, with no discovery")
        XCTAssertEqual(CableError(download: download, session: session), .unplugged)
        session.close()
        XCTAssertFalse(device.calls.contains(.close(seize: true)), "an unplugged device isn't closed")
        XCTAssertTrue(device.calls.contains(.cancelHandlerRan))
    }

    func testCancellingTheSessionEndsABlockedRead() throws {
        let computer = FakeEONSteel()
        computer.silentAfterInit = true
        let session = try openCable(HIDFixtures.eonSteel, model: HIDFixtures.model("Suunto EON Steel"),
                                    hidDevice: factory(computer).factory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { session.cancel() }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertEqual(download.outcome, .cancelled)
        XCTAssertLessThan(milliseconds(since: start), 1_500)
        XCTAssertEqual(CableError(download: download, session: session), .cancelled)
        XCTAssertFalse(session.wasUnplugged)
    }

    func testCancellingAnOpenBlockedInTheInitReadThrowsCancelledPromptly() async throws {
        let devices = FakeHIDFactory { FakeHIDDevice() }
        let endpoint = HIDFixtures.eonSteel
        let model = try HIDFixtures.model("Suunto EON Steel")
        let lease = DiveComputerSessionLease()
        let storage = DeviceStorage(userDefaults: isolatedDefaults("dev"))
        let factory = devices.factory
        let task = Task {
            try await DiveComputerSession.open(endpoint, model: model, discovery: nil, recorder: nil, deviceStorage: storage,
                                               lease: lease, hidDevice: factory)
        }
        let deadline = Date().addingTimeInterval(5)
        while devices.devices.first?.reportsSent.isEmpty ?? true, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(devices.devices.first?.reportsSent.count, 1, "INIT went out and nothing answers it")
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
        XCTAssertEqual(devices.devices.first?.calls.last, .close(seize: true))
        XCTAssertFalse(EndpointClaims.shared.claimedKeys.contains(endpoint.id))
    }

    func testAnOpenSessionIsBusyInDiscoveryAndRemovingTheEndpointUnplugsIt() throws {
        let endpoint = HIDFixtures.eonSteel
        let discovery = StaticCableDiscovery(endpoints: [endpoint])
        let session = try openCable(endpoint, model: HIDFixtures.model("Suunto EON Steel"), discovery: discovery,
                                    hidDevice: factory(FakeEONSteel()).factory)
        XCTAssertEqual(discovery.endpoints.first?.status, .busy)
        XCTAssertTrue(EndpointClaims.shared.claimedKeys.contains(endpoint.id))
        discovery.remove(id: endpoint.id)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertTrue(session.isCancelled)
        session.close()
        XCTAssertFalse(EndpointClaims.shared.claimedKeys.contains(endpoint.id))
    }

    func testAHIDRemovalInTheRegistryUnplugsTheSessionOnIt() throws {
        let source = FakeRegistrySource(RegistrySnapshot(hidDevices: [HIDFixtures.eonSteelDevice]))
        let discovery = IOKitCableDiscovery(source: source)
        discovery.start()
        defer { discovery.stop() }
        let endpoint = try XCTUnwrap(discovery.endpoints.first)
        XCTAssertEqual(endpoint.transport, .usbHID)
        let computer = FakeEONSteel()
        computer.silentAfterInit = true
        let devices = FakeHIDFactory {
            let device = FakeHIDDevice()
            computer.attach(to: device)
            return device
        }
        let session = try openCable(endpoint, model: HIDFixtures.model("Suunto EON Steel"), discovery: discovery,
                                    hidDevice: devices.factory)
        XCTAssertEqual(devices.requests, [HIDFixtures.eonSteel.id])
        XCTAssertEqual(discovery.endpoints.first?.status, .busy)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { source.emit(.removed, RegistrySnapshot()) }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertLessThan(milliseconds(since: start), 1_500)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertEqual(CableError(download: download, session: session), .unplugged)
        XCTAssertTrue(discovery.endpoints.isEmpty)
    }

    func testEachOpenGetsAFreshDeviceAndCloseReleasesTheLast() throws {
        let computer = FakeEONSteel()
        let devices = factory(computer)
        let model = try HIDFixtures.model("Suunto EON Steel")
        let lease = DiveComputerSessionLease()
        for _ in 0..<2 {
            let session = try openCable(HIDFixtures.eonSteel, model: model, lease: lease, hidDevice: devices.factory)
            XCTAssertEqual(downloadToEnd(session).result?.outcome, .completed)
            session.close()
            XCTAssertFalse(lease.isHeld)
        }
        XCTAssertEqual(devices.devices.count, 2, "a cancelled IOHIDDevice can't be scheduled again")
        for device in devices.devices {
            XCTAssertEqual(device.calls.last, .close(seize: true))
            XCTAssertEqual(device.violations, [])
        }
    }

    // MARK: - Messages

    func testUSBHIDErrorsAndInstructionsSaySomethingOfTheirOwn() {
        let all: [CableError] = [.usbError(ioReturn: kIOReturnError), .busy, .permissionDenied, .notFound,
                                 .portError(errno: EIO), .noResponse(.suuntoEonSteel), .noResponse(.uwatecSmart)]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        XCTAssertTrue(CableError.usbError(ioReturn: kIOReturnError).message.contains("0xe00002bc"))
        let fallback = DeviceCatalog.cableConnectInstructions(for: .atomicsCobalt)
        for family in Set(DeviceCatalog.models(for: .usbHID).map(\.family)) {
            XCTAssertNotEqual(DeviceCatalog.cableConnectInstructions(for: family), fallback, family.rawValue)
        }
    }
}
#endif
