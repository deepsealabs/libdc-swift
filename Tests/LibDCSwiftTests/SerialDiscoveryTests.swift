#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Serial discovery: how a `RegistrySnapshot` maps to endpoints, the cable hints, and how discoveries follow hot-plug.
final class SerialDiscoveryTests: XCTestCase {

    private typealias USB = RegistrySnapshot.USBDevice
    private typealias Port = RegistrySnapshot.Port

    private static let suunto = USB(registryID: 0x11, vendorID: 0x0403, productID: 0xF680, serialNumber: "SUUNTO01",
                                    productName: "Suunto USB Serial Cable")
    private static let pelagic = USB(registryID: 0x22, vendorID: 0x0403, productID: 0xF460, serialNumber: "PELAGIC1")
    private static let cp210x = USB(registryID: 0x33, vendorID: 0x10C4, productID: 0xEA60, serialNumber: "0001",
                                    productName: "CP2102 USB to UART Bridge Controller")
    private static let arduino = USB(registryID: 0x44, vendorID: 0x2341, productID: 0x0043, productName: "Arduino Uno")

    private static let macPorts: [Port] = [
        Port(calloutPath: "/dev/cu.debug-console", baseName: "debug-console", parent: .none),
        Port(calloutPath: "/dev/cu.Bluetooth-Incoming-Port", baseName: "Bluetooth-Incoming-Port", parent: .bluetooth),
    ]

    private var serialCount: Int { DeviceCatalog.models(for: .serial).count }

    // MARK: - Mapping

    func testBuiltInPortsAndTheBluetoothListeningPortAreHidden() {
        XCTAssertEqual(RegistrySnapshot(ports: Self.macPorts).endpoints, [])
        // macOS names the listening port in the path even when the base name is missing.
        let unnamed = Port(calloutPath: "/dev/cu.Bluetooth-Incoming-Port", parent: .bluetooth)
        XCTAssertEqual(RegistrySnapshot(ports: [unnamed]).endpoints, [])
    }

    func testAUSBPortCarriesItsAdapterAndHint() throws {
        let snapshot = RegistrySnapshot(ports: Self.macPorts + [Port(calloutPath: "/dev/cu.usbserial-SUUNTO01",
                                                                     baseName: "usbserial-SUUNTO01", parent: .usb(Self.suunto))],
                                        cableDevices: [Self.suunto])
        let endpoint = try XCTUnwrap(snapshot.endpoints.first)
        XCTAssertEqual(snapshot.endpoints.count, 1)
        XCTAssertEqual(endpoint.id, "/dev/cu.usbserial-SUUNTO01")
        XCTAssertEqual(endpoint.transport, .serial)
        XCTAssertEqual(endpoint.calloutPath, "/dev/cu.usbserial-SUUNTO01")
        XCTAssertEqual(endpoint.vendorID, 0x0403)
        XCTAssertEqual(endpoint.productID, 0xF680)
        XCTAssertEqual(endpoint.usbSerialNumber, "SUUNTO01")
        XCTAssertEqual(endpoint.productName, "Suunto USB Serial Cable")
        XCTAssertEqual(endpoint.status, .ready)
        XCTAssertEqual(endpoint.hint?.brand, "Suunto")
        XCTAssertEqual(endpoint.displayName, "Suunto USB cable")
        XCTAssertEqual(endpoint.locator, .serial(path: "/dev/cu.usbserial-SUUNTO01", usbSerial: "SUUNTO01", vid: 0x0403, pid: 0xF680))
        XCTAssertEqual(endpoint.locator?.unitStandIn, "adapter:0403:f680:SUUNTO01")
        XCTAssertFalse(endpoint.candidates.isEmpty)
        XCTAssertTrue(endpoint.candidates.allSatisfy { $0.vendor == "Suunto" }, "\(endpoint.candidates.map(\.name))")
        XCTAssertTrue(endpoint.candidates.contains { $0.name == "Suunto Vyper" })
        XCTAssertTrue(endpoint.candidates.contains { $0.name == "Suunto D9" })
        XCTAssertEqual(endpoint.candidates.first?.family, .suuntoD9)
    }

    func testAKnownCableWithNoPortIsDriverMissing() throws {
        let endpoints = RegistrySnapshot(cableDevices: [Self.pelagic]).endpoints
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoint.status, .driverMissing)
        XCTAssertEqual(endpoint.id, "usb:22")
        XCTAssertNil(endpoint.calloutPath)
        XCTAssertNil(endpoint.locator)
        XCTAssertEqual(endpoint.usbSerialNumber, "PELAGIC1")
        let hint = try XCTUnwrap(endpoint.hint)
        XCTAssertTrue(hint.needsVendorDriver)
        XCTAssertEqual(hint.driverURL?.host, "ftdichip.com")
        XCTAssertTrue(endpoint.candidates.allSatisfy { [.oceanicAtom2, .oceanicVeo250, .oceanicVtpro].contains($0.family) })
        XCTAssertTrue(endpoint.candidates.contains { $0.name == "Oceanic Atom 2.0" })
    }

    func testADriverMissingEndpointSaysWhichDriverAndWhere() throws {
        let pelagic = try XCTUnwrap(RegistrySnapshot(cableDevices: [Self.pelagic]).endpoints.first)
        let message = try XCTUnwrap(pelagic.driverMissingMessage)
        XCTAssertTrue(message.contains("Oceanic/Pelagic USB cable"), message)
        XCTAssertTrue(message.contains("https://ftdichip.com/"), message)
        // macOS 26.4 drives the Suunto cable itself; an older macOS might not, so it still gets FTDI's page.
        let suunto = try XCTUnwrap(RegistrySnapshot(cableDevices: [Self.suunto]).endpoints.first)
        XCTAssertEqual(suunto.status, .driverMissing)
        XCTAssertEqual(suunto.hint?.needsVendorDriver, false)
        let fallback = try XCTUnwrap(suunto.driverMissingMessage)
        XCTAssertTrue(fallback.contains("Unplug it and plug it in again"), fallback)
        XCTAssertTrue(fallback.contains("https://ftdichip.com/"), fallback)
        let cp210x = try XCTUnwrap(RegistrySnapshot(cableDevices: [Self.cp210x]).endpoints.first)
        XCTAssertNil(cp210x.hint?.driverURL)
        XCTAssertTrue(try XCTUnwrap(cp210x.driverMissingMessage).contains("Silicon Labs CP210x"))
        XCTAssertNil(CableEndpoint.serialPort(path: "/dev/cu.usbserial-A", vendorID: 0x0403, productID: 0x6001).driverMissingMessage)
    }

    func testAKnownCableWithAPortIsReady() throws {
        // The same Pelagic cable once the chip maker's driver has made its port.
        let snapshot = RegistrySnapshot(ports: [Port(calloutPath: "/dev/cu.usbserial-PELAGIC1", parent: .usb(Self.pelagic))],
                                        cableDevices: [Self.pelagic])
        XCTAssertEqual(snapshot.endpoints.map(\.status), [.ready])
        XCTAssertEqual(snapshot.endpoints.first?.id, "/dev/cu.usbserial-PELAGIC1")
    }

    func testGenericChipsAndUnknownAdaptersOfferEverySerialModel() throws {
        let snapshot = RegistrySnapshot(ports: [
            Port(calloutPath: "/dev/cu.SLAB_USBtoUART", parent: .usb(Self.cp210x)),
            Port(calloutPath: "/dev/cu.usbmodem1101", parent: .usb(Self.arduino)),
            CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER"),
        ])
        let byPath = Dictionary(uniqueKeysWithValues: snapshot.endpoints.map { ($0.id, $0) })
        let cp210x = try XCTUnwrap(byPath["/dev/cu.SLAB_USBtoUART"])
        XCTAssertEqual(cp210x.hint?.name, "Silicon Labs CP210x")
        XCTAssertNil(cp210x.hint?.brand)
        XCTAssertEqual(cp210x.candidates.count, serialCount)

        let unknown = try XCTUnwrap(byPath["/dev/cu.usbmodem1101"])
        XCTAssertNil(unknown.hint)
        XCTAssertEqual(unknown.displayName, "Arduino Uno")
        XCTAssertEqual(unknown.candidates.count, serialCount)

        // An FTDI FT232R is in many cables, so OSTC models only go first.
        let ftdi = try XCTUnwrap(byPath["/dev/cu.usbserial-TESTADAPTER"])
        XCTAssertEqual(ftdi.candidates.count, serialCount)
        XCTAssertEqual(ftdi.candidates.first?.family, .hwOstc)
        XCTAssertEqual(Set(ftdi.candidates.map(\.id)).count, serialCount, "no model is offered twice")
    }

    func testAPairedBluetoothPortIsClassicBluetoothSerial() throws {
        let snapshot = RegistrySnapshot(ports: Self.macPorts + [
            Port(calloutPath: "/dev/cu.Petrel-SerialPort", baseName: "Petrel-SerialPort", parent: .bluetooth),
        ])
        let endpoint = try XCTUnwrap(snapshot.endpoints.first)
        XCTAssertEqual(snapshot.endpoints.count, 1)
        XCTAssertEqual(endpoint.transport, .classicBTSerial)
        XCTAssertEqual(endpoint.locator, .classicBTSerial(path: "/dev/cu.Petrel-SerialPort"))
        XCTAssertNil(endpoint.hint)
        XCTAssertEqual(endpoint.candidates, DeviceCatalog.models(for: .classicBTSerial))
        XCTAssertFalse(endpoint.candidates.isEmpty)
    }

    func testEndpointsAreOrderedKnownCablesFirst() {
        let snapshot = RegistrySnapshot(ports: [
            Port(calloutPath: "/dev/cu.Petrel-SerialPort", parent: .bluetooth),
            Port(calloutPath: "/dev/cu.usbmodem1101", parent: .usb(Self.arduino)),
            Port(calloutPath: "/dev/cu.usbserial-SUUNTO01", parent: .usb(Self.suunto)),
            Port(calloutPath: "/dev/cu.SLAB_USBtoUART", parent: .usb(Self.cp210x)),
        ], cableDevices: [Self.suunto, Self.pelagic, Self.cp210x])
        XCTAssertEqual(snapshot.endpoints.map(\.id), [
            "/dev/cu.SLAB_USBtoUART", "/dev/cu.usbserial-SUUNTO01", // hinted ports, by path
            "/dev/cu.usbmodem1101",                                 // other USB ports
            "usb:22",                                               // known cables with no port
            "/dev/cu.Petrel-SerialPort",                            // paired Bluetooth
        ])
    }

    func testAnUnhintedUSBDeviceWithNoPortIsNotListed() {
        XCTAssertEqual(RegistrySnapshot(cableDevices: [Self.arduino]).endpoints, [])
    }

    func testAnEmptyAdapterSerialIsNone() {
        let device = USB(registryID: 1, vendorID: 0x1A86, productID: 0x7523, serialNumber: "")
        let endpoint = RegistrySnapshot(ports: [Port(calloutPath: "/dev/cu.wchusbserial10", parent: .usb(device))]).endpoints.first
        XCTAssertNil(endpoint?.usbSerialNumber)
        XCTAssertEqual(endpoint?.locator?.locatorKey, "serial:/dev/cu.wchusbserial10")
        XCTAssertNil(endpoint?.locator?.unitStandIn)
    }

    // MARK: - Hints

    func testTheHintTable() throws {
        func hint(_ vid: UInt16, _ pid: UInt16) throws -> CableHint { try XCTUnwrap(CableHints.hint(vendorID: vid, productID: pid)) }
        let suunto = try hint(0x0403, 0xF680)
        XCTAssertEqual(suunto.brand, "Suunto")
        XCTAssertTrue(suunto.exclusive)
        XCTAssertFalse(suunto.needsVendorDriver)
        XCTAssertEqual(suunto.driverURL?.host, "ftdichip.com", "the fallback if macOS's own driver made no port")
        let cressi = try hint(0x0403, 0x87D0)
        XCTAssertEqual(cressi.driverURL?.host, "ftdichip.com")
        XCTAssertEqual(cressi.brand, "Cressi")
        XCTAssertTrue(cressi.exclusive)
        XCTAssertTrue(cressi.candidates.contains { $0.name == "Cressi Leonardo" })
        let pelagic = try hint(0x0403, 0xF460)
        XCTAssertTrue(pelagic.needsVendorDriver)
        XCTAssertNotNil(pelagic.driverURL)
        for pid: UInt16 in [0x6015, 0x6001] {
            let ostc = try hint(0x0403, pid)
            XCTAssertEqual(ostc.brand, "Heinrichs Weikamp")
            XCTAssertFalse(ostc.exclusive)
            XCTAssertEqual(ostc.families.first, .hwOstc)
            XCTAssertEqual(ostc.driverURL?.host, "ftdichip.com")
        }
        for (vid, pid) in [(0x10C4, 0xEA60), (0x10C4, 0xEA70), (0x067B, 0x2303), (0x067B, 0x2304), (0x1A86, 0x7523), (0x1A86, 0x55D4)] {
            let chip = try hint(UInt16(vid), UInt16(pid))
            XCTAssertNil(chip.brand)
            XCTAssertTrue(chip.families.isEmpty)
            XCTAssertFalse(chip.exclusive)
            XCTAssertFalse(chip.needsVendorDriver)
            XCTAssertNil(chip.driverURL)
        }
        XCTAssertNil(CableHints.hint(vendorID: 0x0403, productID: 0x6010), "multi-channel FTDI chips are JTAG adapters, not dive cables")
        XCTAssertEqual(CableHints.vendorIDs, [0x0403, 0x10C4, 0x067B, 0x1A86])
        XCTAssertEqual(Set(CableHints.all.map { "\($0.vendorID):\($0.productID)" }).count, CableHints.all.count)
    }

    func testExclusiveHintsOfferOnlyTheirFamiliesInTheirOrder() {
        for hint in CableHints.all where hint.exclusive {
            XCTAssertFalse(hint.candidates.isEmpty, hint.name)
            XCTAssertTrue(hint.candidates.allSatisfy { hint.families.contains($0.family) }, hint.name)
            let order = hint.candidates.map { hint.families.firstIndex(of: $0.family)! }
            XCTAssertEqual(order, order.sorted(), hint.name)
            XCTAssertTrue(hint.candidates.allSatisfy { $0.transports.contains(.serial) }, hint.name)
        }
    }

    // MARK: - Feed

    /// Collects what `stream` yields for `duration`, running `body` once the current endpoints have arrived.
    private func collect(_ stream: AsyncStream<[CableEndpoint]>, for duration: TimeInterval,
                         while body: () -> Void = {}) -> [[CableEndpoint]] {
        let box = Collected()
        let first = expectation(description: "current endpoints")
        let task = Task {
            var fulfilled = false
            for await value in stream {
                box.append(value)
                if !fulfilled { fulfilled = true; first.fulfill() }
            }
        }
        wait(for: [first], timeout: 2)
        body()
        let waited = expectation(description: "collect")
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) { waited.fulfill() }
        wait(for: [waited], timeout: duration + 2)
        task.cancel()
        return box.values
    }

    /// Both are lock-protected; the test hands them to concurrentPerform.
    private struct Racers: @unchecked Sendable {
        let claims: SerialPortClaims
        let feed: CableEndpointFeed
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[CableEndpoint]] = []
        var values: [[CableEndpoint]] { lock.lock(); defer { lock.unlock() }; return all }
        func append(_ value: [CableEndpoint]) { lock.lock(); all.append(value); lock.unlock() }
    }

    func testUpdatesYieldTheCurrentEndpointsThenEachChange() {
        let first = CableEndpoint.serialPort(path: "/dev/cu.usbserial-A", vendorID: 0x0403, productID: 0x6001)
        let second = CableEndpoint.serialPort(path: "/dev/cu.usbserial-B", vendorID: 0x0403, productID: 0x6001)
        let discovery = StaticCableDiscovery(endpoints: [first])
        let seen = collect(discovery.updates(), for: 0.3) {
            discovery.setEndpoints([first, second])
            discovery.setEndpoints([first, second])
            discovery.remove(id: first.id)
        }
        XCTAssertEqual(seen.map { $0.map(\.id) }, [[first.id], [first.id, second.id], [second.id]],
                       "an unchanged list isn't published again")
        XCTAssertEqual(discovery.endpoints, [second])
    }

    func testAStreamEndsWithItsDiscovery() {
        var discovery: StaticCableDiscovery? = StaticCableDiscovery()
        let stream = discovery!.updates()
        let ended = expectation(description: "ended")
        let task = Task {
            for await _ in stream {}
            ended.fulfill()
        }
        discovery = nil
        wait(for: [ended], timeout: 2)
        task.cancel()
    }

    func testClaimedPortsShowBusyInEveryDiscovery() throws {
        let claims = SerialPortClaims()
        let feedA = CableEndpointFeed(claims: claims)
        let feedB = CableEndpointFeed(claims: claims)
        let endpoint = CableEndpoint.serialPort(path: "/dev/cu.usbserial-A", vendorID: 0x0403, productID: 0x6001)
        let missing = try XCTUnwrap(RegistrySnapshot(cableDevices: [Self.pelagic]).endpoints.first)
        feedA.replace([endpoint, missing])
        feedB.replace([endpoint])
        claims.claim("/dev/cu.usbserial-A")
        XCTAssertEqual(feedA.endpoints.map(\.status), [.busy, .driverMissing])
        XCTAssertEqual(feedB.endpoints.map(\.status), [.busy])
        XCTAssertEqual(feedA.baseEndpoints.map(\.status), [.ready, .driverMissing])
        claims.claim("/dev/cu.usbserial-A")
        claims.release("/dev/cu.usbserial-A")
        XCTAssertEqual(feedA.endpoints.first?.status, .busy, "busy until every claim is released")
        claims.release("/dev/cu.usbserial-A")
        XCTAssertEqual(feedA.endpoints.map(\.status), [.ready, .driverMissing])
        XCTAssertEqual(feedB.endpoints.map(\.status), [.ready])
    }

    func testConcurrentRepublishesEndOnTheLatestState() async throws {
        let claims = SerialPortClaims()
        let feed = CableEndpointFeed(claims: claims)
        let endpoint = CableEndpoint.serialPort(path: "/dev/cu.usbserial-A", vendorID: 0x0403, productID: 0x6001)
        let path = try XCTUnwrap(endpoint.calloutPath)
        feed.replace([endpoint])
        let stream = feed.updates()
        let racers = Racers(claims: claims, feed: feed)
        // A claim released on one thread while a registry read republishes on another.
        DispatchQueue.concurrentPerform(iterations: 20_000) { i in
            if i % 2 == 0 {
                racers.claims.claim(path)
                racers.claims.release(path)
            } else {
                racers.feed.replace([endpoint])
            }
        }
        XCTAssertEqual(feed.endpoints.map(\.status), [.ready])
        var newest = stream.makeAsyncIterator()
        let last = await newest.next()
        XCTAssertEqual(last?.map(\.status), [.ready], "the last value yielded is the published one")
    }

    // MARK: - IOKitCableDiscovery over a fake registry

    /// A Reefnet Sensus session on a backend that answers everything; its open only sets up the line.
    private func makeSession() throws -> DiveComputerSession {
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        let stream = try DCCustomStream.open(backend: ProbeBackend(), transport: DC_TRANSPORT_SERIAL, context: context)
        return try DiveComputerSession.open(
            iostream: stream, context: try XCTUnwrap(context), family: DC_FAMILY_REEFNET_SENSUS, model: 1,
            displayName: "Reefnet Sensus", storageKey: "serial:test",
            deviceStorage: DeviceStorage(userDefaults: isolatedDefaults("dev")), lease: DiveComputerSessionLease())
    }

    private func session() throws -> DiveComputerSession {
        let session = try makeSession()
        addTeardownBlock { session.close() }
        return session
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { usleep(5_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testStartReadsTheRegistryBeforeItReturns() {
        let source = FakeRegistrySource(RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")],
                                                         cableDevices: [CableFixtures.ftdiOSTC]))
        let discovery = IOKitCableDiscovery(source: source, settle: .milliseconds(0))
        XCTAssertEqual(discovery.endpoints, [])
        discovery.start()
        XCTAssertEqual(discovery.endpoints.map(\.id), ["/dev/cu.usbserial-TESTADAPTER"])
        XCTAssertTrue(source.isWatching)
        discovery.start()
        XCTAssertEqual(source.snapshotCount, 1, "a second start is a no-op")
        discovery.stop()
        XCTAssertFalse(source.isWatching)
    }

    func testARemovalIsReadAtOnce() {
        let source = FakeRegistrySource(RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")]))
        let discovery = IOKitCableDiscovery(source: source, settle: .seconds(30))
        discovery.start()
        source.emit(.removed, RegistrySnapshot())
        waitUntil { discovery.endpoints.isEmpty }
    }

    func testArrivalsSettleBeforeTheRegistryIsReadAgain() {
        let source = FakeRegistrySource()
        let discovery = IOKitCableDiscovery(source: source, settle: .milliseconds(300))
        discovery.start()
        let seen = collect(discovery.updates(), for: 0.8) {
            // The adapter's USB device shows up first; its port follows a moment later.
            source.emit(.arrived, RegistrySnapshot(cableDevices: [CableFixtures.ftdiOSTC]))
            usleep(100_000)
            source.emit(.arrived, RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")],
                                                   cableDevices: [CableFixtures.ftdiOSTC]))
        }
        XCTAssertEqual(seen.map { $0.map(\.id) }, [[], ["/dev/cu.usbserial-TESTADAPTER"]])
        XCTAssertFalse(seen.joined().contains { $0.status == .driverMissing }, "never flashes driverMissing")
        XCTAssertEqual(source.snapshotCount, 2, "both arrivals are one read")
    }

    func testWithoutNotificationsRefreshStillReads() {
        let source = FakeRegistrySource()
        source.canWatch = false
        let discovery = IOKitCableDiscovery(source: source)
        discovery.start()
        source.set(RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")]))
        discovery.refresh()
        XCTAssertEqual(discovery.endpoints.count, 1)
    }

    func testAStoppedDiscoveryIgnoresTheRegistry() {
        let source = FakeRegistrySource()
        let discovery = IOKitCableDiscovery(source: source, settle: .milliseconds(0))
        discovery.start()
        discovery.stop()
        source.set(RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")]))
        discovery.refresh()
        XCTAssertEqual(discovery.endpoints, [])
    }

    func testRemovingAnEndpointCancelsOnlyTheSessionsOnIt() throws {
        let other = CableFixtures.usbPort("/dev/cu.usbserial-OTHER",
                                          RegistrySnapshot.USBDevice(registryID: 0x200, vendorID: 0x0403, productID: 0x6015))
        let source = FakeRegistrySource(RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER"), other]))
        let discovery = IOKitCableDiscovery(source: source)
        discovery.start()
        let pulled = try session()
        let kept = try session()
        discovery.cancelOnRemoval(of: "/dev/cu.usbserial-TESTADAPTER", session: pulled)
        discovery.cancelOnRemoval(of: other.calloutPath, session: kept)
        source.emit(.removed, RegistrySnapshot(ports: [other]))
        waitUntil { pulled.isCancelled }
        XCTAssertTrue(pulled.wasUnplugged)
        XCTAssertFalse(kept.isCancelled)
        XCTAssertFalse(kept.wasUnplugged)
    }

    func testAStoppedDiscoveryWatchesNothing() throws {
        let source = FakeRegistrySource(RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")]))
        let discovery = IOKitCableDiscovery(source: source)
        let session = try session()
        // Never started, so its empty list says nothing about this port.
        discovery.cancelOnRemoval(of: "/dev/cu.usbserial-TESTADAPTER", session: session)
        XCTAssertFalse(session.isCancelled)
        discovery.start()
        discovery.stop()
        discovery.cancelOnRemoval(of: "/dev/cu.usbserial-GONE", session: session)
        XCTAssertFalse(session.isCancelled)
    }

    func testWatchingAnEndpointThatIsAlreadyGoneCancelsAtOnce() throws {
        let discovery = StaticCableDiscovery()
        let session = try session()
        discovery.cancelOnRemoval(of: "/dev/cu.usbserial-GONE", session: session)
        XCTAssertTrue(session.isCancelled)
        XCTAssertTrue(session.wasUnplugged)
    }

    func testAReleasedSessionIsNotKeptByItsWatch() throws {
        let discovery = StaticCableDiscovery(endpoints: [CableEndpoint.serialPort(path: "/dev/cu.usbserial-A", vendorID: nil, productID: nil)])
        weak var released: DiveComputerSession?
        do {
            let session = try makeSession()
            discovery.cancelOnRemoval(of: "/dev/cu.usbserial-A", session: session)
            released = session
        }
        XCTAssertNil(released)
        discovery.remove(id: "/dev/cu.usbserial-A")
    }

    // MARK: - Live registry

    func testTheLiveRegistryReadsAndWatches() {
        let source = IOKitRegistrySource()
        let snapshot = source.snapshot()
        XCTAssertTrue(snapshot.ports.allSatisfy { $0.calloutPath.hasPrefix("/dev/cu.") }, "\(snapshot.ports.map(\.calloutPath))")
        let endpoints = snapshot.endpoints
        XCTAssertFalse(endpoints.contains { $0.id.hasSuffix("debug-console") || $0.id.hasSuffix("Bluetooth-Incoming-Port") })
        XCTAssertTrue(snapshot.cableDevices.allSatisfy { CableHints.hint(vendorID: $0.vendorID, productID: $0.productID) != nil })
        let queue = DispatchQueue(label: "test.registry")
        XCTAssertTrue(queue.sync { source.startWatching(on: queue) { _ in } })
        queue.sync { source.stopWatching() }

        let discovery = IOKitCableDiscovery()
        discovery.start()
        XCTAssertEqual(discovery.endpoints.map(\.id), endpoints.map(\.id))
        discovery.stop()
    }
}
#endif
