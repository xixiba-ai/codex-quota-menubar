import AppKit

extension ResetReminderTier {
    var color: NSColor? {
        switch self {
        case .red, .awaitingConfirmation: return .systemRed
        case .orange: return .systemOrange
        case .unknown: return nil
        case .normal, .disabled: return nil
        }
    }

    var statusText: String {
        switch self {
        case .disabled: return L10n.tr("提醒已关闭")
        case .unknown: return L10n.tr("长期重置时间未知")
        case .awaitingConfirmation: return L10n.tr("等待新周期确认")
        case .red: return L10n.tr("即将重置")
        case .orange: return L10n.tr("临近重置")
        case .normal: return L10n.tr("距重置时间充足")
        }
    }
}

/// Native disabled menu items may dim attributed foreground colors. A noninteractive
/// label view preserves semantic red/orange while keeping information rows inactive.
@MainActor
final class ResetReminderMenuRow: NSView {
    init(title: String, color: NSColor) {
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = color
        label.sizeToFit()
        let width = max(280, label.frame.width + 42)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        label.frame = NSRect(x: 20, y: 3, width: width - 38, height: 18)
        label.autoresizingMask = [.width]
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
