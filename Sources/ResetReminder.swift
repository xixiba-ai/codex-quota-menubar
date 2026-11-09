import Foundation
import Combine

/// Only the account's long-term quota deadline belongs to this reminder.
/// This policy never rolls a passed deadline forward or infers a fresh cycle.
struct ResetReminderConfiguration: Codable, Equatable {
    var isEnabled = true
    var redHours = 24
    var orangeHours = 72

    var isValid: Bool { redHours > 0 && orangeHours > redHours }
}

enum ResetReminderTier: Equatable {
    case disabled, unknown, awaitingConfirmation, red, orange, normal
}

enum ResetReminderPolicy {
    static func tier(resetAt: Date?, now: Date, configuration: ResetReminderConfiguration) -> ResetReminderTier {
        guard configuration.isEnabled else { return .disabled }
        guard configuration.isValid, let resetAt,
              resetAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else { return .unknown }
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0 else { return .awaitingConfirmation }
        if remaining < Double(configuration.redHours) * 3600 { return .red }
        if remaining < Double(configuration.orangeHours) * 3600 { return .orange }
        return .normal
    }
}

@MainActor
final class ResetReminderStore: ObservableObject {
    static let defaultsKey = "longTermResetReminder.v1"
    @Published private(set) var configuration: ResetReminderConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(ResetReminderConfiguration.self, from: data), saved.isValid {
            configuration = saved
        } else { configuration = ResetReminderConfiguration() }
    }

    @discardableResult
    func save(_ configuration: ResetReminderConfiguration) -> Bool {
        guard configuration.isValid, let data = try? JSONEncoder().encode(configuration) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        self.configuration = configuration
        return true
    }

    func setEnabled(_ enabled: Bool) {
        var updated = configuration
        updated.isEnabled = enabled
        save(updated)
    }
}

/// Selects the user's long-term quota for the compact menu bar. Formatting functions
/// are supplied by the caller so selection can be verified without AppKit or a clock.
enum QuotaMenuBarPresentation {
    static func title(snapshot: CodexUsageSnapshot, resetDate: (Date) -> String,
                      remaining: (Date) -> String) -> String {
        if let window = snapshot.longTermResetWindow {
            return "\(window.clampedPercent)% \(resetDate(window.resetsAt))"
        }
        return "\(snapshot.shortTerm.clampedPercent)% \(remaining(snapshot.shortTerm.resetsAt))"
    }
}
