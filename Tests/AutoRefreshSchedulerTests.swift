import Foundation
import XCTest
@testable import Codex_Quota

@MainActor
final class AutoRefreshSchedulerTests: XCTestCase {
    private var calendar: Calendar!
    private var defaults: UserDefaults!
    private var stateStore: AutoRefreshStateStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        suiteName = "AutoRefreshSchedulerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        stateStore = AutoRefreshStateStore(defaults: defaults, key: "state")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        stateStore = nil
        defaults = nil
        calendar = nil
        suiteName = nil
        super.tearDown()
    }

    func testScheduleCalculatesAllFourDailyNodesAndOvernightWindow() {
        XCTAssertEqual(AutoRefreshSchedule.nextWindow(after: date(2026, 7, 11, 5, 29), calendar: calendar).date, date(2026, 7, 11, 5, 30))
        XCTAssertEqual(AutoRefreshSchedule.nextWindow(after: date(2026, 7, 11, 5, 30), calendar: calendar).date, date(2026, 7, 11, 10, 30))
        XCTAssertEqual(AutoRefreshSchedule.nextWindow(after: date(2026, 7, 11, 10, 30), calendar: calendar).date, date(2026, 7, 11, 15, 30))
        XCTAssertEqual(AutoRefreshSchedule.nextWindow(after: date(2026, 7, 11, 15, 30), calendar: calendar).date, date(2026, 7, 11, 20, 30))
        XCTAssertEqual(AutoRefreshSchedule.nextWindow(after: date(2026, 7, 11, 20, 30), calendar: calendar).date, date(2026, 7, 12, 5, 30))
        XCTAssertEqual(AutoRefreshSchedule.latestWindow(onOrBefore: date(2026, 7, 11, 3, 0), calendar: calendar).date, date(2026, 7, 10, 20, 30))
    }

    func testScheduledWindowFiresOnceAndWakeDoesNotDuplicateIt() async {
        let trigger = RecordingTrigger()
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: trigger,
            logger: RecordingLogger(),
            calendar: calendar,
            armsTimers: false
        )
        scheduler.setEnabled(true, at: date(2026, 7, 11, 5, 0))

        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 5, 30), now: date(2026, 7, 11, 5, 30))
        await scheduler.checkForMissedTrigger(at: date(2026, 7, 11, 6, 0), reason: .wakeCompensation)

        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertEqual(scheduler.state.lastTriggerResult, .succeeded)
        XCTAssertEqual(scheduler.state.missedTriggerCount, 0)
        XCTAssertEqual(scheduler.state.nextTriggerTime, date(2026, 7, 11, 10, 30))
    }

    func testWakeAfterMissedWindowRunsOneCompensationAndPersistsIt() async {
        let priorWindow = AutoRefreshScheduleWindow(date: date(2026, 7, 11, 5, 30))
        stateStore.save(AutoRefreshState(
            autoRefreshEnabled: true,
            lastTriggerTime: priorWindow.date,
            nextTriggerTime: date(2026, 7, 11, 10, 30),
            lastTriggerResult: .succeeded,
            missedTriggerCount: 0,
            lastHandledWindowID: priorWindow.id
        ))
        let trigger = RecordingTrigger()
        let logger = RecordingLogger()
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: trigger,
            logger: logger,
            calendar: calendar,
            armsTimers: false
        )

        await scheduler.checkForMissedTrigger(at: date(2026, 7, 11, 11, 15), reason: .wakeCompensation)
        await scheduler.checkForMissedTrigger(at: date(2026, 7, 11, 11, 16), reason: .wakeCompensation)

        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertEqual(scheduler.state.lastTriggerTime, date(2026, 7, 11, 11, 15))
        XCTAssertEqual(scheduler.state.lastTriggerResult, .succeeded)
        XCTAssertEqual(scheduler.state.missedTriggerCount, 1)
        XCTAssertEqual(scheduler.state.nextTriggerTime, date(2026, 7, 11, 15, 30))
        XCTAssertEqual(logger.events.filter { $0.reason == .wakeCompensation && $0.result == .succeeded }.count, 1)
    }

    func testFailedWindowIsRecordedAndNeverRepeatedDuringTheSameWindow() async {
        let trigger = RecordingTrigger(error: TestError.failed)
        let logger = RecordingLogger()
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: trigger,
            logger: logger,
            calendar: calendar,
            armsTimers: false
        )
        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 0))

        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 10, 30), now: date(2026, 7, 11, 10, 30))
        await scheduler.checkForMissedTrigger(at: date(2026, 7, 11, 10, 45), reason: .wakeCompensation)

        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertEqual(scheduler.state.lastTriggerResult, .failed)
        XCTAssertEqual(scheduler.state.lastTriggerReason, .scheduled)
        XCTAssertEqual(scheduler.state.lastFailureKind, .unknown)
        XCTAssertEqual(scheduler.state.missedTriggerCount, 0)
        XCTAssertTrue(logger.events.contains(RecordedEvent(reason: .scheduled, result: .failed, hasError: true)))
    }

    func testUsageLimitSchedulesRetryAtTheReportedResetAndRunsIt() async {
        let resetAt = date(2026, 7, 11, 15, 30)
        let trigger = SequencedTrigger(errors: [
            CodexCLIRefreshTriggerError.usageLimit(resetAt: resetAt, message: "try again at 3:30 PM"),
            nil
        ])
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: trigger,
            logger: RecordingLogger(),
            calendar: calendar,
            armsTimers: false
        )
        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 0))

        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 10, 30), now: date(2026, 7, 11, 10, 30))
        XCTAssertEqual(scheduler.state.pendingQuotaResetRetryTime, resetAt)
        XCTAssertEqual(scheduler.state.nextTriggerTime, resetAt)
        XCTAssertEqual(scheduler.state.lastFailureKind, .quotaLimited)
        XCTAssertEqual(stateStore.load().lastTriggerReason, .scheduled)
        XCTAssertEqual(stateStore.load().lastFailureKind, .quotaLimited)

        await scheduler.handleQuotaResetRetryTimer(now: resetAt)
        XCTAssertEqual(trigger.callCount, 2)
        XCTAssertNil(scheduler.state.pendingQuotaResetRetryTime)
        XCTAssertEqual(scheduler.state.lastTriggerResult, .succeeded)
        XCTAssertEqual(scheduler.state.lastTriggerReason, .quotaResetRetry)
        XCTAssertNil(scheduler.state.lastFailureKind)
        XCTAssertEqual(stateStore.load().lastTriggerReason, .quotaResetRetry)
        XCTAssertNil(stateStore.load().lastFailureKind)
    }

    func testUsageLimitResetTimeParserKeepsTheCurrentMinuteAndRollsOlderTimesForward() {
        let now = date(2026, 7, 11, 15, 30)
        XCTAssertEqual(
            CodexUsageLimitResetTime.parse(from: "try again at 3:30 PM", now: now, calendar: calendar),
            now
        )
        XCTAssertEqual(
            CodexUsageLimitResetTime.parse(from: "try again at 3:29 PM", now: now, calendar: calendar),
            date(2026, 7, 12, 15, 29)
        )
    }

    func testWakeAfterSleepingPastAFullCycleCompensatesOnlyTheLatestWindowOnce() async {
        let priorWindow = AutoRefreshScheduleWindow(date: date(2026, 7, 11, 10, 30))
        stateStore.save(AutoRefreshState(
            autoRefreshEnabled: true,
            lastTriggerTime: priorWindow.date,
            nextTriggerTime: date(2026, 7, 11, 15, 30),
            lastTriggerResult: .succeeded,
            missedTriggerCount: 0,
            lastHandledWindowID: priorWindow.id
        ))
        let trigger = RecordingTrigger()
        let logger = RecordingLogger()
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: trigger,
            logger: logger,
            calendar: calendar,
            armsTimers: false
        )

        // Simulated sleep: the 15:30 point was missed and the Mac wakes at 16:15.
        await scheduler.checkForMissedTrigger(at: date(2026, 7, 11, 16, 15), reason: .wakeCompensation)
        await scheduler.checkForMissedTrigger(at: date(2026, 7, 11, 16, 16), reason: .wakeCompensation)

        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertEqual(scheduler.state.lastTriggerResult, .succeeded)
        XCTAssertEqual(scheduler.state.missedTriggerCount, 1)
        XCTAssertEqual(scheduler.state.nextTriggerTime, date(2026, 7, 11, 20, 30))
        XCTAssertEqual(logger.events.filter { $0.reason == .wakeCompensation && $0.result == .succeeded }.count, 1)
    }

    func testMenuToggleStatePersistsAndUpdatesTheNextPlannedTime() {
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: RecordingTrigger(),
            logger: RecordingLogger(),
            calendar: calendar,
            armsTimers: false
        )

        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 31))
        XCTAssertTrue(scheduler.state.autoRefreshEnabled)
        XCTAssertEqual(scheduler.state.nextTriggerTime, date(2026, 7, 11, 15, 30))
        XCTAssertTrue(stateStore.load().autoRefreshEnabled)

        scheduler.setEnabled(false, at: date(2026, 7, 11, 10, 32))
        XCTAssertFalse(scheduler.state.autoRefreshEnabled)
        XCTAssertNil(scheduler.state.nextTriggerTime)
        XCTAssertFalse(stateStore.load().autoRefreshEnabled)
    }

    func testCustomTriggerTimesPersistAndRearmTheNextWindow() {
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: RecordingTrigger(),
            logger: RecordingLogger(),
            calendar: calendar,
            armsTimers: false
        )
        let customTimes = [6 * 60, 12 * 60 + 30, 18 * 60]

        XCTAssertTrue(scheduler.setTriggerMinutes(customTimes, at: date(2026, 7, 11, 7, 0)))
        XCTAssertEqual(scheduler.state.triggerMinutes, customTimes)
        XCTAssertEqual(stateStore.load().triggerMinutes, customTimes)

        scheduler.setEnabled(true, at: date(2026, 7, 11, 7, 0))
        XCTAssertEqual(scheduler.state.nextTriggerTime, date(2026, 7, 11, 12, 30))

        XCTAssertFalse(scheduler.setTriggerMinutes([], at: date(2026, 7, 11, 7, 1)))
        XCTAssertEqual(scheduler.state.triggerMinutes, customTimes)
    }

    func testExistingPersistedStateWithoutCustomTimesUsesDefaults() throws {
        let oldStateData = try JSONSerialization.data(withJSONObject: [
            "autoRefreshEnabled": true,
            "missedTriggerCount": 2
        ])
        defaults.set(oldStateData, forKey: "state")

        let restored = stateStore.load()
        XCTAssertTrue(restored.autoRefreshEnabled)
        XCTAssertEqual(restored.missedTriggerCount, 2)
        XCTAssertEqual(restored.triggerMinutes, AutoRefreshSchedule.defaultTriggerMinutes)
        XCTAssertNil(restored.lastTriggerReason)
        XCTAssertNil(restored.lastFailureKind)
    }

    func testFailureClassificationDoesNotPersistRawCLIOutput() async throws {
        let secret = "private CLI diagnostics 12345"
        let scheduler = AutoRefreshScheduler(
            stateStore: stateStore,
            trigger: RecordingTrigger(error: CodexCLIRefreshTriggerError.failed(exitCode: 17, message: secret)),
            logger: RecordingLogger(),
            calendar: calendar,
            armsTimers: false
        )
        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 0))

        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 10, 30), now: date(2026, 7, 11, 10, 30))

        XCTAssertEqual(scheduler.state.lastFailureKind, .commandFailed)
        XCTAssertEqual(stateStore.load().lastTriggerReason, .scheduled)
        XCTAssertEqual(stateStore.load().lastFailureKind, .commandFailed)
        let saved = try XCTUnwrap(defaults.data(forKey: "state"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(secret))
    }

    func testInterruptedExecutionRecoversAsSafeFailureOnRelaunch() {
        stateStore.save(AutoRefreshState(
            autoRefreshEnabled: true,
            lastTriggerTime: date(2026, 7, 11, 10, 30),
            lastTriggerResult: .inProgress,
            lastTriggerReason: .scheduled
        ))

        let restored = stateStore.load()
        XCTAssertEqual(restored.lastTriggerResult, .failed)
        XCTAssertEqual(restored.lastTriggerReason, .scheduled)
        XCTAssertEqual(restored.lastFailureKind, .interrupted)
        XCTAssertEqual(stateStore.load(), restored)
    }

    private func recoveryScheduler(_ trigger: any CodexRefreshTriggering) -> AutoRefreshScheduler {
        AutoRefreshScheduler(stateStore: stateStore, trigger: trigger, logger: RecordingLogger(), calendar: calendar, armsTimers: false)
    }

    private func snapshot(_ percent: Int, at time: Date, reset: Date? = nil, long: Int? = nil, account: String? = "account", allowed: Bool? = nil) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            shortTerm: UsageWindow(remainingPercent: percent, resetsAt: reset ?? date(2026, 7, 11, 15, 30), windowDurationMinutes: 300),
            longTerm: long.map { UsageWindow(remainingPercent: $0, resetsAt: date(2026, 7, 18, 0, 0), windowDurationMinutes: 10080) },
            updatedAt: time, sourceDescription: "test", accountID: account, ordinaryUsageAllowed: allowed)
    }

    func testRecoveryBaselineDuplicateAndManualResetAfterScheduledSuccess() async {
        let trigger = RecordingTrigger()
        let scheduler = recoveryScheduler(trigger)
        let baseline = snapshot(50, at: date(2026, 7, 11, 10, 19))
        scheduler.setEnabled(true, at: baseline.updatedAt)
        await scheduler.receiveQuotaSnapshot(baseline, now: baseline.updatedAt)
        XCTAssertEqual(trigger.callCount, 0)
        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 10, 30), now: date(2026, 7, 11, 10, 30))
        let restored = snapshot(100, at: date(2026, 7, 11, 10, 36))
        await scheduler.receiveQuotaSnapshot(restored, now: restored.updatedAt)
        await scheduler.receiveQuotaSnapshot(restored, now: restored.updatedAt)
        XCTAssertEqual(trigger.callCount, 2)
        XCTAssertEqual(scheduler.state.lastTriggerReason, .quotaRecovery)
    }

    func testRollingQuotaAndBlockedSecondaryDoNotTrigger() async {
        let trigger = RecordingTrigger()
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 0))
        await scheduler.receiveQuotaSnapshot(snapshot(40, at: date(2026, 7, 11, 10, 1), long: 0), now: (snapshot(40, at: date(2026, 7, 11, 10, 1), long: 0)).updatedAt)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: date(2026, 7, 11, 10, 2), long: 0), now: (snapshot(100, at: date(2026, 7, 11, 10, 2), long: 0)).updatedAt)
        scheduler.setEnabled(false)
        scheduler.setEnabled(true)
        await scheduler.receiveQuotaSnapshot(snapshot(40, at: date(2026, 7, 11, 10, 3)), now: (snapshot(40, at: date(2026, 7, 11, 10, 3))).updatedAt)
        await scheduler.receiveQuotaSnapshot(snapshot(70, at: date(2026, 7, 11, 10, 4), reset: date(2026, 7, 11, 16, 30)), now: date(2026, 7, 11, 10, 4))
        XCTAssertEqual(trigger.callCount, 0)
    }

    func testNaturalRecoveryAndRetryAreDeduplicatedWithScheduledWindow() async {
        let reset = date(2026, 7, 11, 15, 30)
        let trigger = SequencedTrigger(errors: [CodexCLIRefreshTriggerError.usageLimit(resetAt: reset, message: "limit"), nil])
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 0))
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: date(2026, 7, 11, 10, 1)), now: (snapshot(0, at: date(2026, 7, 11, 10, 1))).updatedAt)
        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 10, 30), now: date(2026, 7, 11, 10, 30))
        await scheduler.handleQuotaResetRetryTimer(now: reset)
        await scheduler.handleScheduledTimer(for: reset, now: reset)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: reset.addingTimeInterval(1), reset: reset.addingTimeInterval(18000)), now: reset.addingTimeInterval(1))
        XCTAssertEqual(trigger.callCount, 2)
        XCTAssertNil(scheduler.state.pendingQuotaResetRetryTime)
    }

    func testEarlyRecoveryReplacesPendingRetryAndReenableAccountSwitchBaseline() async {
        let reset = date(2026, 7, 11, 15, 30)
        let trigger = SequencedTrigger(errors: [CodexCLIRefreshTriggerError.usageLimit(resetAt: reset, message: "limit"), nil])
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: date(2026, 7, 11, 10, 0))
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: date(2026, 7, 11, 10, 1)), now: (snapshot(0, at: date(2026, 7, 11, 10, 1))).updatedAt)
        await scheduler.handleScheduledTimer(for: date(2026, 7, 11, 10, 30), now: date(2026, 7, 11, 10, 30))
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: date(2026, 7, 11, 10, 40)), now: date(2026, 7, 11, 10, 40))
        await scheduler.handleQuotaResetRetryTimer(now: reset)
        XCTAssertEqual(trigger.callCount, 2)
        XCTAssertNil(scheduler.state.pendingQuotaResetRetryTime)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: date(2026, 7, 11, 11, 0)), now: (snapshot(0, at: date(2026, 7, 11, 11, 0))).updatedAt)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: date(2026, 7, 11, 11, 1), account: "other"), now: (snapshot(100, at: date(2026, 7, 11, 11, 1), account: "other")).updatedAt)
        scheduler.setEnabled(false)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: date(2026, 7, 11, 11, 2)), now: (snapshot(0, at: date(2026, 7, 11, 11, 2))).updatedAt)
        scheduler.setEnabled(true)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: date(2026, 7, 11, 11, 3)), now: (snapshot(100, at: date(2026, 7, 11, 11, 3))).updatedAt)
        let restarted = recoveryScheduler(trigger)
        await restarted.receiveQuotaSnapshot(snapshot(100, at: date(2026, 7, 11, 11, 4)), now: date(2026, 7, 11, 11, 4))
        XCTAssertEqual(trigger.callCount, 2)
    }

    func testRecoveryObservedDuringOlderRequestIsDrainedAfterCompletion() async {
        let trigger = SuspendedTrigger()
        let scheduler = recoveryScheduler(trigger)
        let start = date(2026, 7, 11, 10, 30)
        scheduler.setEnabled(true, at: start.addingTimeInterval(-120))
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start.addingTimeInterval(-60)), now: start.addingTimeInterval(-60))
        let scheduled = Task { await scheduler.handleScheduledTimer(for: start, now: start) }
        while trigger.callCount == 0 { await Task.yield() }
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(60)), now: start.addingTimeInterval(60))
        XCTAssertEqual(trigger.callCount, 1)
        trigger.finish()
        await scheduled.value
        XCTAssertEqual(trigger.callCount, 2)
        XCTAssertEqual(scheduler.state.lastTriggerReason, .quotaRecovery)
    }

    func testDisableDuringRequestDropsQueuedRecoveryAndDoesNotRearm() async {
        let trigger = SuspendedTrigger()
        let scheduler = recoveryScheduler(trigger)
        let start = date(2026, 7, 11, 10, 30)
        scheduler.setEnabled(true, at: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start.addingTimeInterval(-60)), now: (snapshot(0, at: start.addingTimeInterval(-60))).updatedAt)
        let scheduled = Task { await scheduler.handleScheduledTimer(for: start, now: start) }
        while trigger.callCount == 0 { await Task.yield() }
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(60)), now: start.addingTimeInterval(60))
        scheduler.setEnabled(false)
        trigger.finish()
        await scheduled.value
        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertNil(scheduler.state.nextTriggerTime)
        XCTAssertNil(scheduler.state.pendingQuotaResetRetryTime)
    }

    func testBlockedRecoveryRunsOnceWhenPermissionBecomesAvailable() async {
        let trigger = RecordingTrigger()
        let scheduler = recoveryScheduler(trigger)
        let start = date(2026, 7, 11, 10, 0)
        scheduler.setEnabled(true, at: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start), now: start)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(60), allowed: false), now: start.addingTimeInterval(60))
        XCTAssertEqual(trigger.callCount, 0)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(120), allowed: true), now: start.addingTimeInterval(120))
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(180), allowed: true), now: start.addingTimeInterval(180))
        XCTAssertEqual(trigger.callCount, 1)
    }

    func testAccountSwitchCancelsOldAccountRetry() async {
        let start = date(2026, 7, 11, 10, 30)
        let reset = start.addingTimeInterval(18000)
        let trigger = SequencedTrigger(errors: [CodexCLIRefreshTriggerError.usageLimit(resetAt: reset, message: "limit"), nil])
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start), now: start)
        await scheduler.handleScheduledTimer(for: start, now: start)
        await scheduler.receiveQuotaSnapshot(snapshot(80, at: start.addingTimeInterval(60), account: "other"), now: start.addingTimeInterval(60))
        await scheduler.handleQuotaResetRetryTimer(now: reset)
        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertNil(scheduler.state.pendingQuotaResetRetryTime)
    }

    func testOldAccountRequestCompletionDrainsNewAccountRecovery() async {
        let start = date(2026, 7, 11, 10, 30)
        let trigger = SuspendedTrigger()
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start), now: start)
        let scheduled = Task { await scheduler.handleScheduledTimer(for: start, now: start) }
        while trigger.callCount == 0 { await Task.yield() }
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start.addingTimeInterval(60), account: "other"), now: start.addingTimeInterval(60))
        XCTAssertEqual(scheduler.state.lastFailureKind, .interrupted)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(120), account: "other"), now: start.addingTimeInterval(120))
        trigger.finish()
        await scheduled.value
        XCTAssertEqual(trigger.callCount, 2)
        XCTAssertEqual(scheduler.state.lastTriggerReason, .quotaRecovery)
        XCTAssertEqual(scheduler.state.lastTriggerResult, .succeeded)
    }

    func testStopDropsQueuedRecoveryAndRejectsLateSnapshots() async {
        let start = date(2026, 7, 11, 10, 30)
        let trigger = SuspendedTrigger()
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start), now: start)
        let scheduled = Task { await scheduler.handleScheduledTimer(for: start, now: start) }
        while trigger.callCount == 0 { await Task.yield() }
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(60)), now: start.addingTimeInterval(60))
        scheduler.stop()
        XCTAssertEqual(scheduler.state.lastFailureKind, .interrupted)
        trigger.finish()
        await scheduled.value
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start.addingTimeInterval(120)), now: start.addingTimeInterval(120))
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(180)), now: start.addingTimeInterval(180))
        await scheduler.handleScheduledTimer(for: start.addingTimeInterval(18000), now: start.addingTimeInterval(18000))
        XCTAssertEqual(trigger.callCount, 1)
        XCTAssertEqual(scheduler.state.lastTriggerResult, .failed)
    }

    func testStaleFutureAndOutOfOrderSnapshotsCannotTriggerRecovery() async {
        let start = date(2026, 7, 11, 10, 30)
        let trigger = RecordingTrigger()
        let scheduler = recoveryScheduler(trigger)
        scheduler.setEnabled(true, at: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start), now: start)
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(60)), now: start.addingTimeInterval(241))
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(120)), now: start.addingTimeInterval(60))
        await scheduler.receiveQuotaSnapshot(snapshot(100, at: start.addingTimeInterval(-60)), now: start)
        await scheduler.receiveQuotaSnapshot(snapshot(0, at: start.addingTimeInterval(180)), now: start.addingTimeInterval(180))
        XCTAssertEqual(trigger.callCount, 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

private final class RecordingTrigger: CodexRefreshTriggering {
    private(set) var callCount = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func trigger() async throws {
        callCount += 1
        if let error { throw error }
    }
}

private final class SequencedTrigger: CodexRefreshTriggering {
    private(set) var callCount = 0
    private var errors: [Error?]

    init(errors: [Error?]) {
        self.errors = errors
    }

    func trigger() async throws {
        callCount += 1
        if !errors.isEmpty, let error = errors.removeFirst() { throw error }
    }
}

private struct RecordedEvent: Equatable {
    let reason: AutoRefreshTriggerReason?
    let result: AutoRefreshTriggerResult?
    let hasError: Bool
}

private final class RecordingLogger: AutoRefreshLogging {
    private(set) var events: [RecordedEvent] = []

    func record(checkTime: Date, reason: AutoRefreshTriggerReason?, result: AutoRefreshTriggerResult?, error: Error?) {
        events.append(RecordedEvent(reason: reason, result: result, hasError: error != nil))
    }
}

private enum TestError: Error {
    case failed
}

@MainActor
private final class SuspendedTrigger: CodexRefreshTriggering {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func trigger() async throws {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
