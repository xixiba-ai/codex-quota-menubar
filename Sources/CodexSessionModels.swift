import Foundation

struct CodexSession: Identifiable, Hashable {
    enum Status: Hashable {
        case notLoaded
        case idle
        case active(flags: [String])
        case systemError
        case unknown(String)

        var label: String {
            switch self {
            case .notLoaded: L10n.tr("已保存")
            case .idle: L10n.tr("空闲")
            case .active(let flags): flags.isEmpty ? L10n.tr("进行中") : L10n.tr("等待处理")
            case .systemError: L10n.tr("异常")
            case .unknown: L10n.tr("未知")
            }
        }

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    let id: String
    let name: String?
    let preview: String
    let cwd: String
    let createdAt: Date
    let updatedAt: Date
    let status: Status

    var displayTitle: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? preview : trimmedName
    }

    var resumeCommand: String {
        "cd \(ShellQuote.quote(cwd)) && codex resume -- \(ShellQuote.quote(id))"
    }
}
