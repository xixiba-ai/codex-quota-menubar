import AppKit
import Combine
import Foundation
import os

struct AutoRefreshState: Codable, Equatable {
    var autoRefreshEnabled: Bool
    var lastTriggerTime: Date?
    var nextTriggerTime: Date?
    var lastTriggerResult: AutoRefreshTriggerResult?
    var missedTriggerCount: Int
    /// A one-off retry scheduled for the exact time Codex says a rate limit resets.
    var pendingQuotaResetRetryTime: Date?

    /// An internal, persisted id that makes a schedule window idempotent across restarts.
    var lastHandledWindowID: String?
    /// Minutes after midnight at which an automatic refresh should run.
    var triggerMinutes: [Int]

    init(
        autoRefreshEnabled: Bool = false,
        lastTriggerTime: Date? = nil,
        nextTriggerTime: Date? = nil,
        lastTriggerResult: AutoRefreshTriggerResult? = nil,
        missedTriggerCount: Int = 0,
        pendingQuotaResetRetryTime: Date? = nil,
        lastHandledWindowID: String? = nil,
        triggerMinutes: [Int] = AutoRefreshSchedule.defaultTriggerMinutes
    ) {
        self.autoRefreshEnabled = autoRefreshEnabled
        self.lastTriggerTime = lastTriggerTime
        self.nextTriggerTime = nextTriggerTime
        self.lastTriggerResult = lastTriggerResult
        self.missedTriggerCount = missedTriggerCount
        self.pendingQuotaResetRetryTime = pendingQuotaResetRetryTime
        self.lastHandledWindowID = lastHandledWindowID
        self.triggerMinutes = AutoRefreshSchedule.normalizedTriggerMinutes(triggerMinutes)
            ?? AutoRefreshSchedule.defaultTriggerMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case autoRefreshEnabled, lastTriggerTime, nextTriggerTime, lastTriggerResult
        case missedTriggerCount, pendingQuotaResetRetryTime, lastHandledWindowID, triggerMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            autoRefreshEnabled: try container.decodeIfPresent(Bool.self, forKey: .autoRefreshEnabled) ?? false,
            lastTriggerTime: try container.decodeIfPresent(Date.self, forKey: .lastTriggerTime),
            nextTriggerTime: try container.decodeIfPresent(Date.self, forKey: .nextTriggerTime),
            lastTriggerResult: try container.decodeIfPresent(AutoRefreshTriggerResult.self, forKey: .lastTriggerResult),
            missedTriggerCount: try container.decodeIfPresent(Int.self, forKey: .missedTriggerCount) ?? 0,
            pendingQuotaResetRetryTime: try container.decodeIfPresent(Date.self, forKey: .pendingQuotaResetRetryTime),
            lastHandledWindowID: try container.decodeIfPresent(String.self, forKey: .lastHandledWindowID),
            triggerMinutes: try container.decodeIfPresent([Int].self, forKey: .triggerMinutes)
                ?? AutoRefreshSchedule.defaultTriggerMinutes
        )
    }
}

enum AutoRefreshTriggerResult: String, Codable, Equatable {
    case inProgress
    case succeeded
    case failed
}

enum AutoRefreshTriggerReason: String, Codable, Equatable {
    case scheduled = "正常计划"
    case wakeCompensation = "休眠补偿"
    case launchCompensation = "启动补偿"
    case clockChangeCompensation = "时间变更补偿"
    case quotaResetRetry = "额度重置后重试"
}

struct AutoRefreshScheduleWindow: Equatable {
    let date: Date

    var id: String {
        String(Int64(date.timeIntervalSince1970))
    }
}

enum AutoRefreshSchedule {
    static let defaultTriggerMinutes = [5 * 60 + 30, 10 * 60 + 30, 15 * 60 + 30, 20 * 60 + 30]

    static func normalizedTriggerMinutes(_ values: [Int]) -> [Int]? {
        let normalized = Array(Set(values.filter { (0..<24 * 60).contains($0) })).sorted()
        return normalized.isEmpty ? nil : normalized
    }

    static func parseTimeList(_ text: String) -> [Int]? {
        let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty else { return nil }

        var minutes: [Int] = []
        for part in parts {
            let components = part.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components[0].count == 2, components[1].count == 2,
                  components.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let hour = Int(components[0]),
                  let minute = Int(components[1]),
                  (0..<24).contains(hour),
                  (0..<60).contains(minute) else {
                return nil
            }
            minutes.append(hour * 60 + minute)
        }
        return normalizedTriggerMinutes(minutes)
    }

    static func formattedTimeList(_ triggerMinutes: [Int]) -> String {
        (normalizedTriggerMinutes(triggerMinutes) ?? defaultTriggerMinutes)
            .map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
            .joined(separator: ", ")
    }

    static func latestWindow(
        onOrBefore date: Date,
        triggerMinutes: [Int] = defaultTriggerMinutes,
        calendar: Calendar = .current
    ) -> AutoRefreshScheduleWindow {
        let times = normalizedTriggerMinutes(triggerMinutes) ?? defaultTriggerMinutes
        let today = calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let candidates = [yesterday, today].flatMap { day in
            times.compactMap { minuteOfDay in
                calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day)
            }
        }
        return AutoRefreshScheduleWindow(date: candidates.filter { $0 <= date }.max()!)
    }

    static func nextWindow(
        after date: Date,
        triggerMinutes: [Int] = defaultTriggerMinutes,
        calendar: Calendar = .current
    ) -> AutoRefreshScheduleWindow {
        let times = normalizedTriggerMinutes(triggerMinutes) ?? defaultTriggerMinutes
        let today = calendar.startOfDay(for: date)
        for minuteOfDay in times {
            let candidate = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: today)!
            if candidate > date { return AutoRefreshScheduleWindow(date: candidate) }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        return AutoRefreshScheduleWindow(
            date: calendar.date(bySettingHour: times[0] / 60, minute: times[0] % 60, second: 0, of: tomorrow)!
        )
    }
}

protocol CodexRefreshTriggering {
    func trigger() async throws
}

protocol AutoRefreshLogging {
    func record(checkTime: Date, reason: AutoRefreshTriggerReason?, result: AutoRefreshTriggerResult?, error: Error?)
}

struct SystemAutoRefreshLogger: AutoRefreshLogging {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.CodexQuotaMenuBar", category: "AutoRefresh")

    func record(checkTime: Date, reason: AutoRefreshTriggerReason?, result: AutoRefreshTriggerResult?, error: Error?) {
        let timestamp = checkTime.formatted(date: .numeric, time: .standard)
        let reasonText = reason?.rawValue ?? "调度检查"
        let resultText = result?.rawValue ?? "无触发"
        if let error {
            logger.error("\(timestamp, privacy: .public) | \(reasonText, privacy: .public) | \(resultText, privacy: .public) | \(error.localizedDescription, privacy: .private)")
        } else {
            logger.notice("\(timestamp, privacy: .public) | \(reasonText, privacy: .public) | \(resultText, privacy: .public)")
        }
    }
}

final class AutoRefreshStateStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "autoRefreshState") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AutoRefreshState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(AutoRefreshState.self, from: data) else {
            return AutoRefreshState()
        }
        return state
    }

    func save(_ state: AutoRefreshState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class AutoRefreshScheduler: ObservableObject {
    @Published private(set) var state: AutoRefreshState

    private let stateStore: AutoRefreshStateStore
    private let trigger: any CodexRefreshTriggering
    private let logger: any AutoRefreshLogging
    private let calendar: Calendar
    private let armsTimers: Bool
    private var scheduledTimer: DispatchSourceTimer?
    private var quotaResetRetryTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var clockChangeObserver: NSObjectProtocol?
    private var isStarted = false
    private var isTriggering = false

    init(
        stateStore: AutoRefreshStateStore = AutoRefreshStateStore(),
        trigger: any CodexRefreshTriggering = CodexCLIRefreshTrigger(),
        logger: any AutoRefreshLogging = SystemAutoRefreshLogger(),
        calendar: Calendar = .current,
        armsTimers: Bool = true
    ) {
        self.stateStore = stateStore
        self.trigger = trigger
        self.logger = logger
        self.calendar = calendar
        self.armsTimers = armsTimers
        state = stateStore.load()
    }

    deinit {
        scheduledTimer?.cancel()
        quotaResetRetryTimer?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let clockChangeObserver { NotificationCenter.default.removeObserver(clockChangeObserver) }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeSystemEvents()
        guard state.autoRefreshEnabled else { return }
        armQuotaResetRetryTimer()
        Task { await checkForMissedTrigger(at: .now, reason: .launchCompensation) }
    }

    func stop() {
        isStarted = false
        scheduledTimer?.cancel()
        scheduledTimer = nil
        quotaResetRetryTimer?.cancel()
        quotaResetRetryTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let clockChangeObserver {
            NotificationCenter.default.removeObserver(clockChangeObserver)
            self.clockChangeObserver = nil
        }
    }

    func setEnabled(_ enabled: Bool, at date: Date = .now) {
        mutateState {
            $0.autoRefreshEnabled = enabled
            $0.nextTriggerTime = enabled
                ? AutoRefreshSchedule.nextWindow(after: date, triggerMinutes: $0.triggerMinutes, calendar: calendar).date
                : nil
            if !enabled { $0.pendingQuotaResetRetryTime = nil }
        }
        if enabled {
            armNextTimer(after: date)
        } else {
            scheduledTimer?.cancel()
            scheduledTimer = nil
            quotaResetRetryTimer?.cancel()
            quotaResetRetryTimer = nil
        }
    }

    @discardableResult
    func setTriggerMinutes(_ triggerMinutes: [Int], at date: Date = .now) -> Bool {
        guard let normalized = AutoRefreshSchedule.normalizedTriggerMinutes(triggerMinutes) else { return false }
        mutateState { $0.triggerMinutes = normalized }
        if state.autoRefreshEnabled {
            armNextTimer(after: date)
            armQuotaResetRetryTimer()
        }
        return true
    }

    /// Called on launch and wake. Only the newest schedule window can be compensated.
    func checkForMissedTrigger(at date: Date = .now, reason: AutoRefreshTriggerReason) async {
        logger.record(checkTime: date, reason: nil, result: nil, error: nil)
        guard state.autoRefreshEnabled else { return }

        let window = AutoRefreshSchedule.latestWindow(onOrBefore: date, triggerMinutes: state.triggerMinutes, calendar: calendar)
        guard state.lastHandledWindowID != window.id else {
            armNextTimer(after: date)
            armQuotaResetRetryTimer()
            return
        }

        await trigger(window: window, reason: reason, isCompensation: true, checkTime: date)
    }

    /// The timer supplies the intended date so a delayed fire after sleep is classified correctly.
    func handleScheduledTimer(for scheduledDate: Date, now: Date = .now) async {
        guard state.autoRefreshEnabled else { return }
        let latestWindow = AutoRefreshSchedule.latestWindow(onOrBefore: now, triggerMinutes: state.triggerMinutes, calendar: calendar)
        guard state.lastHandledWindowID != latestWindow.id else {
            armNextTimer(after: now)
            armQuotaResetRetryTimer()
            return
        }

        let reason: AutoRefreshTriggerReason = latestWindow.date == scheduledDate ? .scheduled : .wakeCompensation
        await trigger(
            window: latestWindow,
            reason: reason,
            isCompensation: reason != .scheduled,
            checkTime: now
        )
    }

    private func observeSystemEvents() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForMissedTrigger(at: .now, reason: .wakeCompensation)
            }
        }
        clockChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForMissedTrigger(at: .now, reason: .clockChangeCompensation)
            }
        }
    }

    private func trigger(
        window: AutoRefreshScheduleWindow,
        reason: AutoRefreshTriggerReason,
        isCompensation: Bool,
        checkTime: Date
    ) async {
        guard !isTriggering else { return }
        isTriggering = true
        defer {
            isTriggering = false
            armNextTimer(after: checkTime)
        }

        // Persist before the request. A relaunch or a second wake event cannot duplicate this window.
        mutateState {
            $0.lastHandledWindowID = window.id
            $0.lastTriggerTime = checkTime
            $0.lastTriggerResult = .inProgress
            if isCompensation { $0.missedTriggerCount += 1 }
        }
        logger.record(checkTime: checkTime, reason: reason, result: .inProgress, error: nil)

        do {
            try await trigger.trigger()
            mutateState {
                $0.lastTriggerResult = .succeeded
                $0.pendingQuotaResetRetryTime = nil
            }
            logger.record(checkTime: Date.now, reason: reason, result: .succeeded, error: nil)
        } catch {
            mutateState { $0.lastTriggerResult = .failed }
            logger.record(checkTime: Date.now, reason: reason, result: .failed, error: error)
            scheduleQuotaResetRetry(after: error, currentTime: checkTime)
        }
    }

    /// Invoked by the one-off timer created from Codex's "try again at …" response.
    func handleQuotaResetRetryTimer(now: Date = .now) async {
        guard state.autoRefreshEnabled,
              let retryTime = state.pendingQuotaResetRetryTime else { return }
        guard retryTime <= now else {
            armQuotaResetRetryTimer()
            return
        }
        guard !isTriggering else { return }

        isTriggering = true
        defer {
            isTriggering = false
            armNextTimer(after: now)
            armQuotaResetRetryTimer()
        }

        // Clear before the request so a relaunch cannot start the same retry twice.
        mutateState {
            $0.pendingQuotaResetRetryTime = nil
            $0.lastTriggerTime = now
            $0.lastTriggerResult = .inProgress
        }
        logger.record(checkTime: now, reason: .quotaResetRetry, result: .inProgress, error: nil)

        do {
            try await trigger.trigger()
            mutateState { $0.lastTriggerResult = .succeeded }
            logger.record(checkTime: Date.now, reason: .quotaResetRetry, result: .succeeded, error: nil)
        } catch {
            mutateState { $0.lastTriggerResult = .failed }
            logger.record(checkTime: Date.now, reason: .quotaResetRetry, result: .failed, error: error)
            scheduleQuotaResetRetry(after: error, currentTime: now)
        }
    }

    private func scheduleQuotaResetRetry(after error: Error, currentTime: Date) {
        guard case let CodexCLIRefreshTriggerError.usageLimit(resetAt, _) = error,
              let resetAt else { return }

        // The CLI reports minute precision. Leave a short grace period for the server-side
        // reset to propagate if the request itself lands within that minute.
        let retryTime = max(resetAt, currentTime.addingTimeInterval(5))
        mutateState { $0.pendingQuotaResetRetryTime = retryTime }
        armQuotaResetRetryTimer()
    }

    private func armNextTimer(after date: Date) {
        let next = AutoRefreshSchedule.nextWindow(after: date, triggerMinutes: state.triggerMinutes, calendar: calendar)
        let nextVisibleTrigger = state.pendingQuotaResetRetryTime.map { min($0, next.date) } ?? next.date
        mutateState { $0.nextTriggerTime = nextVisibleTrigger }
        guard armsTimers, state.autoRefreshEnabled else { return }

        scheduledTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = max(0, next.date.timeIntervalSinceNow)
        timer.schedule(deadline: .now() + delay, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.handleScheduledTimer(for: next.date)
            }
        }
        scheduledTimer = timer
        timer.resume()
    }

    private func armQuotaResetRetryTimer() {
        quotaResetRetryTimer?.cancel()
        quotaResetRetryTimer = nil
        guard armsTimers, state.autoRefreshEnabled,
              let retryTime = state.pendingQuotaResetRetryTime else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, retryTime.timeIntervalSinceNow), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in await self?.handleQuotaResetRetryTimer() }
        }
        quotaResetRetryTimer = timer
        timer.resume()
    }

    private func mutateState(_ mutation: (inout AutoRefreshState) -> Void) {
        mutation(&state)
        stateStore.save(state)
    }
}
