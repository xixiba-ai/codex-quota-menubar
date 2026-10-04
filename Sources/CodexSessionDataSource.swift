import Foundation

@MainActor
final class CodexSessionDataSource {
    enum Error: LocalizedError {
        case executableNotFound
        case invalidMessage
        case processStopped
        case requestFailed(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound: return L10n.tr("未找到 Codex CLI；请先安装并登录 Codex")
            case .invalidMessage: return L10n.tr("Codex CLI 返回了无法识别的会话数据")
            case .processStopped: return L10n.tr("Codex CLI 本地会话服务已停止")
            case let .requestFailed(code, message):
                if code == -32600,
                   message.hasPrefix("thread "),
                   message.hasSuffix(" already has an active writer") {
                    return L10n.tr("会话仍被 Codex 或其他客户端占用。请先在对应客户端关闭该会话，再重试删除。")
                }
                return L10n.tr("Codex CLI 拒绝了会话请求（\(code)）：\(message)")
            }
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var isInitialized = false
    private var initializationTask: Task<Void, Swift.Error>?
    private var responseContinuations: [Int: CheckedContinuation<[String: Any], Swift.Error>] = [:]

    func listSessions() async throws -> [CodexSession] {
        try await startIfNeeded()

        var sessions: [CodexSession] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [
                "limit": 100,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "sourceKinds": ["cli", "vscode"]
            ]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "thread/list", params: params)
            guard let data = result["data"] as? [[String: Any]] else { throw Error.invalidMessage }
            sessions.append(contentsOf: data.compactMap(CodexSession.init(payload:)))
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        return sessions
    }

    func deleteSession(id: String) async throws {
        try await startIfNeeded()
        _ = try await request(method: "thread/delete", params: ["threadId": id])
    }

    func stop() {
        output?.readabilityHandler = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: false)
        input?.closeFile()
        input = nil
        process?.terminate()
        process = nil
        isInitialized = false
        initializationTask?.cancel()
        initializationTask = nil
        let continuations = responseContinuations
        responseContinuations.removeAll()
        continuations.values.forEach { $0.resume(throwing: Error.processStopped) }
    }

    private func startIfNeeded() async throws {
        if isInitialized { return }
        if let initializationTask { return try await initializationTask.value }

        let task = Task<Void, Swift.Error> { @MainActor [weak self] in
            guard let self else { throw Error.processStopped }
            let executable: URL
            do {
                executable = try CodexExecutableResolver.executableURL()
            } catch {
                throw Error.executableNotFound
            }

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executable
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.didStop() }
            }
            self.process = process
            self.input = inputPipe.fileHandleForWriting
            self.output = outputPipe.fileHandleForReading
            self.output?.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.receive(data: data) }
            }
            do {
                try process.run()
                _ = try await self.request(method: "initialize", params: [
                    "clientInfo": ["name": "Codex Quota", "version": "1.0"],
                    "capabilities": ["experimentalApi": true]
                ])
                self.isInitialized = true
                self.sendNotification(method: "initialized")
            } catch {
                self.stop()
                throw error
            }
        }
        initializationTask = task
        defer { initializationTask = nil }
        try await task.value
    }

    private func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let id = send(method: method, params: params)
            responseContinuations[id] = continuation
        }
    }

    private func receive(data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = message["id"] as? Int,
                  let continuation = responseContinuations.removeValue(forKey: id) else { continue }
            do {
                continuation.resume(returning: try Self.decodeResponse(message))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// JSON-RPC failures are valid responses, not malformed session data.
    static func decodeResponse(_ message: [String: Any]) throws -> [String: Any] {
        if let error = message["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let description = error["message"] as? String {
            throw Error.requestFailed(code: code, message: description)
        }
        guard message["error"] == nil,
              let result = message["result"] as? [String: Any] else {
            throw Error.invalidMessage
        }
        return result
    }

    @discardableResult
    private func send(method: String, params: [String: Any]?) -> Int {
        let id = nextRequestID
        nextRequestID += 1
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        write(request)
        return id
    }

    private func sendNotification(method: String) { write(["method": method]) }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var text = String(data: data, encoding: .utf8) else { return }
        text.append("\n")
        input?.write(Data(text.utf8))
    }

    private func didStop() {
        guard process != nil else { return }
        output?.readabilityHandler = nil
        output = nil
        input = nil
        process = nil
        isInitialized = false
        let continuations = responseContinuations
        responseContinuations.removeAll()
        continuations.values.forEach { $0.resume(throwing: Error.processStopped) }
    }
}

private extension CodexSession {
    init?(payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let preview = payload["preview"] as? String,
              let cwd = payload["cwd"] as? String,
              let createdAt = (payload["createdAt"] as? NSNumber)?.doubleValue,
              let updatedAt = (payload["updatedAt"] as? NSNumber)?.doubleValue else { return nil }
        self.id = id
        self.name = payload["name"] as? String
        self.preview = preview
        self.cwd = cwd
        self.createdAt = Date(timeIntervalSince1970: createdAt)
        self.updatedAt = Date(timeIntervalSince1970: updatedAt)
        let statusPayload = payload["status"] as? [String: Any]
        switch statusPayload?["type"] as? String {
        case "notLoaded": self.status = .notLoaded
        case "idle": self.status = .idle
        case "active": self.status = .active(flags: statusPayload?["activeFlags"] as? [String] ?? [])
        case "systemError": self.status = .systemError
        case let value?: self.status = .unknown(value)
        case nil: self.status = .unknown("")
        }
    }
}
