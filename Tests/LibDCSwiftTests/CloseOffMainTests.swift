import XCTest
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A device's close runs its quit exchange over the link and waits on BLE
/// callbacks that are delivered on main, so `close()` must run it elsewhere,
/// keep the link up until it returns, and only then cancel the link.
final class CloseOffMainTests: XCTestCase {

    private final class EventLog {
        private let lock = NSLock()
        private var events: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
        func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
        func contains(_ event: String) -> Bool { all.contains(event) }
    }

    private final class Flag {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ value: Bool) { lock.lock(); _value = value; lock.unlock() }
    }

    private var fakeDevices: [UnsafeMutableRawPointer] = []

    override func tearDown() {
        fakeDevices.forEach { $0.deallocate() }
        fakeDevices = []
        super.tearDown()
    }

    /// Zeroed memory stands in for the `dc_device_t`, so the cancel check a held-back close sets lands harmlessly.
    @discardableResult
    private func openDevice(on manager: CoreBluetoothManager) -> UnsafeMutablePointer<device_data_t> {
        let device = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 16)
        device.initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
        fakeDevices.append(device)
        let devicePtr = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        devicePtr.initialize(to: device_data_t())
        devicePtr.pointee.device = OpaquePointer(device)
        manager.openedDeviceDataPtr = devicePtr
        return devicePtr
    }

    /// CBPeripheral has no public initializer; an allocated instance stands in for the link by identity.
    /// Never released, since it was never initialized.
    private func makePeripheral() -> CBPeripheral {
        let peripheralClass: AnyObject = CBPeripheral.self
        return peripheralClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! CBPeripheral
    }

    /// A link with its write and notify characteristics, and a device close that blocks until `release` is
    /// signalled. Capped, so a close that runs on main fails the test instead of hanging it.
    private func makeLinkedManager(events: EventLog, release: DispatchSemaphore) -> (CoreBluetoothManager, CBPeripheral) {
        let manager = CoreBluetoothManager(withoutCentral: ())
        openDevice(on: manager)
        let peripheral = makePeripheral()
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: "FFF1"),
                                                     properties: [.writeWithoutResponse, .notify],
                                                     value: nil, permissions: [.writeable])
        manager.peripheral = peripheral
        manager.writeCharacteristic = characteristic
        manager.notifyCharacteristic = characteristic
        manager.closeDevice = { [unowned manager] _ in
            let linkUp = manager.peripheral === peripheral
                && manager.writeCharacteristic != nil && manager.notifyCharacteristic != nil
            events.append(linkUp ? "close: link up" : "close: link gone")
            _ = release.wait(timeout: .now() + 3)
            events.append("close returned")
        }
        manager.cancelConnection = { cancelled in
            events.append(cancelled === peripheral ? "cancel" : "cancel: another peripheral")
        }
        return (manager, peripheral)
    }

    /// Runs main, where the teardown's last step and the CoreBluetooth callbacks land.
    private func spinMain(until condition: () -> Bool, timeout: TimeInterval = 5,
                          file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func spinMain(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - close() on main

    func testCloseOnMainReturnsWhileTheDeviceCloseBlocks() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        openDevice(on: manager)
        let closed = Flag()
        let closedOnMain = Flag()
        manager.closeDevice = { _ in
            closedOnMain.set(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 3)
            closed.set(true)
        }

        XCTAssertTrue(Thread.isMainThread)
        let start = Date()
        manager.close(clearDevicePtr: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "close() doesn't wait for the device's close")
        XCTAssertNil(manager.openedDeviceDataPtr, "the host never sees a device that is being freed")
        XCTAssertTrue(manager.isTearingDown)
        XCTAssertTrue(manager.isDisconnecting)

        spinMain(until: { !manager.isTearingDown }, timeout: 6)
        XCTAssertTrue(closed.value)
        XCTAssertFalse(closedOnMain.value)
        XCTAssertFalse(manager.isDisconnecting)
    }

    func testLinkStaysUpUntilTheDeviceCloseReturnsAndIsThenCancelled() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, peripheral) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        XCTAssertTrue(manager.peripheral === peripheral, "the quit command still needs the link")
        XCTAssertNotNil(manager.writeCharacteristic)
        XCTAssertNotNil(manager.notifyCharacteristic)

        spinMain(until: { events.contains("close: link up") || events.contains("close: link gone") })
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["close: link up"], "no cancel while the device's close runs")

        release.signal()
        spinMain(until: { !manager.isTearingDown })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel"])
        XCTAssertNil(manager.peripheral)
        XCTAssertNil(manager.writeCharacteristic)
        XCTAssertNil(manager.notifyCharacteristic)
        XCTAssertFalse(manager.isDisconnecting)
    }

    func testSecondCloseWhileClosingDoesNotCancelEarly() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, peripheral) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })
        manager.close(clearDevicePtr: true)
        manager.close()
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["close: link up"], "a repeated close must not cut off the quit command")
        XCTAssertTrue(manager.peripheral === peripheral)
        XCTAssertTrue(manager.isTearingDown)

        release.signal()
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel"], "one device close, one cancel")
    }

    func testDeviceOpenedDuringTeardownIsClosedAfterItWithoutAnEarlyCancel() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })
        openDevice(on: manager)
        manager.close(clearDevicePtr: true)
        XCTAssertNil(manager.openedDeviceDataPtr)
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["close: link up"])

        release.signal()
        release.signal()
        spinMain(until: { events.all.filter { $0 == "close returned" }.count == 2 })
        spinMain(until: { !manager.isTearingDown })
        let all = events.all
        XCTAssertEqual(all.filter { $0 == "cancel" }.count, 1)
        XCTAssertEqual(Array(all.prefix(2)), ["close: link up", "close returned"],
                       "the link is cancelled after the first device's close, not before")
    }

    func testCloseWithNoLinkStillPublishesDisconnected() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        manager.isPeripheralReady = true

        manager.close()
        spinMain(until: { !manager.isTearingDown })
        XCTAssertFalse(manager.isPeripheralReady)
        XCTAssertNil(manager.connectedDevice)
        XCTAssertFalse(manager.isDisconnecting)
    }

    // MARK: - A close held back by a download

    func testDeferredCloseRunsTheDeviceCloseOffMainOnceTheDownloadEnds() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        let devicePtr = openDevice(on: manager)
        let closed = Flag()
        let closedOnMain = Flag()
        let cancelledDuringClose = Flag()
        manager.closeDevice = { [unowned manager] _ in
            closedOnMain.set(Thread.isMainThread)
            cancelledDuringClose.set(manager.isIOCancelled())
            Thread.sleep(forTimeInterval: 3)
            closed.set(true)
        }
        manager.beginRetrieval(devicePtr)

        manager.close(clearDevicePtr: true)
        XCTAssertTrue(manager.openedDeviceDataPtr == devicePtr, "held back while the download uses the device")
        XCTAssertTrue(manager.isIOCancelled())

        let start = Date()
        manager.endRetrieval(devicePtr)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "the held-back close doesn't block main either")
        XCTAssertNil(manager.openedDeviceDataPtr)

        spinMain(until: { !manager.isTearingDown }, timeout: 6)
        XCTAssertTrue(closed.value)
        XCTAssertFalse(closedOnMain.value)
        XCTAssertFalse(cancelledDuringClose.value, "the quit command goes out with I/O no longer cancelled")
    }

    // MARK: - Opening waits for the old link

    func testOpenWaitsForAPendingTeardown() {
        assertOpenWaitsForAPendingTeardown()
    }

    /// The open then skips closing the open device, which would otherwise wait for the teardown too.
    func testOpenWaitsForAPendingTeardownWhileAnAutoDownloadHoldsTheLink() {
        let leased = Flag()
        Task.detached {
            try await NauticLinkLease.shared.acquire()
            leased.set(true)
        }
        spinMain(until: { leased.value })
        defer { NauticLinkLease.shared.release() }
        assertOpenWaitsForAPendingTeardown()
    }

    private func assertOpenWaitsForAPendingTeardown(file: StaticString = #filePath, line: UInt = #line) {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })

        let prepared = Flag()
        let preparedAfterClose = Flag()
        DispatchQueue.global(qos: .userInitiated).async {
            DeviceConfiguration.prepareLink(forOpening: "Test", on: manager)
            preparedAfterClose.set(events.contains("close returned"))
            prepared.set(true)
        }
        spinMain(for: 0.3)
        XCTAssertFalse(prepared.value, "an open waits while the old device's close is still on the link",
                       file: file, line: line)

        release.signal()
        spinMain(until: { prepared.value }, file: file, line: line)
        XCTAssertTrue(preparedAfterClose.value, file: file, line: line)
    }

    func testNauticSessionCloseReturnsOnlyAfterTheDeviceClose() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        let device = openDevice(on: manager).pointee.device!
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        manager.closeDevice = { _ in
            events.append("close")
            _ = release.wait(timeout: .now() + 3)
            events.append("close returned")
        }

        let returned = Flag()
        let returnedAfterClose = Flag()
        DispatchQueue.global(qos: .userInitiated).async {
            CoreBluetoothNauticConnector.closeSession(of: device, name: "Nautic", on: manager)
            returnedAfterClose.set(events.contains("close returned"))
            returned.set(true)
        }
        spinMain(until: { events.contains("close") })
        spinMain(for: 0.2)
        XCTAssertFalse(returned.value, "the session keeps the link until the device's close is done")

        release.signal()
        spinMain(until: { returned.value })
        XCTAssertTrue(returnedAfterClose.value)
        XCTAssertNil(manager.openedDeviceDataPtr)
    }
}
