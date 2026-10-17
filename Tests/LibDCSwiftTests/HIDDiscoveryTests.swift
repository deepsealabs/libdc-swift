#if os(macOS)
import XCTest
import IOKit
import IOKit.hid
import Clibdivecomputer
@testable import LibDCSwift

/// USB HID dive computers in discovery: which HID devices become endpoints, and how they follow hot-plug.
final class HIDDiscoveryTests: XCTestCase {
    private static let eonSteel = RegistrySnapshot.HIDDevice(registryID: 0xE05, vendorID: 0x1493, productID: 0x0030,
                                                             serialNumber: "TESTSERIAL", productName: "EON Steel",
                                                             primaryUsagePage: 0xFF00)
    private static let d5 = RegistrySnapshot.HIDDevice(registryID: 0xD05, vendorID: 0x1493, productID: 0x0035, productName: "D5")
    private static let g2 = RegistrySnapshot.HIDDevice(registryID: 0x062, vendorID: 0x2e6c, productID: 0x3201, productName: "G2")
    private static let aladinSquare = RegistrySnapshot.HIDDevice(registryID: 0xA1A, vendorID: 0xc251, productID: 0x2006)
    // Same VIDs, but no model libdivecomputer knows.
    private static let suuntoWatch = RegistrySnapshot.HIDDevice(registryID: 0x0A3, vendorID: 0x1493, productID: 0x0019,
                                                                productName: "Ambit3")
    private static let debugProbe = RegistrySnapshot.HIDDevice(registryID: 0xDAB, vendorID: 0xc251, productID: 0xf002,
                                                               productName: "CMSIS-DAP")
    private static let keyboardPage = RegistrySnapshot.HIDDevice(registryID: 0xBAD, vendorID: 0x1493, productID: 0x0033,
                                                                 primaryUsagePage: 0x01)

    func testOnlyKnownHIDModelsBecomeEndpoints() throws {
        let snapshot = RegistrySnapshot(hidDevices: [Self.suuntoWatch, Self.g2, Self.debugProbe, Self.eonSteel, Self.keyboardPage,
                                                     Self.aladinSquare, Self.d5])
        let endpoints = snapshot.endpoints
        XCTAssertEqual(Set(endpoints.map(\.registryID)), [0xE05, 0xD05, 0x062, 0xA1A])
        XCTAssertTrue(endpoints.allSatisfy { $0.transport == .usbHID && $0.status == .ready && $0.calloutPath == nil })

        let steel = try XCTUnwrap(endpoints.first { $0.registryID == 0xE05 })
        XCTAssertEqual(steel.id, "usbhid:e05")
        XCTAssertEqual(steel.candidates.map(\.name), ["Suunto EON Steel"])
        XCTAssertEqual(steel.displayName, "Suunto EON Steel")
        XCTAssertEqual(steel.usbSerialNumber, "TESTSERIAL")
        XCTAssertEqual(steel.locator, .usbHID(vid: 0x1493, pid: 0x0030, registryID: 0xE05))
        XCTAssertEqual(steel.locator?.locatorKey, "usbhid:1493:0030:e05")
        XCTAssertNil(steel.locator?.unitStandIn, "HID computers always report a serial")
        XCTAssertEqual(steel.claimKey, steel.id)
        XCTAssertNil(steel.driverMissingMessage)

        XCTAssertEqual(endpoints.first { $0.registryID == 0xD05 }?.candidates.map(\.name), ["Suunto D5"])
        XCTAssertEqual(endpoints.first { $0.registryID == 0xA1A }?.candidates.map(\.name), ["Scubapro Aladin Square"])
        XCTAssertEqual(endpoints.first { $0.registryID == 0xA1A }?.displayName, "Scubapro Aladin Square")
        XCTAssertEqual(endpoints.map(\.id), endpoints.map(\.id).sorted())
    }

    func testHIDComputersComeBeforeSerialPorts() {
        let snapshot = RegistrySnapshot(ports: [CableFixtures.usbPort("/dev/cu.usbserial-TESTADAPTER")],
                                        cableDevices: [CableFixtures.ftdiOSTC], hidDevices: [Self.eonSteel])
        XCTAssertEqual(snapshot.endpoints.map(\.transport), [.usbHID, .serial])
    }

    func testTheHIDVendorsAreExactlyTheVendorsOfTheHIDModels() {
        let hidModelVendors = Set(DeviceCatalog.usbModels.keys.map { UInt16($0 >> 16) })
        XCTAssertEqual(Set(HIDVendors.vendorIDs), hidModelVendors)
        XCTAssertEqual(HIDVendors.vendorIDs, [0x1493, 0x2e6c, 0xc251])
        for key in DeviceCatalog.usbModels.keys {
            let candidates = DeviceCatalog.candidates(vid: UInt16(key >> 16), pid: UInt16(key & 0xffff), transport: .usbHID)
            XCTAssertFalse(candidates.isEmpty, String(format: "%08x", key))
        }
    }

    func testAnEndpointOnlyForAKnownModel() {
        XCTAssertNil(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x1493, productID: 0x0019))
        XCTAssertNil(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x0403, productID: 0x6001))
        XCTAssertNil(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x2e6c, productID: 0x9999), "G3 has no PID in libdivecomputer's table")
        XCTAssertNotNil(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x2e6c, productID: 0x4201))
        XCTAssertNil(CableEndpoint.usbHIDDevice(registryID: 1, vendorID: 0x1493, productID: 0x0030, serialNumber: "")?.usbSerialNumber)
    }

    func testAClaimedHIDDeviceIsBusy() {
        let claims = EndpointClaims()
        let snapshot = RegistrySnapshot(hidDevices: [Self.eonSteel, Self.g2])
        let feed = CableEndpointFeed(claims: claims)
        feed.replace(snapshot.endpoints)
        claims.claim("usbhid:e05")
        XCTAssertEqual(feed.endpoints.first { $0.id == "usbhid:e05" }?.status, .busy)
        XCTAssertEqual(feed.endpoints.first { $0.id == "usbhid:62" }?.status, .ready)
        claims.release("usbhid:e05")
        XCTAssertEqual(feed.endpoints.first { $0.id == "usbhid:e05" }?.status, .ready)
    }

    // MARK: - Live

    func testListingHIDDevicesTouchesOnlyDiveVendorsAndNeverAsksForInputMonitoring() {
        let before = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let snapshot = IOKitRegistrySource().snapshot()
        for device in snapshot.hidDevices {
            XCTAssertTrue(HIDVendors.vendorIDs.contains(device.vendorID), String(format: "%04x", device.vendorID))
        }
        let discovery = IOKitCableDiscovery()
        discovery.start()
        discovery.stop()
        XCTAssertEqual(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent), before, "no Input Monitoring request was made")
    }

    func testTheLiveSourceWatchesAndStopsAgain() {
        let source = IOKitRegistrySource()
        let queue = DispatchQueue(label: "test.hid.watch")
        for _ in 0..<3 {
            XCTAssertTrue(queue.sync { source.startWatching(on: queue) { _ in } })
            _ = queue.sync { source.snapshot() }
            queue.sync { source.stopWatching() }
        }
        queue.sync {}
    }
}
#endif
