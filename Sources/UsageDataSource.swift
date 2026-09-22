import Foundation

@MainActor
protocol UsageDataSource: AnyObject {
    func fetchUsage() async throws -> CodexUsageSnapshot
}

/// A source that can also deliver changes as Codex reports them.
@MainActor
protocol LiveUsageDataSource: UsageDataSource {
    func setUpdateHandler(_ handler: @escaping (CodexUsageSnapshot) -> Void)
    func stop()
}

/// Default development source. It keeps the app usable before an authorized data source is configured.
final class MockUsageDataSource: UsageDataSource {
    func fetchUsage() async throws -> CodexUsageSnapshot {
        NotificationCenter.default.post(name: .codexQuotaActiveRefresh, object: nil)
        return CodexUsageSnapshot.preview
    }
}

/// Adapter for an explicitly authorized, official endpoint supplied by the user or their organization.
/// Expected JSON: {"shortTerm":{"remainingPercent":65,"resetsAt":"ISO-8601"},
///                 "longTerm":{"remainingPercent":55,"resetsAt":"ISO-8601"}}
final class RemoteJSONUsageDataSource: UsageDataSource {
    let endpoint: URL
    let bearerToken: String?

    init(endpoint: URL, bearerToken: String?) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        NotificationCenter.default.post(name: .codexQuotaActiveRefresh, object: nil)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UsageDataSourceError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RemoteUsagePayload.self, from: data)
        return CodexUsageSnapshot(
            shortTerm: payload.shortTerm,
            longTerm: payload.longTerm,
            updatedAt: payload.updatedAt,
            sourceDescription: "已配置的数据源"
        )
    }
}

/// Reads the signed-in CLI's local app-server protocol. This protocol is experimental, so the
/// source is deliberately isolated here and the UI can still fall back to the existing sources.
@MainActor
final class CodexAppServerUsageDataSource: LiveUsageDataSource {
    private enum AppServerError: LocalizedError {
        case executableNotFound
        case invalidMessage
        case missingRateLimits
        case processStopped

        var errorDescription: String? {
            switch self {
            case .executableNotFound: "未找到 Codex CLI；请先安装并登录 Codex"
            case .invalidMessage: "Codex CLI 返回了无法识别的额度数据"
            case .missingRateLimits: "Codex CLI 未返回可用的额度周期"
            case .processStopped: "Codex CLI 本地额度服务已停止"
            }
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var isInitialized = false
    private var initializationContinuations: [CheckedContinuation<Void, Error>] = []
    private var rateLimitsContinuation: CheckedContinuation<CodexUsageSnapshot, Error>?
    private var updateHandler: ((CodexUsageSnapshot) -> Void)?

    func setUpdateHandler(_ handler: @escaping (CodexUsageSnapshot) -> Void) {
        updateHandler = handler
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        NotificationCenter.default.post(name: .codexQuotaActiveRefresh, object: nil)
        try await startIfNeeded()
        return try await readRateLimits()
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
    }

    private func startIfNeeded() async throws {
        if isInitialized { return }
        if process != nil {
            return try await waitForInitialization()
        }

        let executable = try executableURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.didStop(with: AppServerError.processStopped) }
        }

        self.process = process
        input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        self.output = output
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.receive(data: data)
            }
        }

        do {
            try process.run()
        } catch {
            stop()
            throw error
        }

        try await withCheckedThrowingContinuation { continuation in
            initializationContinuations.append(continuation)
            initializeRequestID = send(method: "initialize", params: [
                "clientInfo": ["name": "Codex Quota", "version": "1.0"],
                "capabilities": ["experimentalApi": true]
            ])
        }
    }

    private func waitForInitialization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            initializationContinuations.append(continuation)
        }
    }

    private func readRateLimits() async throws -> CodexUsageSnapshot {
        guard rateLimitsContinuation == nil else {
            throw AppServerError.invalidMessage
        }
        return try await withCheckedThrowingContinuation { continuation in
            rateLimitsContinuation = continuation
            send(method: "account/rateLimits/read", params: nil)
        }
    }

    private func receive(data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            receive(line: String(decoding: lineData, as: UTF8.self))
        }
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        if let id = message["id"] as? Int {
            handleResponse(id: id, message: message)
        } else if let method = message["method"] as? String,
                  method == "account/rateLimits/updated" {
            Task { [weak self] in
                guard let self, self.rateLimitsContinuation == nil,
                      let snapshot = try? await self.readRateLimits() else { return }
                self.updateHandler?(snapshot)
            }
        }
    }

    private func handleResponse(id: Int, message: [String: Any]) {
        if id == initializeRequestID {
            isInitialized = true
            initializeRequestID = nil
            let continuations = initializationContinuations
            initializationContinuations.removeAll()
            continuations.forEach { $0.resume() }
            sendNotification(method: "initialized")
            return
        }

        guard let continuation = rateLimitsContinuation else { return }
        rateLimitsContinuation = nil

        do {
            guard let result = message["result"] as? [String: Any] else {
                throw AppServerError.invalidMessage
            }
            continuation.resume(returning: try makeSnapshot(from: result))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func makeSnapshot(from result: [String: Any]) throws -> CodexUsageSnapshot {
        let allLimits = result["rateLimitsByLimitId"] as? [String: Any]
        let selected = (allLimits?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        guard let selected,
              let primary = usageWindow(selected["primary"]) else {
            throw AppServerError.missingRateLimits
        }
        return CodexUsageSnapshot(
            shortTerm: primary,
            longTerm: usageWindow(selected["secondary"]),
            updatedAt: .now,
            sourceDescription: "Codex CLI（本机实时）"
        )
    }

    private func usageWindow(_ value: Any?) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = value["usedPercent"] as? NSNumber,
              let resetsAt = value["resetsAt"] as? NSNumber else { return nil }
        return UsageWindow(
            remainingPercent: 100 - used.intValue,
            resetsAt: Date(timeIntervalSince1970: resetsAt.doubleValue),
            windowDurationMinutes: (value["windowDurationMins"] as? NSNumber)?.intValue
        )
    }

    @discardableResult
    private func send(method: String, params: Any?) -> Int {
        let id = nextRequestID
        nextRequestID += 1
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        write(request)
        return id
    }

    private func sendNotification(method: String) {
        write(["method": method])
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var text = String(data: data, encoding: .utf8) else { return }
        text.append("\n")
        input?.write(Data(text.utf8))
    }

    private func executableURL() throws -> URL {
        do {
            return try CodexExecutableResolver.executableURL()
        } catch CodexCLIRefreshTriggerError.executableNotFound {
            throw AppServerError.executableNotFound
        }
    }

    private func didStop(with error: Error) {
        guard process != nil else { return }
        output?.readabilityHandler = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: false)
        input = nil
        process = nil
        isInitialized = false
        initializeRequestID = nil
        let continuations = initializationContinuations
        initializationContinuations.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        rateLimitsContinuation?.resume(throwing: error)
        rateLimitsContinuation = nil
    }
}

private struct RemoteUsagePayload: Decodable {
    let shortTerm: UsageWindow
    let longTerm: UsageWindow?
    let updatedAt: Date
}

enum UsageDataSourceError: LocalizedError {
    case invalidResponse
    case noAuthorizedEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "额度服务未返回有效数据"
        case .noAuthorizedEndpoint: "尚未配置已授权的额度数据源"
        }
    }
}

enum UsageDataSourceFactory {
    @MainActor
    static func make() -> any UsageDataSource {
        guard let value = UserDefaults.standard.string(forKey: "usageEndpoint"),
              let endpoint = URL(string: value),
              endpoint.scheme == "https" else {
            return CodexAppServerUsageDataSource()
        }
        return RemoteJSONUsageDataSource(
            endpoint: endpoint,
            bearerToken: UserDefaults.standard.string(forKey: "usageEndpointBearerToken")
        )
    }
}
