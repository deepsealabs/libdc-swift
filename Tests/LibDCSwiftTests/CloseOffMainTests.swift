import XCTest
import Combine
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// A device's close runs its quit exchange over the link and waits on BLE callbacks that CoreBluetooth delivers on
/// main, so `close()` runs it on the manager's link queue, keeps the link up until it returns, and only then cancels
/// the link (APPLE-IOS-P: about 4 s of frozen main on Oceanic/Aqualung units, 3 s on OSTC).
final class CloseOffMainTests: XCTestCase {

    private final class EventLog {
        private let lock = NSLock()
        private var events: [String] = []
        private var times: [String: Date] = [:]
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
        func append(_ event: String) { lock.lock(); events.append(event); times[event] = Date(); lock.unlock() }
        func contains(_ event: String) -> Bool { all.contains(event) }
        func count(of event: String) -> Int { all.filter { $0 == event }.count }
        func time(of event: String) -> Date? { lock.lock(); defer { lock.unlock() }; return times[event] }
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

    /// CBPeripheral has no public initializer; an allocated instance stands in for the link by identity only.
    /// Never released, since it was never initialized.
    private func makePeripheral() -> CBPeripheral {
        let peripheralClass: AnyObject = CBPeripheral.self
        return peripheralClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! CBPeripheral
    }

    /// An open device on a connected link, with a device close that blocks until `release` is signalled. Capped, so
    /// a close that ran on main fails the test instead of hanging it.
    private func makeLinkedManager(events: EventLog, release: DispatchSemaphore,
                                   state: CBPeripheralState = .connected) -> (CoreBluetoothManager, CBPeripheral) {
        let manager = CoreBluetoothManager(withoutCentral: ())
        openDevice(on: manager)
        let peripheral = makePeripheral()
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: "FFF1"),
                                                     properties: [.writeWithoutResponse, .notify],
                                                     value: nil, permissions: [.writeable])
        manager.linkState.start()
        manager.peripheral = peripheral
        manager.writeCharacteristic = characteristic
        manager.notifyCharacteristic = characteristic
        manager.peripheralState = { _ in state }
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

    /// The quit's answer arrives through `didUpdateValueFor` on main, as CoreBluetooth delivers it. A close on main
    /// would sit on main until its read timed out, and the unit would never see its quit acknowledged.
    func testTheQuitsAnswerDeliveredOnMainReachesTheDeviceClose() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        openDevice(on: manager)
        let peripheral = makePeripheral()
        let ack = Data([0x5A])
        let answer = CBMutableCharacteristic(type: CBUUID(string: "FFF2"), properties: [.read],
                                             value: ack, permissions: [.readable])
        let events = EventLog()
        manager.closeDevice = { [unowned manager] _ in
            events.append("quit sent")
            DispatchQueue.main.async {
                manager.peripheral(peripheral, didUpdateValueFor: answer, error: nil)
            }
            events.append(manager.readDataPartial(64) == ack ? "quit answered" : "quit timed out")
        }

        let start = Date()
        manager.close(clearDevicePtr: true)
        spinMain(until: { !manager.isTearingDown }, timeout: 6)
        XCTAssertEqual(events.all, ["quit sent", "quit answered"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "answered at once, not after the 3 s read timeout")
    }

    func testLinkStaysUpUntilTheDeviceCloseReturnsThenSettlesAndIsCancelled() {
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
        XCTAssertTrue(manager.peripheral === peripheral)

        release.signal()
        spinMain(until: { !manager.isTearingDown })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel"])
        if let returned = events.time(of: "close returned"), let cancelled = events.time(of: "cancel") {
            XCTAssertGreaterThanOrEqual(cancelled.timeIntervalSince(returned), 0.45,
                                        "the quit's write gets the settle to flush before the cancel (Shearwater's WAIT CMD)")
        }
        XCTAssertNil(manager.peripheral)
        XCTAssertNil(manager.writeCharacteristic)
        XCTAssertNil(manager.notifyCharacteristic)
        XCTAssertFalse(manager.isDisconnecting)
    }

    func testDroppedLinkIsCancelledWithoutTheSettle() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release, state: .disconnected)
        manager.linkState.drop(peripheralState: .disconnected)
        release.signal()

        manager.close(clearDevicePtr: true)
        spinMain(until: { !manager.isTearingDown })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel"])
        if let returned = events.time(of: "close returned"), let cancelled = events.time(of: "cancel") {
            XCTAssertLessThan(cancelled.timeIntervalSince(returned), 0.3, "nothing to flush on a dropped link")
        }
    }

    /// iOS keeps a bonded watch's link, so a connect reuses the same CBPeripheral; the old close mustn't cancel it (#101).
    func testConnectSinceTheCloseKeepsItsLink() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, peripheral) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })
        manager.linkState.start()

        release.signal()
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.1)
        XCTAssertEqual(events.all, ["close: link up", "close returned"], "no cancel on the new link")
        XCTAssertTrue(manager.peripheral === peripheral, "the new link's handles stay")
        XCTAssertNotNil(manager.writeCharacteristic)
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

    /// The Nautic, EON Steel, OSTC3, Mares iconHD and Seac drivers close their iostream from inside their own close,
    /// which reaches `close()` through `ble_close` on the link queue.
    func testDriverClosingItsIostreamDuringItsCloseDoesNotCancelEarly() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, peripheral) = makeLinkedManager(events: events, release: release)
        manager.closeDevice = { [unowned manager] _ in
            events.append("quit sent")
            manager.close()
            events.append(manager.peripheral === peripheral ? "iostream closed: link up" : "iostream closed: link gone")
            _ = release.wait(timeout: .now() + 3)
            events.append("close returned")
        }

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("iostream closed: link up") || events.contains("iostream closed: link gone") })
        spinMain(for: 0.2)
        release.signal()
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.1)
        XCTAssertEqual(events.all, ["quit sent", "iostream closed: link up", "close returned", "cancel"])
    }

    func testDeviceOpenedDuringTeardownIsClosedAfterItWithoutAnEarlyCancel() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, peripheral) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })
        openDevice(on: manager)
        manager.close(clearDevicePtr: true)
        XCTAssertNil(manager.openedDeviceDataPtr)
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["close: link up"])

        release.signal()
        release.signal()
        spinMain(until: { events.count(of: "close: link up") == 2 })
        XCTAssertTrue(manager.peripheral === peripheral, "the first teardown leaves the link to the second device's close")
        XCTAssertTrue(manager.isDisconnecting)
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.1)
        XCTAssertEqual(events.all, ["close: link up", "close returned", "close: link up", "close returned", "cancel"],
                       "each device's quit goes out on the live link, and one cancel follows the last")
        if let returned = events.time(of: "close returned"), let cancelled = events.time(of: "cancel") {
            XCTAssertGreaterThanOrEqual(cancelled.timeIntervalSince(returned), 0.45, "the second quit gets its settle too")
        }
        XCTAssertNil(manager.peripheral)
        XCTAssertFalse(manager.isDisconnecting)
    }

    /// A connect that didn't wait (on main, or past its 30 s cap) makes a newer link; the old teardown skips its cancel.
    func testDeviceOnALinkConnectedDuringTeardownGetsItsOwnCloseAndCancel() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })
        manager.linkState.start()
        openDevice(on: manager)
        manager.close(clearDevicePtr: true)

        release.signal()
        release.signal()
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.1)
        XCTAssertEqual(events.all, ["close: link up", "close returned", "close: link up", "close returned", "cancel"])
        XCTAssertNil(manager.peripheral, "nothing is left holding connectedDevice for a host's next scan")
        XCTAssertFalse(manager.isDisconnecting)
    }

    /// `connectToBLEDevice` closes a link whose open failed; iOS never times out its pending connect.
    func testFailedConnectDuringTeardownStillHasItsLinkCancelled() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })
        manager.linkState.start()
        manager.close()
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["close: link up"], "not before the running close's quit is out")

        release.signal()
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.1)
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel"])
        XCTAssertNil(manager.peripheral)
    }

    /// A driver's `ble_close` belongs to the old device, not to a link a connect has made since.
    func testDriverClosingItsIostreamAfterAConnectLeavesTheNewLinkAlone() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, peripheral) = makeLinkedManager(events: events, release: release)
        manager.closeDevice = { [unowned manager] _ in
            events.append("quit sent")
            manager.linkState.start()
            manager.close()
            _ = release.wait(timeout: .now() + 3)
            events.append("close returned")
        }

        manager.close(clearDevicePtr: true)
        release.signal()
        spinMain(until: { !manager.isTearingDown })
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, ["quit sent", "close returned"], "no cancel on the new link")
        XCTAssertTrue(manager.peripheral === peripheral)
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
        manager.closeDevice = { [unowned manager] device in
            closedOnMain.set(Thread.isMainThread)
            cancelledDuringClose.set(manager.isIOCancelled() || libdc_device_is_cancelled(device) != 0)
            Thread.sleep(forTimeInterval: 3)
            closed.set(true)
        }
        manager.beginRetrieval(devicePtr)

        manager.close(clearDevicePtr: true)
        XCTAssertTrue(manager.openedDeviceDataPtr == devicePtr, "held back while the download uses the device")
        XCTAssertTrue(manager.isIOCancelled())
        XCTAssertNotEqual(libdc_device_is_cancelled(devicePtr.pointee.device), 0, "drivers polling the cancel stop too")

        let start = Date()
        manager.endRetrieval(devicePtr)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "the held-back close doesn't block main either")
        XCTAssertNil(manager.openedDeviceDataPtr)

        spinMain(until: { !manager.isTearingDown }, timeout: 6)
        XCTAssertTrue(closed.value)
        XCTAssertFalse(closedOnMain.value)
        XCTAssertFalse(cancelledDuringClose.value, "the driver sends its quit; a set cancel makes it skip it")
    }

    // MARK: - close(clearDevicePtr:completion:)

    func testCloseCompletionRunsOnMainOnceTheLinkIsCancelled() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)

        let completedOnMain = Flag()
        manager.close(clearDevicePtr: true) {
            completedOnMain.set(Thread.isMainThread)
            events.append("completion")
        }
        spinMain(until: { events.contains("close: link up") })
        spinMain(for: 0.2)
        XCTAssertFalse(events.contains("completion"))

        release.signal()
        spinMain(until: { events.contains("completion") })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel", "completion"])
        XCTAssertTrue(completedOnMain.value)
        XCTAssertFalse(manager.isTearingDown)
    }

    func testCloseCompletionWaitsForTheDownloadAndTheDeviceClose() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)
        let devicePtr = manager.openedDeviceDataPtr!
        manager.beginRetrieval(devicePtr)

        manager.close(clearDevicePtr: true) { events.append("completion") }
        manager.close(clearDevicePtr: true) { events.append("second completion") }
        spinMain(for: 0.2)
        XCTAssertEqual(events.all, [], "nothing closes while the download holds the device")

        manager.endRetrieval(devicePtr)
        spinMain(until: { events.contains("close: link up") })
        release.signal()
        spinMain(until: { events.contains("second completion") })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel", "completion", "second completion"])
    }

    func testCloseCompletionWithNothingOpenStillRuns() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        let completed = Flag()
        manager.close(clearDevicePtr: true) { completed.set(true) }
        spinMain(until: { completed.value })
        XCTAssertFalse(manager.isTearingDown)
    }

    // MARK: - Opening waits for the old link

    /// Every BLE open reaches the radio through `connect(toDevice:)` (`connectToBLEDevice` in the bridge), so an open
    /// with or without an auto download or session lease held waits there.
    func testConnectWaitsForTheDeviceCloseAndTheCancel() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)

        manager.close(clearDevicePtr: true)
        spinMain(until: { events.contains("close: link up") })

        let connected = Flag()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = manager.connect(toDevice: UUID().uuidString)
            events.append("connect")
            connected.set(true)
        }
        spinMain(for: 0.3)
        XCTAssertFalse(connected.value, "a connect waits while the old device's close is still on the link")

        release.signal()
        spinMain(until: { connected.value })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel", "connect"])
    }

    /// A connect on another thread that starts its wait just as the close begins, before the device's close is queued.
    func testConnectWaitingAsTheCloseBeginsWaitsForTheDeviceClose() {
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        let (manager, _) = makeLinkedManager(events: events, release: release)
        let connectStarted = Flag()
        let connected = Flag()
        let sink = manager.$isDisconnecting.sink { disconnecting in
            guard disconnecting, !connectStarted.value else { return }
            connectStarted.set(true)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = manager.connect(toDevice: UUID().uuidString)
                events.append("connect")
                connected.set(true)
            }
            // Main is held here, inside close(), so the connect's wait starts before the device's close is queued.
            Thread.sleep(forTimeInterval: 0.2)
        }
        defer { sink.cancel() }

        manager.close(clearDevicePtr: true)
        XCTAssertTrue(connectStarted.value)
        spinMain(until: { events.contains("close: link up") })
        spinMain(for: 0.3)
        XCTAssertFalse(connected.value, "the connect waits for the close that began under it")

        release.signal()
        spinMain(until: { connected.value })
        XCTAssertEqual(events.all, ["close: link up", "close returned", "cancel", "connect"])
    }

    func testCloseAndWaitForDisconnectWaitsForTheDeviceClose() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        openDevice(on: manager)
        let events = EventLog()
        let release = DispatchSemaphore(value: 0)
        manager.closeDevice = { _ in
            events.append("close")
            _ = release.wait(timeout: .now() + 3)
            events.append("close returned")
        }

        let returned = Flag()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = manager.closeAndWaitForDisconnect()
            events.append("returned")
            returned.set(true)
        }
        spinMain(until: { events.contains("close") })
        spinMain(for: 0.2)
        XCTAssertFalse(returned.value)

        release.signal()
        spinMain(until: { returned.value })
        XCTAssertEqual(events.all, ["close", "close returned", "returned"])
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
        DispatchQueue.global(qos: .userInitiated).async {
            CoreBluetoothNauticConnector.closeSession(of: device, name: "Nautic", on: manager)
            events.append("returned")
            returned.set(true)
        }
        spinMain(until: { events.contains("close") })
        spinMain(for: 0.2)
        XCTAssertFalse(returned.value, "the session keeps the link lease until the device's close is done")

        release.signal()
        spinMain(until: { returned.value })
        XCTAssertEqual(events.all, ["close", "close returned", "returned"])
        XCTAssertNil(manager.openedDeviceDataPtr)
    }

    func testNauticSessionCloseLeavesAnotherSessionsDeviceAlone() {
        let manager = CoreBluetoothManager(withoutCentral: ())
        openDevice(on: manager)
        let stale = OpaquePointer(bitPattern: 0x1000)!
        let closed = Flag()
        manager.closeDevice = { _ in closed.set(true) }

        let returned = Flag()
        DispatchQueue.global(qos: .userInitiated).async {
            CoreBluetoothNauticConnector.closeSession(of: stale, name: "Nautic", on: manager)
            returned.set(true)
        }
        spinMain(until: { returned.value })
        spinMain(for: 0.1)
        XCTAssertFalse(closed.value)
        XCTAssertNotNil(manager.openedDeviceDataPtr)
    }
}
