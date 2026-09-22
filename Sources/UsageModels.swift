import Foundation
import SwiftUI

struct UsageWindow: Codable, Equatable {
    let remainingPercent: Int
    let resetsAt: Date
    let windowDurationMinutes: Int?

    var statusColor: Color {
        switch remainingPercent {
        case 51...100: .green
        case 20...50: .yellow
        default: .red
        }
    }

    var clampedPercent: Int { min(100, max(0, remainingPercent)) }
}

struct CodexUsageSnapshot: Codable, Equatable {
    let shortTerm: UsageWindow
    /// Codex plans that expose only one rate-limit window omit the secondary window.
    let longTerm: UsageWindow?
    let updatedAt: Date
    var sourceDescription: String

    /// Some plans expose only a weekly (or longer) window. In that case the API returns it
    /// as `primary`, despite it being the long-term quota from a user's perspective.
    var hasOnlyLongTermWindow: Bool {
        longTerm == nil && (shortTerm.windowDurationMinutes ?? 0) >= 24 * 60
    }

    static let preview = CodexUsageSnapshot(
        shortTerm: UsageWindow(remainingPercent: 65, resetsAt: .now.addingTimeInterval(17 * 60 + 56), windowDurationMinutes: 300),
        longTerm: UsageWindow(remainingPercent: 55, resetsAt: Calendar.current.date(byAdding: .day, value: 3, to: .now)!, windowDurationMinutes: 10_080),
        updatedAt: .now,
        sourceDescription: "示例数据"
    )
}

enum QuotaState: Equatable {
    case available(CodexUsageSnapshot)
    case loading(CodexUsageSnapshot?)
    case unavailable(message: String, lastKnown: CodexUsageSnapshot?)

    var snapshot: CodexUsageSnapshot? {
        switch self {
        case .available(let snapshot): snapshot
        case .loading(let snapshot): snapshot
        case .unavailable(_, let snapshot): snapshot
        }
    }
}
