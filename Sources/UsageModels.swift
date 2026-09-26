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

    var localizedSourceDescription: String {
        switch sourceDescription {
        case "Sample data": L10n.tr("示例数据")
        case "Configured data source": L10n.tr("已配置的数据源")
        case "Codex CLI (local, live)": L10n.tr("Codex CLI（本机实时）")
        default: sourceDescription
        }
    }

    /// Some plans expose only a weekly (or longer) window. In that case the API returns it
    /// as `primary`, despite it being the long-term quota from a user's perspective.
    var hasOnlyLongTermWindow: Bool {
        longTerm == nil && (shortTerm.windowDurationMinutes ?? 0) >= 24 * 60
    }

    static let preview = CodexUsageSnapshot(
        shortTerm: UsageWindow(remainingPercent: 65, resetsAt: .now.addingTimeInterval(17 * 60 + 56), windowDurationMinutes: 300),
        longTerm: UsageWindow(remainingPercent: 55, resetsAt: Calendar.current.date(byAdding: .day, value: 3, to: .now)!, windowDurationMinutes: 10_080),
        updatedAt: .now,
        sourceDescription: "Sample data"
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

    /// A retained snapshot never becomes current again merely because a read is in flight.
    func freshness(at date: Date = .now, staleAfter: TimeInterval = 3 * 60) -> QuotaFreshness {
        guard let snapshot else { return self == .loading(nil) ? .loading : .unavailable }
        if case .unavailable = self { return .stale }
        return date.timeIntervalSince(snapshot.updatedAt) > staleAfter ? .stale : .current
    }
}

enum QuotaFreshness: Equatable {
    case loading
    case current
    case stale
    case unavailable

    var localizedText: String {
        switch self {
        case .loading: L10n.tr("额度数据：获取中")
        case .current: L10n.tr("额度数据：最新")
        case .stale: L10n.tr("额度数据：已过期")
        case .unavailable: L10n.tr("额度数据：暂不可用")
        }
    }
}
