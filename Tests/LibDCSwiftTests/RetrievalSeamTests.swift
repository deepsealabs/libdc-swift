import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// `retrieveDiveLogs` used to require a live `CBPeripheral`, which can't be
/// constructed in a test (`CBPeer.init` is unavailable). These exercise the
/// internal name/UUID/isCancelled seam the CBPeripheral overload forwards to.
final class RetrievalSeamTests: XCTestCase {

    private func emptyDevicePtr() -> UnsafeMutablePointer<device_data_t> {
        let ptr = UnsafeMutablePointer<device_data_t>.allocate(capacity: 1)
        ptr.initialize(to: device_data_t())
        return ptr
    }

    func testNoDeviceConnectionFailsThroughTheSeamWithoutABluetoothManager() {
        let ptr = emptyDevicePtr()
        defer { ptr.deallocate() }
        let viewModel = DiveDataViewModel()

        var isCancelledCallCount = 0
        var markFinishedCallCount = 0
        let done = expectation(description: "completion")
        var result: Bool?

        DiveLogRetriever.retrieveDiveLogs(
            from: ptr,
            deviceName: "Test Device",
            deviceUUID: "TEST-UUID",
            viewModel: viewModel,
            isCancelled: { isCancelledCallCount += 1; return false },
            markFinished: { markFinishedCallCount += 1 },
            completion: { success in
                result = success
                done.fulfill()
            }
        )

        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, false, "a nil device pointer must fail, not crash")
        XCTAssertEqual(markFinishedCallCount, 1, "markFinished must run exactly once, matching the CBPeripheral overload")
        // The nil-device guard returns before any per-dive callback, so isCancelled is never consulted.
        XCTAssertEqual(isCancelledCallCount, 0)

        let finishedExpectation = expectation(description: "progress observed")
        DispatchQueue.main.async { finishedExpectation.fulfill() }
        wait(for: [finishedExpectation], timeout: 2)
        guard case .failed = viewModel.progress else {
            return XCTFail("expected .failed, got \(viewModel.progress)")
        }
    }

    func testTwoConcurrentSeamCallsDoNotShareState() {
        // Each call gets its own CallbackContext; nothing here should be
        // process-global except DeviceStorage/DeviceFingerprintStorage.shared,
        // which neither path touches before the nil-device guard.
        let ptrA = emptyDevicePtr()
        let ptrB = emptyDevicePtr()
        defer { ptrA.deallocate(); ptrB.deallocate() }
        let viewModelA = DiveDataViewModel()
        let viewModelB = DiveDataViewModel()

        let doneA = expectation(description: "A")
        let doneB = expectation(description: "B")
        var resultA: Bool?
        var resultB: Bool?

        DiveLogRetriever.retrieveDiveLogs(
            from: ptrA, deviceName: "A", deviceUUID: "UUID-A", viewModel: viewModelA,
            isCancelled: { false }, markFinished: {},
            completion: { resultA = $0; doneA.fulfill() })
        DiveLogRetriever.retrieveDiveLogs(
            from: ptrB, deviceName: "B", deviceUUID: "UUID-B", viewModel: viewModelB,
            isCancelled: { false }, markFinished: {},
            completion: { resultB = $0; doneB.fulfill() })

        wait(for: [doneA, doneB], timeout: 2)
        XCTAssertEqual(resultA, false)
        XCTAssertEqual(resultB, false)
    }
}
