import AppKit
import Foundation

enum TerminalResumeError: LocalizedError {
    case projectUnavailable
    case invalidSessionID
    case terminalUnavailable
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            L10n.tr("项目目录不存在或不可访问，无法续接会话")
        case .invalidSessionID:
            L10n.tr("会话 ID 无效，无法续接会话")
        case .terminalUnavailable:
            L10n.tr("未找到 macOS 终端应用")
        case .launchFailed(let detail):
            L10n.tr("无法在终端续接会话：\(detail)")
        }
    }
}

/// Opens a one-use command file with Terminal so the interactive CLI owns its terminal session.
/// The private file removes itself before starting Codex. A later launch prunes any old files
/// left behind when Terminal never ran the command.
struct CodexTerminalResumeLauncher {
    typealias OpenCommand = (URL, URL, @escaping (Error?) -> Void) -> Void

    private let fileManager: FileManager
    private let scriptDirectory: URL
    private let resolveExecutable: () throws -> URL
    private let terminalApplication: () -> URL?
    private let openCommand: OpenCommand

    init(
        fileManager: FileManager = .default,
        scriptDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuotaResume", isDirectory: true),
        resolveExecutable: @escaping () throws -> URL = { try CodexExecutableResolver.executableURL() },
        terminalApplication: @escaping () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        },
        openCommand: @escaping OpenCommand = { script, application, completion in
            NSWorkspace.shared.open(
                [script],
                withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in completion(error) }
        }
    ) {
        self.fileManager = fileManager
        self.scriptDirectory = scriptDirectory
        self.resolveExecutable = resolveExecutable
        self.terminalApplication = terminalApplication
        self.openCommand = openCommand
    }

    func launch(_ session: CodexSession, completion: @escaping (Error?) -> Void) {
        do {
            let executable = try resolveExecutable()
            guard let terminal = terminalApplication() else { throw TerminalResumeError.terminalUnavailable }
            let script = try prepareScript(for: session, executable: executable)
            openCommand(script, terminal) { error in
                if let error {
                    try? self.fileManager.removeItem(at: script)
                    completion(TerminalResumeError.launchFailed(error.localizedDescription))
                } else {
                    completion(nil)
                }
            }
        } catch {
            completion(error)
        }
    }

    /// Internal for tests: preparing a command never starts Terminal or Codex.
    func prepareScript(for session: CodexSession, executable: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard session.cwd.hasPrefix("/"),
              fileManager.fileExists(atPath: session.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TerminalResumeError.projectUnavailable
        }
        guard !session.id.isEmpty, !session.id.contains("\0") else {
            throw TerminalResumeError.invalidSessionID
        }
        guard executable.path.hasPrefix("/"), fileManager.isExecutableFile(atPath: executable.path) else {
            throw CodexCLIRefreshTriggerError.executableNotFound
        }

        try fileManager.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Keep an existing directory private too, including one restored with wider permissions.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptDirectory.path)
        pruneOldScripts()

        let script = scriptDirectory.appendingPathComponent(UUID().uuidString + ".command")
        let body = """
        #!/bin/sh
        /bin/rm -f -- "$0"
        cd \(ShellQuote.quote(session.cwd)) || exit 1
        exec \(ShellQuote.quote(executable.path)) resume -- \(ShellQuote.quote(session.id))

        """
        try Data(body.utf8).write(to: script, options: .atomic)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            try? fileManager.removeItem(at: script)
            throw error
        }
        return script
    }

    private func pruneOldScripts(now: Date = .now) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: scriptDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension == "command" {
            let name = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: name) != nil,
                  let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created < now.addingTimeInterval(-24 * 60 * 60) else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}

enum ShellQuote {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
