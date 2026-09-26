import SwiftUI

struct ObservedQuotaMenuBarLabel: View {
    @ObservedObject private var language = AppLanguageStore.shared
    @ObservedObject var store: QuotaStore

    var body: some View {
        QuotaMenuBarLabel(snapshot: store.snapshot)
    }
}

struct QuotaMenuBarLabel: View {
    @ObservedObject private var language = AppLanguageStore.shared
    let snapshot: CodexUsageSnapshot?

    var body: some View {
        Group {
            if let snapshot {
                HStack(spacing: 2) {
                    Circle()
                        .fill(snapshot.shortTerm.statusColor)
                        .frame(width: 4, height: 4)
                    Text("\(snapshot.shortTerm.clampedPercent)%")
                        .foregroundStyle(snapshot.shortTerm.statusColor)
                    Text(snapshot.hasOnlyLongTermWindow ? TimeFormatter.resetDate(snapshot.shortTerm.resetsAt) : TimeFormatter.remaining(snapshot.shortTerm.resetsAt))
                    if let longTerm = snapshot.longTerm {
                        Text("·").foregroundStyle(.secondary)
                        Text("\(longTerm.clampedPercent)%")
                            .foregroundStyle(longTerm.statusColor)
                        Text(TimeFormatter.resetDate(longTerm.resetsAt))
                    }
                }
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(L10n.tr("Codex 额度数据不可用"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct QuotaLines: View {
    @ObservedObject private var language = AppLanguageStore.shared
    let snapshot: CodexUsageSnapshot
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            StatusLine(window: snapshot.shortTerm, detail: snapshot.hasOnlyLongTermWindow ? TimeFormatter.resetDate(snapshot.shortTerm.resetsAt) : TimeFormatter.remaining(snapshot.shortTerm.resetsAt), compact: compact)
            if let longTerm = snapshot.longTerm {
                StatusLine(window: longTerm, detail: TimeFormatter.resetDate(longTerm.resetsAt), compact: compact)
            }
        }
        .font(.system(size: 7, weight: .medium, design: .rounded))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.longTerm.map { L10n.tr("短周期剩余 \(snapshot.shortTerm.remainingPercent)%，长期剩余 \($0.remainingPercent)%") } ?? L10n.tr("短周期剩余 \(snapshot.shortTerm.remainingPercent)%"))
    }
}

private struct StatusLine: View {
    let window: UsageWindow
    let detail: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(window.statusColor)
                .frame(width: 3, height: 3)
            Text("\(window.clampedPercent)%")
                .foregroundStyle(window.statusColor)
            if !compact { Text(detail).foregroundStyle(.primary) }
        }
        .lineLimit(1)
    }
}

struct QuotaMenuContent: View {
    @ObservedObject private var language = AppLanguageStore.shared
    @ObservedObject var store: QuotaStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.tr("Codex 使用额度"), systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }

            if let snapshot = store.snapshot {
                DetailRow(title: snapshot.hasOnlyLongTermWindow ? L10n.tr("长期") : L10n.tr("短周期"), window: snapshot.shortTerm, resetText: snapshot.hasOnlyLongTermWindow ? L10n.tr("重置于 \(TimeFormatter.fullDate(snapshot.shortTerm.resetsAt))") : L10n.tr("剩余 \(TimeFormatter.remaining(snapshot.shortTerm.resetsAt))"))
                if let longTerm = snapshot.longTerm {
                    DetailRow(title: L10n.tr("长期"), window: longTerm, resetText: L10n.tr("重置于 \(TimeFormatter.fullDate(longTerm.resetsAt))"))
                }
                Text(L10n.tr("更新：\(snapshot.updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))) · \(snapshot.localizedSourceDescription)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("无法加载额度")).font(.subheadline)
                    Text(store.errorMessage ?? L10n.tr("正在连接额度服务"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                Label(store.freshnessText(at: context.date),
                      systemImage: store.freshness(at: context.date) == .stale ? "exclamationmark.triangle" : "clock")
                    .font(.caption)
                    .foregroundStyle(store.freshness(at: context.date) == .stale ? Color.orange : Color.secondary)
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
            HStack {
                Button { Task { await store.refresh() } } label: {
                    Label(L10n.tr("立即刷新"), systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                Spacer()
                Button(L10n.tr("退出")) { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 310)
    }
}

private struct DetailRow: View {
    let title: String
    let window: UsageWindow
    let resetText: String

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(window.statusColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(resetText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(window.clampedPercent)%")
                .font(.title3.weight(.semibold))
                .foregroundStyle(window.statusColor)
                .monospacedDigit()
        }
    }
}

enum TimeFormatter {
    static func dataAge(_ date: Date, relativeTo now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    static func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        return String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    static func resetDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(L10n.locale))
    }

    static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().hour().minute().locale(L10n.locale))
    }
}
