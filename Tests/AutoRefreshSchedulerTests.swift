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
