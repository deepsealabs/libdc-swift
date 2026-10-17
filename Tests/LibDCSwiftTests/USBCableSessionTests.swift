#if os(macOS)
import XCTest
import IOKit
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `DiveComputerSession.open` on raw USB endpoints, with libdivecomputer's own Atomic Aquatics Cobalt driver talking to an emulated computer through `USBStream`.
final class USBCableSessionTests: XCTestCase {
    // Synthetic values throughout: made-up serial digits and dates, no positions.
    private static let serialDigits = "00012345"
    private static let newerDepths = CobaltDive.profile(24, maxMbar: 2140)
    private static let olderDepths = CobaltDive.profile(18, maxMbar: 1560)
    private static let newer = CobaltDive.make(year: 2001, month: 2, day: 4, hour: 11, minute: 25, depthsMbar: newerDepths)
    private static let older = CobaltDive.make(year: 2001, month: 2, day: 3, hour: 9, minute: 10, depthsMbar: olderDepths)

    private func cobalt2() throws -> DCModel { try USBFixtures.model("Atomic Aquatics Cobalt 2") }

    private func newest(_ dives: [DiveData]) -> DiveData? {
        dives.max { $0.datetime < $1.datetime }
    }

    // MARK: - Downloads through the real driver

    func testACobaltOpensAndDownloadsOverUSB() throws {
        let computer = FakeCobalt(serialDigits: Self.serialDigits, firmware: (2, 7), model: 2, dives: [Self.newer, Self.older])
        let devices = FakeUSBFactory(computer)
        let session = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
        XCTAssertEqual(session.transport, DC_TRANSPORT_USB)
        XCTAssertEqual(session.locator, .usb(vid: 0x0471, pid: 0x0888, registryID: USBFixtures.cobaltID))
        XCTAssertEqual(session.storageKey, "usb:0471:0888:" + String(USBFixtures.cobaltID, radix: 16))
        XCTAssertEqual(session.displayName, "Atomic Aquatics Cobalt 2")
        XCTAssertEqual(devices.requests.map(\.id), [USBFixtures.cobalt.id])
        XCTAssertEqual(devices.requests.first?.layout, USBInterfaceLayout(vendorID: 0x0471, productID: 0x0888, interfaceNumber: 0,
                                                                         endpointIn: 0x82, endpointOut: 0x02))

        let (result, dives) = downloadToEnd(session)
        XCTAssertEqual(result?.outcome, .completed)
        XCTAssertEqual(result?.divesDownloaded, 2)
        XCTAssertEqual(dives.count, 2)
        let identity = try XCTUnwrap(result?.identity)
        XCTAssertEqual(identity.family, .atomicsCobalt)
        XCTAssertEqual(identity.model, 2)
        XCTAssertEqual(identity.canonicalName, "Atomic Aquatics Cobalt 2")
        XCTAssertEqual(identity.serial, String(format: "%08x", 12_345), "DEVINFO's serial is the version block's ASCII digits")
        XCTAssertEqual(identity.transport, .usb)
        XCTAssertEqual(computer.commands, [FakeCobalt.cmdVersion, FakeCobalt.cmdFirstDive, FakeCobalt.cmdNextDive, FakeCobalt.cmdNextDive])
        XCTAssertEqual(computer.malformed, [], "every command arrived as atomics_cobalt.c built it")

        let dive = try XCTUnwrap(newest(dives))
        XCTAssertEqual(dive.maxDepth, CobaltDive.depthMetres(Self.newerDepths.max()!), accuracy: 0.001)
        XCTAssertEqual(dive.divetime, 720, "24 samples 30 s apart")
        XCTAssertEqual(dive.profile.count, 24)
        let start = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dive.datetime)
        XCTAssertEqual([start.year, start.month, start.day, start.hour, start.minute], [2001, 2, 4, 11, 25])
        XCTAssertEqual(result?.fingerprintCommit?.fingerprint, CobaltDive.fingerprint(Self.newer))

        let device = try XCTUnwrap(devices.devices.first)
        XCTAssertTrue(device.reads.allSatisfy { $0.length <= 64 }, "one packet per request")
        XCTAssertTrue(device.reads.allSatisfy { $0.timeout > 0 && $0.timeout <= 2000 }, "inside the driver's 2 s")
        session.close()
        XCTAssertEqual(device.closeCount, 1)
    }

    func testEitherCobaltModelOpensAndDEVINFONamesTheComputer() throws {
        let endpoint = USBFixtures.cobalt
        XCTAssertEqual(endpoint.candidates.map(\.name), ["Atomic Aquatics Cobalt", "Atomic Aquatics Cobalt 2"])
        XCTAssertEqual(endpoint.displayName, "Atomic Aquatics Cobalt or Atomic Aquatics Cobalt 2")

        let first = FakeCobalt(model: 0, dives: [Self.newer])
        let asCobalt2 = try openCable(endpoint, model: cobalt2(), usbDevice: FakeUSBFactory(first).factory)
        let one = try XCTUnwrap(downloadToEnd(asCobalt2).result?.identity)
        asCobalt2.close()
        XCTAssertEqual(one.model, 0)
        XCTAssertEqual(one.canonicalName, "Atomic Aquatics Cobalt")

        let second = FakeCobalt(model: 2, dives: [Self.newer])
        let asCobalt = try openCable(endpoint, model: USBFixtures.model("Atomic Aquatics Cobalt"), usbDevice: FakeUSBFactory(second).factory)
        let two = try XCTUnwrap(downloadToEnd(asCobalt).result?.identity)
        asCobalt.close()
        XCTAssertEqual(two.model, 2)
        XCTAssertEqual(two.canonicalName, "Atomic Aquatics Cobalt 2")
    }

    func testACobalt1OpenedAsACobalt2IsStoredAsTheModelItReports() throws {
        let computer = FakeCobalt(model: 0, dives: [Self.newer])
        let session = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: FakeUSBFactory(computer).factory)
        let (result, _) = downloadToEnd(session)
        XCTAssertEqual(result?.outcome, .completed)
        let stored = try XCTUnwrap(session.deviceStorage.getStoredDevice(uuid: session.storageKey))
        XCTAssertEqual(stored.family, .atomicsCobalt)
        XCTAssertEqual(stored.model, 0, "0 is the Cobalt 1, not an unreported model")
    }

    func testADiveThatFillsItsLastPacketEndsOnTheReadTimeout() throws {
        // 8 segments and an 8-byte trailer: 382 bytes and the checksum fill exactly 6 packets, so no short packet ends the transfer.
        let aligned = CobaltDive.make(year: 2001, month: 2, day: 5, hour: 8, minute: 0, depthsMbar: CobaltDive.profile(8, maxMbar: 900),
                                      trailer: [UInt8](repeating: 0x5A, count: 8))
        XCTAssertEqual(FakeCobalt.withChecksum(aligned).count % 64, 0)
        let computer = FakeCobalt(dives: [aligned])
        let devices = FakeUSBFactory(computer)
        let session = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
        let (result, dives) = downloadToEnd(session)
        XCTAssertEqual(result?.outcome, .completed)
        XCTAssertEqual(dives.count, 1)
        XCTAssertEqual(dives.first?.profile.count, 8, "the trailer is no sample")
        XCTAssertEqual(result?.fingerprintCommit?.fingerprint, CobaltDive.fingerprint(aligned))
        let device = try XCTUnwrap(devices.devices.first)
        XCTAssertTrue(device.calls.contains(.clearStall(endpoint: 0x82)), "the timed-out read put the data toggle back")
    }

    func testADiveOfExactlyOneReadAndOneLongerThanOneReadArriveWhole() throws {
        // 496 segments and an 8-byte trailer make 8,190 bytes: with the checksum, one full 8 KiB read, then an empty one.
        let full = CobaltDive.make(year: 2001, month: 2, day: 6, hour: 7, minute: 0, depthsMbar: CobaltDive.profile(496, maxMbar: 1800),
                                   interval: 10, trailer: [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(FakeCobalt.withChecksum(full).count, 8192)
        let long = CobaltDive.make(year: 2001, month: 2, day: 5, hour: 7, minute: 0, depthsMbar: CobaltDive.profile(600, maxMbar: 2600),
                                   interval: 10)
        XCTAssertGreaterThan(long.count, 8192)
        for sendsZeroLengthPacket in [false, true] {
            let computer = FakeCobalt(dives: [full, long])
            let devices = FakeUSBFactory(computer) { $0.sendsZeroLengthPacket = sendsZeroLengthPacket }
            let session = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
            let (result, dives) = downloadToEnd(session)
            session.close()
            XCTAssertEqual(result?.outcome, .completed, "zero-length packet: \(sendsZeroLengthPacket)")
            XCTAssertEqual(dives.map(\.profile.count).sorted(), [496, 600])
            XCTAssertEqual(newest(dives)?.maxDepth ?? 0, CobaltDive.depthMetres(CobaltDive.profile(496, maxMbar: 1800).max()!),
                           accuracy: 0.001)
        }
    }

    func testASecondDownloadStopsAtTheFingerprint() throws {
        let store = DeviceFingerprintStorage(userDefaults: isolatedDefaults("fp"))
        let computer = FakeCobalt(dives: [Self.newer, Self.older])
        let devices = FakeUSBFactory(computer)
        let first = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
        let (firstResult, _) = downloadToEnd(first, viewModel: DiveDataViewModel(fingerprintStore: store))
        first.close()
        try XCTUnwrap(firstResult?.fingerprintCommit).acknowledge()
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        let second = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
        let (secondResult, dives) = downloadToEnd(second, viewModel: DiveDataViewModel(fingerprintStore: store))
        second.close()
        XCTAssertEqual(secondResult?.outcome, .noNewDives)
        XCTAssertEqual(dives.count, 0)
        XCTAssertEqual(Array(computer.commands.suffix(2)), [FakeCobalt.cmdVersion, FakeCobalt.cmdFirstDive],
                       "the walk stopped at the newest dive, which it already has")
        XCTAssertEqual(devices.devices.count, 2, "each open claims the interface again")
    }

    func testAUSBDownloadRecordedThroughTheTapReplays() throws {
        let computer = FakeCobalt(dives: [Self.newer])
        let recorder = DCStreamRecorder()
        let model = try cobalt2()
        let session = try openCable(USBFixtures.cobalt, model: model, recorder: recorder, usbDevice: FakeUSBFactory(computer).factory)
        let (live, liveDives) = downloadToEnd(session)
        session.close()
        let recording = recorder.recording(family: model.dcFamily, model: model.model)
        XCTAssertEqual(recording.transport, DC_TRANSPORT_USB)
        XCTAssertEqual(Array(recording.exchanges.prefix(3)), [
            .setTimeout(2000, status: DC_STATUS_SUCCESS),
            .ioctl(request: USBControl.controlWrite, input: USBControl.command(FakeCobalt.cmdVersion), output: [],
                   status: DC_STATUS_SUCCESS),
            .read(size: 16, data: FakeCobalt.withChecksum(computer.version), status: DC_STATUS_SUCCESS),
        ])

        let (replayed, replayedDives, script) = try replayDownload(try DCRecording(dcrec: try recording.encoded()),
                                                                   displayName: model.name)
        XCTAssertNil(script.deviation)
        XCTAssertTrue(script.isComplete, "played \(script.consumed) of \(script.exchanges.count)")
        XCTAssertEqual(replayed.outcome, live?.outcome)
        XCTAssertEqual(replayed.identity?.serial, live?.identity?.serial)
        XCTAssertEqual(replayedDives.map(\.maxDepth), liveDives.map(\.maxDepth))
        XCTAssertEqual(replayed.fingerprintCommit?.fingerprint, CobaltDive.fingerprint(Self.newer))
    }

    // MARK: - Refusals

    func testAnOpenFailureMapsItsIOReturn() throws {
        let model = try cobalt2()
        for (result, expected) in [(kIOReturnExclusiveAccess, CableError.busy), (kIOReturnNotPermitted, .permissionDenied),
                                   (kIOReturnNoDevice, .notFound), (kIOReturnError, .usbError(ioReturn: kIOReturnError))] {
            let devices = FakeUSBFactory { throw CableError(usbOpen: result) }
            let lease = DiveComputerSessionLease()
            XCTAssertEqual(cableOpenError(USBFixtures.cobalt, model: model, lease: lease, usbDevice: devices.factory), expected)
            XCTAssertFalse(lease.isHeld)
            XCTAssertEqual(devices.requests.count, 1)
        }
        XCTAssertEqual(CableError(usbOpen: kIOReturnNotPrivileged), .permissionDenied)
        XCTAssertEqual(CableError(usbOpen: kIOReturnNotAttached), .notFound)
        XCTAssertEqual(CableError(usbOpen: kIOReturnNotFound), .notFound)
        XCTAssertEqual(CableError(usbOpen: kIOReturnOffline), .notFound)
        let missingPipe = IOReturn(bitPattern: 0xE000_4057)
        XCTAssertEqual(CableError(usbOpen: missingPipe), .usbError(ioReturn: missingPipe), "kIOUSBEndpointNotFound")
    }

    func testAModelThisDeviceCantBeIsRefusedBeforeTheDeviceIsOpened() throws {
        let devices = FakeUSBFactory { FakeUSBDevice() }
        XCTAssertEqual(cableOpenError(USBFixtures.cobalt, model: try CableFixtures.model("Heinrichs Weikamp OSTC Mk2"),
                                      usbDevice: devices.factory), .unsupportedTransport(.usb))
        XCTAssertEqual(cableOpenError(USBFixtures.cobalt, model: try HIDFixtures.model("Suunto EON Steel"),
                                      usbDevice: devices.factory), .unsupportedTransport(.usb))
        XCTAssertEqual(devices.requests.count, 0)
        XCTAssertNil(CableEndpoint.usbDevice(registryID: 1, vendorID: 0x0471, productID: 0x0999))
        XCTAssertNil(CableEndpoint.usbDevice(registryID: 1, vendorID: 0x1493, productID: 0x0030), "a HID computer's VID:PID")
    }

    func testAnotherSessionHoldingTheLeaseIsSessionInProgress() throws {
        let devices = FakeUSBFactory { FakeUSBDevice() }
        let lease = DiveComputerSessionLease()
        XCTAssertTrue(lease.tryAcquire())
        XCTAssertEqual(cableOpenError(USBFixtures.cobalt, model: try cobalt2(), lease: lease, usbDevice: devices.factory),
                       .sessionInProgress)
        XCTAssertEqual(devices.requests.count, 0, "the device isn't touched")
        lease.release()
    }

    func testAComputerThatDoesntAnswerIsNoResponse() throws {
        let computer = FakeCobalt()
        computer.silentFrom = FakeCobalt.cmdVersion
        let devices = FakeUSBFactory(computer)
        let lease = DiveComputerSessionLease()
        XCTAssertEqual(cableOpenError(USBFixtures.cobalt, model: try cobalt2(), lease: lease, usbDevice: devices.factory),
                       .noResponse(.atomicsCobalt))
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(devices.devices.first?.closeCount, 1, "a failed open closes the device")
        XCTAssertTrue(CableError.noResponse(.atomicsCobalt).message.contains("didn't answer"))
    }

    func testAVersionWithABadChecksumIsAProtocolError() throws {
        let devices = FakeUSBFactory {
            let device = FakeUSBDevice()
            device.onControl = { _, _ in (kIOReturnSuccess, [], Array("00012345".utf8) + [0, 2, 0, 7, 0, 2, 0xAB, 0xCD]) }
            return device
        }
        XCTAssertEqual(cableOpenError(USBFixtures.cobalt, model: try cobalt2(), usbDevice: devices.factory),
                       .protocolError(DC_STATUS_PROTOCOL))
        XCTAssertEqual(devices.devices.first?.closeCount, 1)
    }

    // MARK: - Unplug, cancel, close

    func testPullingTheComputerMidDownloadEndsItAsUnplugged() throws {
        let computer = FakeCobalt(dives: [Self.newer])
        computer.silentFrom = FakeCobalt.cmdFirstDive
        let devices = FakeUSBFactory(computer) { $0.waitsOnSilence = true }
        let session = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
        let device = try XCTUnwrap(devices.devices.first)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { device.detach() }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertLessThan(milliseconds(since: start), 1_500, "well inside the driver's 2 s timeout")
        XCTAssertTrue(session.wasUnplugged, "the stream saw the device go, with no discovery")
        XCTAssertEqual(CableError(download: download, session: session), .unplugged)
        session.close()
        XCTAssertEqual(device.closeCount, 1)
    }

    func testCancellingTheSessionEndsABlockedRead() throws {
        let computer = FakeCobalt(dives: [Self.newer])
        computer.silentFrom = FakeCobalt.cmdFirstDive
        let devices = FakeUSBFactory(computer) { $0.waitsOnSilence = true }
        let session = try openCable(USBFixtures.cobalt, model: cobalt2(), usbDevice: devices.factory)
        let cancelled = Instant()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            cancelled.mark()
            session.cancel()
        }
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertEqual(download.outcome, .cancelled)
        XCTAssertLessThan(milliseconds(since: cancelled.value), 200, "the blocked read was aborted, not waited out")
        XCTAssertEqual(CableError(download: download, session: session), .cancelled)
        XCTAssertFalse(session.wasUnplugged)
        XCTAssertGreaterThanOrEqual(devices.devices.first?.aborts ?? 0, 1)
    }

    func testCancellingAnOpenBlockedInTheVersionReadThrowsCancelledPromptly() async throws {
        let computer = FakeCobalt()
        computer.silentFrom = FakeCobalt.cmdVersion
        let devices = FakeUSBFactory(computer) { $0.waitsOnSilence = true }
        let endpoint = USBFixtures.cobalt
        let model = try cobalt2()
        let lease = DiveComputerSessionLease()
        let storage = DeviceStorage(userDefaults: isolatedDefaults("dev"))
        let factory = devices.factory
        let task = Task {
            try await DiveComputerSession.open(endpoint, model: model, discovery: nil, recorder: nil, deviceStorage: storage,
                                               lease: lease, hidDevice: IOKitHIDDevice.make, usbDevice: factory)
        }
        let deadline = Date().addingTimeInterval(5)
        while computer.commands.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(computer.commands, [FakeCobalt.cmdVersion], "the version request went out and nothing answers it")
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
        XCTAssertEqual(devices.devices.first?.closeCount, 1)
        XCTAssertFalse(EndpointClaims.shared.claimedKeys.contains(endpoint.id))
    }

    func testAnOpenSessionIsBusyInDiscoveryAndRemovingTheEndpointUnplugsIt() throws {
        let endpoint = USBFixtures.cobalt
        let discovery = StaticCableDiscovery(endpoints: [endpoint])
        let session = try openCable(endpoint, model: cobalt2(), discovery: discovery,
                                    usbDevice: FakeUSBFactory(FakeCobalt()).factory)
        XCTAssertEqual(discovery.endpoints.first?.status, .busy)
        XCTAssertTrue(EndpointClaims.shared.claimedKeys.contains(endpoint.id))
        discovery.remove(id: endpoint.id)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertTrue(session.isCancelled)
        session.close()
        XCTAssertFalse(EndpointClaims.shared.claimedKeys.contains(endpoint.id))
    }

    func testARemovalInTheRegistryUnplugsTheSessionOnIt() throws {
        let source = FakeRegistrySource(RegistrySnapshot(usbComputers: [USBFixtures.cobaltDevice]))
        let discovery = IOKitCableDiscovery(source: source)
        discovery.start()
        defer { discovery.stop() }
        let endpoint = try XCTUnwrap(discovery.endpoints.first)
        XCTAssertEqual(endpoint.transport, .usb)
        let computer = FakeCobalt(dives: [Self.newer])
        computer.silentFrom = FakeCobalt.cmdFirstDive
        let devices = FakeUSBFactory(computer) { $0.waitsOnSilence = true }
        let session = try openCable(endpoint, model: cobalt2(), discovery: discovery, usbDevice: devices.factory)
        XCTAssertEqual(discovery.endpoints.first?.status, .busy)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { source.emit(.removed, RegistrySnapshot()) }
        let start = DispatchTime.now()
        let download = try XCTUnwrap(downloadToEnd(session).result)
        XCTAssertLessThan(milliseconds(since: start), 1_500)
        XCTAssertTrue(session.wasUnplugged)
        XCTAssertEqual(CableError(download: download, session: session), .unplugged)
        XCTAssertTrue(discovery.endpoints.isEmpty)
    }

    func testEachOpenGetsAFreshDeviceAndCloseClosesIt() throws {
        let devices = FakeUSBFactory(FakeCobalt(dives: [Self.newer]))
        let lease = DiveComputerSessionLease()
        for _ in 0..<2 {
            let session = try openCable(USBFixtures.cobalt, model: cobalt2(), lease: lease, usbDevice: devices.factory)
            XCTAssertEqual(downloadToEnd(session).result?.outcome, .completed)
            session.close()
            XCTAssertFalse(lease.isHeld)
        }
        XCTAssertEqual(devices.devices.count, 2)
        XCTAssertEqual(devices.devices.map(\.closeCount), [1, 1])
    }
}
#endif
