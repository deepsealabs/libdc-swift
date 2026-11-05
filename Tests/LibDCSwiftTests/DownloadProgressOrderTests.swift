import XCTest
@testable import LibDCSwift

final class DownloadProgressOrderTests: XCTestCase {
    private func makeViewModel() -> DiveDataViewModel {
        let suite = "DownloadProgressOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: defaults))
    }

    private func drainMain() {
        for _ in 0..<3 {
            let drained = expectation(description: "drain")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
    }

    func testALateDiveCountDoesNotUndoAFinishedDownload() {
        let terminal: [DiveDataViewModel.DownloadProgress] = [.completed, .noNewDives, .emptyRead, .cancelled]
        for outcome in terminal {
            let viewModel = makeViewModel()
            viewModel.updateProgress(count: 1)
            viewModel.updateProgress(outcome)
            viewModel.updateProgress(count: 2)
            viewModel.appendDives([])
            drainMain()
            XCTAssertEqual(viewModel.progress, outcome, "a count after \(outcome) must not bring back inProgress")
        }
    }

    func testALateDiveCountDoesNotUndoAFailure() {
        let viewModel = makeViewModel()
        viewModel.updateProgress(count: 1)
        viewModel.setError("link lost")
        viewModel.updateProgress(count: 2)
        drainMain()
        guard case .failed = viewModel.progress else {
            return XCTFail("expected .failed, got \(viewModel.progress)")
        }
    }

    func testCountsResumeAfterAReset() {
        let viewModel = makeViewModel()
        viewModel.updateProgress(.completed)
        viewModel.resetProgress()
        viewModel.updateProgress(count: 1)
        drainMain()
        XCTAssertEqual(viewModel.progress, .inProgress(1))
    }
}
