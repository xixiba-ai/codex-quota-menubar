import Foundation
import CoreFoundation

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
            sourceDescription: "Configured data source"
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
        case timedOut
        case requestRejected

        var errorDescription: String? {
            switch self {
            case .executableNotFound: L10n.tr("未找到 Codex CLI；请先安装并登录 Codex")
            case .invalidMessage: L10n.tr("Codex CLI 返回了无法识别的额度数据")
            case .missingRateLimits: L10n.tr("Codex CLI 未返回可用的额度周期")
            case .processStopped: L10n.tr("Codex CLI 本地额度服务已停止")
            case .timedOut: L10n.tr("Codex CLI 响应超时，请重试")
            case .requestRejected: L10n.tr("Codex CLI 拒绝了额度请求")
            }
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var rateLimitsRequestID: Int?
    private var isInitialized = false
    private var initializationContinuations: [CheckedContinuation<Void, Error>] = []
    private var rateLimitsContinuation: CheckedContinuation<CodexUsageSnapshot, Error>?
    private var updateHandler: ((CodexUsageSnapshot) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private let executableOverride: URL?
    private let requestTimeout: Duration

    init(executableURL: URL? = nil, requestTimeout: Duration = .seconds(12)) {
        executableOverride = executableURL
        self.requestTimeout = requestTimeout
    }

    func setUpdateHandler(_ handler: @escaping (CodexUsageSnapshot) -> Void) {
        updateHandler = handler
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        NotificationCenter.default.post(name: .codexQuotaActiveRefresh, object: nil)
        try await startIfNeeded()
        return try await readRateLimits()
    }

    func stop() {
        resetProcess(with: AppServerError.processStopped)
    }

    private func resetProcess(with error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        output?.readabilityHandler = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: false)
        let oldInput = input
        input = nil
        let oldProcess = process
        process = nil
        isInitialized = false
        initializeRequestID = nil
        rateLimitsRequestID = nil
        let initialization = initializationContinuations
        initializationContinuations.removeAll()
        let rateLimits = rateLimitsContinuation
        rateLimitsContinuation = nil
        initialization.forEach { $0.resume(throwing: error) }
        rateLimits?.resume(throwing: error)
        oldInput?.closeFile()
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
    }

    private func startIfNeeded() async throws {
        if isInitialized { return }
        if process != nil {
            return try await waitForInitialization()
        }

        let executable = try executableOverride ?? executableURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, let process, self.process === process else { return }
                self.resetProcess(with: AppServerError.processStopped)
            }
        }

        self.process = process
        input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        self.output = output
        output.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, let process, self.process === process else { return }
                self.receive(data: data)
            }
        }

        do {
            try process.run()
        } catch {
            resetProcess(with: error)
            throw error
        }

        try await withCheckedThrowingContinuation { continuation in
            initializationContinuations.append(continuation)
            initializeRequestID = send(method: "initialize", params: [
                "clientInfo": ["name": "Codex Quota", "version": "1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            armTimeout(for: initializeRequestID!)
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
            rateLimitsRequestID = send(method: "account/rateLimits/read", params: nil)
            armTimeout(for: rateLimitsRequestID!)
        }
    }

    private func armTimeout(for id: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            guard !Task.isCancelled, let self,
                  self.initializeRequestID == id || self.rateLimitsRequestID == id else { return }
            self.resetProcess(with: AppServerError.timedOut)
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
            if message["error"] != nil || message["result"] == nil {
                resetProcess(with: AppServerError.requestRejected)
                return
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            isInitialized = true
            initializeRequestID = nil
            let continuations = initializationContinuations
            initializationContinuations.removeAll()
            continuations.forEach { $0.resume() }
            sendNotification(method: "initialized")
            return
        }

        guard id == rateLimitsRequestID, let continuation = rateLimitsContinuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        rateLimitsContinuation = nil
        rateLimitsRequestID = nil

        do {
            if message["error"] != nil { throw AppServerError.requestRejected }
            guard let result = message["result"] as? [String: Any] else {
                throw AppServerError.invalidMessage
            }
            continuation.resume(returning: try makeSnapshot(from: result))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func makeSnapshot(from result: [String: Any]) throws -> CodexUsageSnapshot {
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
            sourceDescription: "Codex CLI (local, live)",
            rateLimitResetCredits: resetCreditsSummary(result["rateLimitResetCredits"]),
            accountID: result["accountId"] as? String,
            ordinaryUsageAllowed: result["ordinaryUsageAllowed"] as? Bool
        )
    }

    private func resetCreditsSummary(_ value: Any?) -> RateLimitResetCreditsSummary? {
        guard let value = value as? [String: Any],
              let availableCount = exactNonnegativeInteger(value["availableCount"]) else { return nil }
        let credits = (value["credits"] as? [Any])?.compactMap { item -> RateLimitResetCredit? in
            guard let item = item as? [String: Any],
                  let id = item["id"] as? String,
                  let resetType = item["resetType"] as? String,
                  let status = item["status"] as? String else { return nil }
            let expiresAt: Date?
            if let timestamp = item["expiresAt"], !(timestamp is NSNull) {
                guard let seconds = exactNonnegativeInteger(timestamp) else { return nil }
                expiresAt = Date(timeIntervalSince1970: TimeInterval(seconds))
            } else {
                expiresAt = nil
            }
            return RateLimitResetCredit(id: id, resetType: resetType, status: status, expiresAt: expiresAt)
        }
        return RateLimitResetCreditsSummary(availableCount: availableCount, credits: credits)
    }

    private func exactNonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
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

}

struct RemoteUsagePayload: Decodable {
    let shortTerm: UsageWindow
    let longTerm: UsageWindow?
    let updatedAt: Date
}

enum UsageDataSourceError: LocalizedError {
    case invalidResponse
    case noAuthorizedEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidResponse: L10n.tr("额度服务未返回有效数据")
        case .noAuthorizedEndpoint: L10n.tr("尚未配置已授权的额度数据源")
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
