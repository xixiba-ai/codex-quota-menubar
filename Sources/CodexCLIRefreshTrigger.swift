import Foundation

enum CodexCLIRefreshTriggerError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case failed(exitCode: Int32, message: String)
    case usageLimit(resetAt: Date?, message: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            L10n.tr("未找到 Codex CLI；请先安装并登录 Codex")
        case .launchFailed(let message):
            L10n.tr("无法启动 Codex CLI：\(message)")
        case .failed(let exitCode, let message):
            L10n.tr("Codex CLI 调用失败（退出码 \(exitCode)）：\(message)")
        case .usageLimit(_, let message):
            L10n.tr("Codex 使用额度已用尽：\(message)")
        case .timedOut:
            L10n.tr("Codex CLI 调用超时")
        }
    }
}

enum CodexUsageLimitResetTime {
    /// Parses the CLI's current English rate-limit wording, e.g. "try again at 3:30 PM".
    /// The CLI only supplies minute precision, so the scheduler adds a small propagation grace.
    static func parse(from message: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let pattern = #"try again at\s+(\d{1,2})(?::(\d{2}))?\s*([AP]M)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let hourRange = Range(match.range(at: 1), in: message),
              let meridiemRange = Range(match.range(at: 3), in: message),
              let parsedHour = Int(message[hourRange]),
              (1...12).contains(parsedHour) else { return nil }

        let minute = Range(match.range(at: 2), in: message).flatMap { Int(message[$0]) } ?? 0
        guard (0..<60).contains(minute) else { return nil }
        let meridiem = message[meridiemRange].uppercased()
        let hour = (parsedHour % 12) + (meridiem == "PM" ? 12 : 0)
        let startOfToday = calendar.startOfDay(for: now)
        guard var retryAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfToday) else {
            return nil
        }

        // A response emitted a few seconds after the stated minute still refers to today.
        // For an older time, the CLI is referring to the next day's reset.
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        if retryAt < now && (hour != currentHour || minute != currentMinute) {
            retryAt = calendar.date(byAdding: .day, value: 1, to: retryAt)!
        }
        return retryAt
    }
}

enum CodexExecutableResolver {
    static func executableURL(defaults: UserDefaults = .standard) throws -> URL {
        let configured = defaults.string(forKey: "codexExecutablePath")
        let candidates = [
            configured,
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexCLIRefreshTriggerError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

/// A separate one-shot CLI invocation keeps scheduled activity independent from the long-lived
/// app-server process used only for quota reads.
struct CodexCLIRefreshTrigger: CodexRefreshTriggering {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    func trigger() async throws {
        let executable: URL
        do {
            executable = try CodexExecutableResolver.executableURL()
        } catch {
            throw error
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        process.arguments = [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never",
            "仅回复 OK。"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try await withCheckedThrowingContinuation { continuation in
            let gate = ProcessCompletionGate(continuation: continuation)
            process.terminationHandler = { completedProcess in
                let errorText = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? L10n.tr("未知错误")
                if completedProcess.terminationStatus == 0 {
                    gate.finish(.success(()))
                } else {
                    let error: CodexCLIRefreshTriggerError
                    if errorText.localizedCaseInsensitiveContains("usage limit") {
                        error = .usageLimit(
                            resetAt: CodexUsageLimitResetTime.parse(from: errorText),
                            message: errorText
                        )
                    } else {
                        error = .failed(exitCode: completedProcess.terminationStatus, message: errorText)
                    }
                    gate.finish(.failure(error))
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                gate.finish(.failure(CodexCLIRefreshTriggerError.timedOut))
            }

            do {
                try process.run()
            } catch {
                gate.finish(.failure(CodexCLIRefreshTriggerError.launchFailed(error.localizedDescription)))
            }
        }
    }
}

private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
