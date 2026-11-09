import Foundation
#if !RESET_REMINDER_CLI_TEST
import XCTest
@testable import Codex_Quota

final class ResetReminderTests: XCTestCase {
    @MainActor
    func testBoundariesSelectionAndPersistence() throws {
        XCTAssertGreaterThan(try ResetReminderChecks.run(), 25)
    }
}
#endif

/// The same checks run under XCTest, or directly with CLT on Macs without full Xcode.
enum ResetReminderChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func run() throws -> Int {
        var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(description: message) }
            count += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = ResetReminderConfiguration()
        func tier(_ seconds: Double?, config: ResetReminderConfiguration = ResetReminderConfiguration()) -> ResetReminderTier {
            ResetReminderPolicy.tier(resetAt: seconds.map { now.addingTimeInterval($0) }, now: now, configuration: config)
        }
        try expect(config.isEnabled, "enabled by default")
        try expect(config.redHours == 24 && config.orangeHours == 72, "default thresholds")
        try expect(tier(1) == .red, "one second left")
        try expect(tier(24 * 3600 - 1) == .red, "just before 24h")
        try expect(tier(24 * 3600) == .orange, "exact 24h is orange")
        try expect(tier(24 * 3600 + 1) == .orange, "just after 24h")
        try expect(tier(72 * 3600 - 1) == .orange, "just before 72h")
        try expect(tier(72 * 3600) == .normal, "exact 72h is normal")
        try expect(tier(72 * 3600 + 1) == .normal, "after 72h")
        try expect(tier(0) == .awaitingConfirmation, "deadline is not new cycle")
        try expect(tier(-1) == .awaitingConfirmation, "expired deadline")
        try expect(tier(-8 * 86400) == .awaitingConfirmation, "no inferred cycle rollover")
        try expect(tier(nil) == .unknown, "missing date unknown")
        var disabled = config; disabled.isEnabled = false
        for seconds: Double? in [nil, -1, 0, 1, 48 * 3600, 100 * 3600] {
            try expect(tier(seconds, config: disabled) == .disabled, "disabled has no reminder")
        }
        let custom = ResetReminderConfiguration(isEnabled: true, redHours: 12, orangeHours: 48)
        try expect(tier(12 * 3600 - 1, config: custom) == .red, "custom red")
        try expect(tier(12 * 3600, config: custom) == .orange, "custom orange boundary")
        try expect(tier(48 * 3600, config: custom) == .normal, "custom normal boundary")
        let weekly = UsageWindow(remainingPercent: 50, resetsAt: now.addingTimeInterval(24 * 3600), windowDurationMinutes: 10080)
        let short = UsageWindow(remainingPercent: 80, resetsAt: now.addingTimeInterval(3600), windowDurationMinutes: 300)
        func snapshot(_ primary: UsageWindow, _ secondary: UsageWindow?) -> CodexUsageSnapshot {
            CodexUsageSnapshot(shortTerm: primary, longTerm: secondary, updatedAt: now, sourceDescription: "Sample data")
        }
        try expect(snapshot(short, weekly).longTermResetWindow == weekly, "dual uses long-term secondary")
        try expect(snapshot(weekly, nil).longTermResetWindow == weekly, "weekly-only uses primary")
        try expect(snapshot(short, nil).longTermResetWindow == nil, "five-hour primary never used")
        try expect(ResetReminderPolicy.tier(resetAt: snapshot(short, weekly).longTermResetWindow?.resetsAt, now: now, configuration: config) == .orange, "short reset in one hour does not make dual red")
        try expect(ResetReminderPolicy.tier(resetAt: snapshot(weekly, nil).longTermResetWindow?.resetsAt, now: now, configuration: config) == .orange, "weekly-only has same policy")
        try expect(ResetReminderPolicy.tier(resetAt: snapshot(short, nil).longTermResetWindow?.resetsAt, now: now, configuration: config) == .unknown, "short-only has no long-term reminder")
        // Verify actual compact presentation selection via distinguishable formatters.
        var formattedDate: Date?
        var formattedRemaining: Date?
        func compactTitle(_ value: CodexUsageSnapshot) -> String {
            formattedDate = nil; formattedRemaining = nil
            return QuotaMenuBarPresentation.title(snapshot: value, resetDate: { formattedDate = $0; return "Nov 10" },
                                                 remaining: { formattedRemaining = $0; return "01:00" })
        }
        try expect(compactTitle(snapshot(short, weekly)) == "50% Nov 10", "dual compact bar uses long-term percent and date only")
        try expect(formattedDate == weekly.resetsAt && formattedRemaining == nil, "dual never formats short-term countdown")
        try expect(compactTitle(snapshot(weekly, nil)) == "50% Nov 10", "weekly-only compact format matches dual")
        try expect(formattedDate == weekly.resetsAt && formattedRemaining == nil, "weekly primary date selected")
        try expect(compactTitle(snapshot(short, nil)) == "80% 01:00", "short-only retains countdown")
        try expect(formattedDate == nil && formattedRemaining == short.resetsAt, "short-only never formats an invented long-term date")
        let suite = "ResetReminderChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResetReminderStore(defaults: defaults)
        try expect(store.configuration == config, "fresh install defaults")
        try expect(store.save(custom), "save custom thresholds")
        try expect(ResetReminderStore(defaults: defaults).configuration == custom, "round-trip persisted thresholds")
        store.setEnabled(false)
        try expect(!ResetReminderStore(defaults: defaults).configuration.isEnabled, "disabled persisted")
        for invalid in [ResetReminderConfiguration(redHours: 0, orangeHours: 72), ResetReminderConfiguration(redHours: -1, orangeHours: 72), ResetReminderConfiguration(redHours: 24, orangeHours: 24), ResetReminderConfiguration(redHours: 48, orangeHours: 24)] {
            let previous = store.configuration
            try expect(!store.save(invalid), "invalid threshold rejected")
            try expect(store.configuration == previous, "invalid save preserves state")
        }
        defaults.set(try JSONEncoder().encode(ResetReminderConfiguration(redHours: 0, orangeHours: 0)), forKey: ResetReminderStore.defaultsKey)
        try expect(ResetReminderStore(defaults: defaults).configuration == config, "invalid persisted configuration recovers defaults")
        let deadline = now.addingTimeInterval(73 * 3600)
        try expect(ResetReminderPolicy.tier(resetAt: deadline, now: now.addingTimeInterval(2 * 3600), configuration: config) == .orange, "recompute as time advances")
        return count
    }
}

#if RESET_REMINDER_CLI_TEST
@main
struct ResetReminderTestRunner {
    @MainActor
    static func main() throws { print("PASS: \(try ResetReminderChecks.run()) reset reminder checks") }
}
#endif
