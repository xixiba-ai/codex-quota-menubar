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
            case .notLoaded: "已保存"
            case .idle: "空闲"
            case .active(let flags): flags.isEmpty ? "进行中" : "等待处理"
            case .systemError: "异常"
            case .unknown: "未知"
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
        "cd \(shellQuote(cwd)) && codex resume \(shellQuote(id))"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
