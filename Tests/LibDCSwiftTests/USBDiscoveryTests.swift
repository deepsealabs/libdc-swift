#if os(macOS)
import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Raw USB dive computers in discovery and the catalog: which USB devices become endpoints, where they list, and which models are beta.
final class USBDiscoveryTests: XCTestCase {
    private typealias USB = RegistrySnapshot.USBDevice

    private static let cobaltID: UInt64 = 0x1_0000_0C0B
    private static let cobaltDevice = USB(registryID: cobaltID, vendorID: 0x0471, productID: 0x0888)
    private static let named = USB(registryID: 0xC0B2, vendorID: 0x0471, productID: 0x0888, serialNumber: "", productName: "COBALT")
    // Philips/NXP's vendor ID, but no model libdivecomputer knows.
    private static let otherNXP = USB(registryID: 0x0E1, vendorID: 0x0471, productID: 0x0999, productName: "Webcam")

    private static var cobaltEndpoint: CableEndpoint {
        CableEndpoint.usbDevice(registryID: cobaltID, vendorID: 0x0471, productID: 0x0888)!
    }

    func testOnlyKnownUSBComputersBecomeEndpoints() throws {
        let endpoints = RegistrySnapshot(usbComputers: [Self.otherNXP, Self.cobaltDevice]).endpoints
        XCTAssertEqual(endpoints.count, 1)
        let cobalt = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(cobalt.transport, .usb)
        XCTAssertEqual(cobalt.id, "usbdevice:" + String(Self.cobaltID, radix: 16))
        XCTAssertEqual(cobalt.registryID, Self.cobaltID)
        XCTAssertNil(cobalt.calloutPath)
        XCTAssertNil(cobalt.hint)
        XCTAssertEqual(cobalt.status, .ready)
        XCTAssertEqual(cobalt.candidates.map(\.name), ["Atomic Aquatics Cobalt", "Atomic Aquatics Cobalt 2"])
        XCTAssertEqual(cobalt.displayName, "Atomic Aquatics Cobalt or Atomic Aquatics Cobalt 2")
        XCTAssertEqual(cobalt.locator, .usb(vid: 0x0471, pid: 0x0888, registryID: Self.cobaltID))
        XCTAssertEqual(cobalt.locator?.locatorKey, "usb:0471:0888:" + String(Self.cobaltID, radix: 16))
        XCTAssertNil(cobalt.locator?.unitStandIn, "the Cobalt reports its own serial")
        XCTAssertEqual(cobalt.claimKey, cobalt.id)
        XCTAssertNil(cobalt.driverMissingMessage)

        let withName = try XCTUnwrap(RegistrySnapshot(usbComputers: [Self.named]).endpoints.first)
        XCTAssertEqual(withName.displayName, "COBALT", "the device's own product name")
        XCTAssertNil(withName.usbSerialNumber, "an empty serial is none")
    }

    func testUSBComputersListAfterHIDComputersAndBeforeSerialPorts() {
        let hid = RegistrySnapshot.HIDDevice(registryID: 0xE05, vendorID: 0x1493, productID: 0x0030, productName: "EON Steel")
        let snapshot = RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")],
                                        cableDevices: [CableFixtures.ftdiOSTC], hidDevices: [hid],
                                        usbComputers: [Self.cobaltDevice])
        XCTAssertEqual(snapshot.endpoints.map(\.transport), [.usbHID, .usb, .serial])
    }

    func testAClaimedCobaltIsBusy() {
        let claims = EndpointClaims()
        let feed = CableEndpointFeed(claims: claims)
        feed.replace(RegistrySnapshot(usbComputers: [Self.cobaltDevice, Self.named]).endpoints)
        let id = Self.cobaltEndpoint.id
        claims.claim(id)
        XCTAssertEqual(feed.endpoints.first { $0.id == id }?.status, .busy)
        XCTAssertEqual(feed.endpoints.first { $0.id != id }?.status, .ready)
        claims.release(id)
        XCTAssertEqual(feed.endpoints.first { $0.id == id }?.status, .ready)
    }

    func testAnArrivalAndARemovalInTheRegistryAreFollowed() {
        let source = FakeRegistrySource()
        let discovery = IOKitCableDiscovery(source: source, settle: .milliseconds(10))
        discovery.start()
        defer { discovery.stop() }
        XCTAssertTrue(discovery.endpoints.isEmpty)
        source.emit(.arrived, RegistrySnapshot(usbComputers: [Self.cobaltDevice]))
        XCTAssertTrue(waitFor { discovery.endpoints.map(\.id) == [Self.cobaltEndpoint.id] })
        source.emit(.removed, RegistrySnapshot())
        XCTAssertTrue(waitFor { discovery.endpoints.isEmpty })
    }

    // MARK: - Layout table

    func testTheLayoutTableIsUSBCsAndCoversEveryUSBModel() {
        XCTAssertEqual(USBComputers.all, [USBInterfaceLayout(vendorID: 0x0471, productID: 0x0888, interfaceNumber: 0,
                                                             endpointIn: 0x82, endpointOut: 0x02)],
                       "usb.c's g_usb_config")
        XCTAssertEqual(USBComputers.vendorIDs, [0x0471])
        let reachable = Set(USBComputers.all.flatMap {
            DeviceCatalog.candidates(vid: $0.vendorID, pid: $0.productID, transport: .usb)
        })
        XCTAssertEqual(reachable, Set(DeviceCatalog.models(for: .usb)), "every USB model has an interface to read it through")
        XCTAssertNil(USBComputers.layout(vendorID: 0x0471, productID: 0x0999))
    }

    // MARK: - Beta

    func testTheCobaltsAndShearwatersClassicBTAreBeta() throws {
        for transport in DCTransport.allCases {
            let beta = DeviceCatalog.models(for: transport).filter { $0.isBeta(on: transport) }.map(\.name)
            let expected: [String]
            switch transport {
            case .usb: expected = ["Atomic Aquatics Cobalt", "Atomic Aquatics Cobalt 2"]
            case .classicBTSerial: expected = ["Shearwater Predator", "Shearwater Petrel", "Shearwater Petrel 2",
                                               "Shearwater Nerd", "Shearwater Perdix"]
            default: expected = []
            }
            XCTAssertEqual(beta, expected, transport.rawValue)
        }
        let cobalt = try XCTUnwrap(DeviceCatalog.models(for: .usb).first { $0.name == "Atomic Aquatics Cobalt 2" })
        XCTAssertFalse(cobalt.isBeta(on: .ble))
        let perdix = try XCTUnwrap(DeviceCatalog.models(for: .classicBTSerial).first { $0.name == "Shearwater Perdix" })
        XCTAssertFalse(perdix.isBeta(on: .ble), "the same model isn't beta on its other transport")
        XCTAssertEqual(DeviceCatalog.betaFamilies, [.usb: [.atomicsCobalt], .classicBTSerial: [.shearwaterPetrel, .shearwaterPredator]])

        XCTAssertTrue(Self.cobaltEndpoint.isBeta)
        let pairedPetrel = CableEndpoint(id: "/dev/cu.Petrel-SerialPort", transport: .classicBTSerial,
                                         calloutPath: "/dev/cu.Petrel-SerialPort", candidates: DeviceCatalog.models(for: .classicBTSerial))
        XCTAssertTrue(pairedPetrel.isBeta)
        XCTAssertFalse(try XCTUnwrap(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x1493, productID: 0x0030)).isBeta)
        XCTAssertFalse(CableEndpoint.serialPort(path: "/dev/cu.usbserial-TESTADAPTER", vendorID: 0x0403, productID: 0xF680).isBeta)
        XCTAssertFalse(CableEndpoint(id: "x", transport: .usb, calloutPath: nil, candidates: []).isBeta, "no candidates is no beta")
    }

    // MARK: - Live

    func testALiveSnapshotListsOnlyKnownUSBComputers() {
        let snapshot = IOKitRegistrySource().snapshot()
        for device in snapshot.usbComputers {
            XCTAssertNotNil(USBComputers.layout(vendorID: device.vendorID, productID: device.productID),
                            String(format: "%04x:%04x", device.vendorID, device.productID))
        }
        for device in snapshot.cableDevices {
            XCTAssertNil(USBComputers.layout(vendorID: device.vendorID, productID: device.productID), "listed once, as a cable")
        }
    }
}
#endif
