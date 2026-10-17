import XCTest
@testable import LibDCSwift

/// retrieveDiveLogs owns the flag its per-dive callback treats as the cancel switch.
final class RetrievalFlagTests: XCTestCase {

    private final class ThreadRecordingHolder: RetrievalFlagHolder {
        private(set) var setOnMain: [Bool] = []
        var isRetrievingLogs = false {
            didSet { setOnMain.append(Thread.isMainThread) }
        }
    }

    func testStartedFromMainSetsTheFlagBeforeReturning() {
        let holder = ThreadRecordingHolder()
        DiveLogRetriever.markRetrievalStarted(holder)
        XCTAssertTrue(holder.isRetrievingLogs)
        XCTAssertEqual(holder.setOnMain, [true])
    }

    func testStartedFromABackgroundQueueSetsTheFlagOnMainBeforeReturning() {
        let holder = ThreadRecordingHolder()
        let done = expectation(description: "started")
        var flagWhenReturned: Bool?
        DispatchQueue.global(qos: .userInitiated).async {
            DiveLogRetriever.markRetrievalStarted(holder)
            flagWhenReturned = holder.isRetrievingLogs
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(flagWhenReturned, true)
        XCTAssertEqual(holder.setOnMain, [true])
    }

    func testFinishedClearsTheFlag() {
        let holder = ThreadRecordingHolder()
        DiveLogRetriever.markRetrievalStarted(holder)
        DiveLogRetriever.markRetrievalFinished(holder)
        XCTAssertFalse(holder.isRetrievingLogs)
    }

    func testCancelAfterStartIsNotOverwritten() {
        let holder = ThreadRecordingHolder()
        DiveLogRetriever.markRetrievalStarted(holder)
        holder.isRetrievingLogs = false
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(holder.isRetrievingLogs)
    }
}
