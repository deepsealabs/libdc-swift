import XCTest
@testable import LibDCSwift

final class NauticAutoSyncPolicyTests: XCTestCase {

    // MARK: - ReconnectTracker

    func testRetriesWithTheFixedDelay() {
        var tracker = ReconnectTracker(policy: .suuntoApp)
        XCTAssertEqual(tracker.connectionFailed(linkLost: false), .retry(after: 4, attempt: 2))
        XCTAssertEqual(tracker.connectionFailed(linkLost: false), .retry(after: 4, attempt: 3))
    }

    func testCoolsDownAfterTheCountedAttempts() {
        var tracker = ReconnectTracker(policy: .suuntoApp)
        for _ in 0..<19 {
            guard case .retry = tracker.connectionFailed(linkLost: false) else { return XCTFail("cooled down early") }
        }
        XCTAssertEqual(tracker.connectionFailed(linkLost: false), .coolDown(120 * 60))
        XCTAssertEqual(tracker.countedAttempts, 0, "a cool-down starts a fresh budget")
    }

    func testLinkLossFailuresOnlyCountTowardTheTotal() {
        var tracker = ReconnectTracker(policy: .suuntoApp)
        for _ in 0..<95 {
            guard case .retry = tracker.connectionFailed(linkLost: true) else { return XCTFail("cooled down early") }
        }
        XCTAssertEqual(tracker.countedAttempts, 0)
        XCTAssertEqual(tracker.connectionFailed(linkLost: true), .coolDown(120 * 60))
    }

    func testConnectingResetsTheBudget() {
        var tracker = ReconnectTracker(policy: .suuntoApp)
        for _ in 0..<10 { _ = tracker.connectionFailed(linkLost: false) }
        tracker.connected()
        XCTAssertEqual(tracker.nextAttempt, 1)
        XCTAssertEqual(tracker.countedAttempts, 0)
    }

    func testConnectionLoopCoolsDown() {
        var tracker = ReconnectTracker(policy: .suuntoApp)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<10 {
            XCTAssertEqual(tracker.disconnected(at: start.addingTimeInterval(Double(i) * 20)), .retry(after: 4, attempt: 1))
        }
        XCTAssertEqual(tracker.disconnected(at: start.addingTimeInterval(200)), .coolDown(120 * 60))
    }

    func testSpreadOutDisconnectsAreNotALoop() {
        var tracker = ReconnectTracker(policy: .suuntoApp)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<30 {
            XCTAssertEqual(tracker.disconnected(at: start.addingTimeInterval(Double(i) * 60)), .retry(after: 4, attempt: 1))
        }
    }

    // MARK: - DiveSyncPlan

    func testPendingIsOldestFirstAndSkipsSynced() {
        let plan = DiveSyncPlan(synced: [300], retriesPerDive: 3)
        XCTAssertEqual(plan.pending(listed: [400, 300, 200, 100]), [100, 200, 400])
    }

    func testBaselineCoversOlderDives() {
        let plan = DiveSyncPlan(synced: [], baseline: 200)
        XCTAssertEqual(plan.pending(listed: [300, 200, 100]), [300])
    }

    func testResumeAfterADropKeepsOnlyTheMissingDives() {
        var plan = DiveSyncPlan(synced: [], retriesPerDive: 3)
        let listed: [UInt32] = [30, 20, 10]
        plan.recordAttempt(10)
        plan.markSynced(10)
        plan.recordAttempt(20)
        XCTAssertEqual(plan.pending(listed: listed), [20, 30], "the dive the link died on is retried, then the rest")
        XCTAssertEqual(plan.attempts[20], 1)
        XCTAssertEqual(plan.pending(listed: [40] + listed), [20, 30, 40], "a dive recorded meanwhile joins the queue")
    }

    func testRetryBudgetPerDive() {
        var plan = DiveSyncPlan(synced: [], retriesPerDive: 2)
        plan.recordAttempt(7)
        XCTAssertTrue(plan.canRetry(7))
        plan.recordAttempt(7)
        XCTAssertTrue(plan.canRetry(7))
        plan.recordAttempt(7)
        XCTAssertFalse(plan.canRetry(7))
    }

    func testGivenUpDivesComeBackNextRun() {
        var plan = DiveSyncPlan(synced: [])
        plan.giveUp(5)
        XCTAssertEqual(plan.pending(listed: [5, 6]), [6])
        plan.finishRun()
        XCTAssertEqual(plan.pending(listed: [5, 6]), [5, 6])
    }

    func testStoreRoundTrip() {
        let defaults = UserDefaults(suiteName: "NauticAutoSyncPolicyTests")!
        defaults.removePersistentDomain(forName: "NauticAutoSyncPolicyTests")
        let store = UserDefaultsAutoSyncStore(defaults: defaults)
        store.markSynced([3, 1], device: "Nautic 1")
        store.markSynced([2, 3], device: "Nautic 1")
        XCTAssertEqual(store.syncedIDs(device: "Nautic 1"), [1, 2, 3])
        XCTAssertEqual(store.syncedIDs(device: "Nautic 2"), [])
        store.reset(device: "Nautic 1")
        XCTAssertEqual(store.syncedIDs(device: "Nautic 1"), [])
    }

    // MARK: - Whiteboard values (bytes from an official-app capture)

    func testWhiteboardValueDecoding() {
        // /Logbook/UnsynchronisedLogs subscribe reply body: uint16 0.
        XCTAssertEqual(SuuntoNauticExplorer.WhiteboardValue(encoded: Data([0x05, 0x00, 0x00, 0x00]))?.integerValue, 0)
        // /Device/Power/Batterylevel: uint8 46.
        XCTAssertEqual(SuuntoNauticExplorer.WhiteboardValue(encoded: Data([0x03, 0x00, 0x2E]))?.integerValue, 46)
        // Battery notification, with the trailing pad byte: uint8 91.
        XCTAssertEqual(SuuntoNauticExplorer.WhiteboardValue(encoded: Data([0x03, 0x00, 0x5B, 0x00]))?.integerValue, 91)
        // /Weather/Sync: bool true.
        XCTAssertEqual(SuuntoNauticExplorer.WhiteboardValue(encoded: Data([0x01, 0x00, 0x01]))?.integerValue, 1)
        XCTAssertNil(SuuntoNauticExplorer.WhiteboardValue(encoded: Data([0x05])))
    }

    func testSubscriptionMatchesTheNotificationHandle() {
        let subscription = SuuntoNauticExplorer.Subscription(path: "/Logbook/Data", handle: [0x00, 0x24, 0x0E], initialValue: nil)
        XCTAssertTrue(subscription.matches([0xF0, 0x24, 0x0E]))
        XCTAssertFalse(subscription.matches([0xF0, 0x24, 0x0D]))
    }

    func testConnectAttemptsAndTriggerRetriesAreBounded() {
        let config = NauticAutoSync.Configuration()
        XCTAssertEqual(config.connectTimeout, 25, "a pending connect to a sleeping watch can otherwise sit for minutes")
        XCTAssertEqual(config.triggerSubscribeRetries, 3)
        XCTAssertEqual(config.triggerSubscribeRetryDelay, 2)
        XCTAssertEqual(config.triggerResubscribeInterval, 5 * 60)
    }
}
