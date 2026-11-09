import Foundation
import Combine
import AppKit
import UserNotifications

struct CodexResetEvent: Codable, Equatable, Identifiable {
    let id: String
    let announcedAt: Date
    let announcementState: String?
    let group: String
    let type: String
    let summary: String
    let localizedSummary: String?
    let sourceURL: String?
    let bankedState: String?
    let resetKind: String?

    enum Kind: String, Codable { case confirmedReset, availableCredit, creditUpdate, unconfirmed }
    var kind: Kind {
        if group == "reset", announcementState == "announced" { return .confirmedReset }
        if group == "credits" {
            return bankedState == "available" && resetKind == "banked" ? .availableCredit : .creditUpdate
        }
        return .unconfirmed
    }
    var isNotifiable: Bool { kind == .confirmedReset || kind == .availableCredit }
    var safeURL: URL { Self.safeURL(sourceURL) }
    var displaySummary: String {
        if L10n.language == .simplifiedChinese, let localizedSummary, !localizedSummary.isEmpty { return localizedSummary }
        return summary
    }
    var label: String {
        switch kind {
        case .confirmedReset: return L10n.tr("Codex Reset 报告：全局重置")
        case .availableCredit: return L10n.tr("Codex Reset 报告：重置券可用")
        case .creditUpdate: return L10n.tr("Codex Reset：重置券动态")
        case .unconfirmed: return L10n.tr("Codex Reset：未确认动态")
        }
    }
    static let timelineURL = URL(string: "https://codex-reset.com/timeline")!
    /// Only known HTTPS source locations may leave the app. Never open arbitrary payload URLs.
    static func safeURL(_ raw: String?) -> URL {
        guard let raw, let c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              let host = c.host?.lowercased() else { return timelineURL }
        if host == "codex-reset.com", c.path == "/" || c.path == "/timeline" || c.path.hasPrefix("/timeline/") {
            return c.url ?? timelineURL
        }
        if host == "x.com" || host == "twitter.com" {
            let path = c.path.split(separator: "/")
            let authors = ["codex_reset", "thsottiaux", "openai", "openaidevs"]
            if path.count == 3, authors.contains(path[0].lowercased()), path[1] == "status",
               !path[2].isEmpty, path[2].allSatisfy({ $0.isASCII && $0.isNumber }) { return c.url ?? timelineURL }
        }
        return timelineURL
    }
}

enum CodexResetParsingError: Error { case invalidPayload }
struct CodexResetTimeline {
    let updatedAt: Date?
    let events: [CodexResetEvent]
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    /// Unknown optional fields never determine confirmation. `confirmed` and probabilities are ignored.
    static func parse(_ data: Data, now: Date = .now) throws -> CodexResetTimeline {
        guard data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["events"] as? [[String: Any]], rows.count <= 5000 else { throw CodexResetParsingError.invalidPayload }
        var ids = Set<String>()
        var events: [CodexResetEvent] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, id.count <= 256,
                  let timestamp = row["announced_at"] as? String, let time = date(timestamp), time <= now.addingTimeInterval(300),
                  let group = row["group"] as? String, !group.isEmpty,
                  let type = row["type"] as? String, !type.isEmpty,
                  let summary = row["summary"] as? String, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(id).inserted else { continue }
            events.append(CodexResetEvent(id: id, announcedAt: time, announcementState: row["announcement_state"] as? String,
                                         group: group, type: type, summary: String(summary.prefix(4000)),
                                         localizedSummary: (row["localized_summary"] as? String).map { String($0.prefix(4000)) },
                                         sourceURL: row["url"] as? String, bankedState: row["banked_state"] as? String,
                                         resetKind: row["reset_kind"] as? String))
        }
        guard rows.isEmpty || !events.isEmpty else { throw CodexResetParsingError.invalidPayload }
        return CodexResetTimeline(updatedAt: date(object["updated_at"] as? String), events: events.sorted { $0.announcedAt > $1.announcedAt })
    }
}

/// Tracks source confirmation transitions, never tweet text or the user's quota.
struct CodexResetLedger: Codable {
    struct Record: Codable { var date: Date; var wasNotifiable: Bool }
    var established = false
    var highWater: Date?
    var records: [String: Record] = [:]

    mutating func ingest(_ events: [CodexResetEvent]) -> [CodexResetEvent] {
        guard !events.isEmpty else { return [] }
        let first = !established
        let cutoff = highWater ?? .distantPast
        var notifications: [CodexResetEvent] = []
        for event in events.sorted(by: { $0.announcedAt < $1.announcedAt }) {
            let previous = records[event.id]
            let transition = previous.map { !$0.wasNotifiable && event.isNotifiable } ?? (event.announcedAt > cutoff && event.isNotifiable)
            if !first, transition { notifications.append(event) }
            records[event.id] = Record(date: event.announcedAt, wasNotifiable: (previous?.wasNotifiable ?? false) || event.isNotifiable)
            highWater = max(highWater ?? .distantPast, event.announcedAt)
        }
        established = true
        if records.count > 2048 {
            records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.date > $1.value.date }.prefix(2048).map { ($0.key, $0.value) })
        }
        return notifications
    }
}

struct CodexResetHTTPResponse {
    var data: Data
    var status: Int
    var headers: [String: String] = [:]
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    func nextAllowed(at now: Date) -> Date {
        var delay: TimeInterval = 60
        if let value = header("retry-after") {
            if let seconds = Double(value), seconds.isFinite { delay = max(delay, seconds) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                if let date = formatter.date(from: value) { delay = max(delay, date.timeIntervalSince(now)) }
            }
        }
        if let cache = header("cache-control"),
           let range = cache.range(of: #"max-age\s*=\s*\d+"#, options: .regularExpression),
           let seconds = Double(cache[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") {
            delay = max(delay, seconds - (Double(header("age") ?? "0") ?? 0))
        }
        return now.addingTimeInterval(delay)
    }
}

@MainActor
protocol CodexResetFetching { func fetch(locale: String) async throws -> CodexResetHTTPResponse }

/// Ephemeral, credential-free GET. Redirects cannot escape the same public endpoint.
final class CodexResetHTTPClient: NSObject, CodexResetFetching, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    @MainActor
    func fetch(locale: String) async throws -> CodexResetHTTPResponse {
        let url = URL(string: "https://codex-reset.com/api/timeline?locale=\(locale == "zh" ? "zh" : "en")")!
        var request = URLRequest(url: url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CodexQuotaReleaseVersion") as? String ?? "1.0.0"
        request.setValue("CodexQuotaMenuBar/\(version) (+https://github.com/xixiba-ai/codex-quota-menubar)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw CodexResetParsingError.invalidPayload }
        return CodexResetHTTPResponse(data: data, status: response.statusCode,
                                      headers: Dictionary(uniqueKeysWithValues: response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }))
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "codex-reset.com" && url?.path == "/api/timeline" && url?.user == nil && url?.password == nil && (url?.port == nil || url?.port == 443)
        completionHandler(allowed ? request : nil)
    }
}

@MainActor
protocol CodexResetNotificationSending {
    func permission() async -> String
    func authorize() async -> Bool
    func send(_ event: CodexResetEvent) async throws
    func sendTest() async throws
}

final class CodexResetSystemNotifications: NSObject, CodexResetNotificationSending, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    override init() { super.init(); center.delegate = self }
    func permission() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "authorized"
        case .notDetermined: return "notDetermined"
        default: return "denied"
        }
    }
    func authorize() async -> Bool {
        let state = await permission()
        if state == "authorized" { return true }
        guard state == "notDetermined" else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func send(_ event: CodexResetEvent) async throws {
        let content = UNMutableNotificationContent()
        content.title = event.label; content.sound = .default; content.body = event.displaySummary + "\n" + L10n.tr("第三方报告，不代表你的账号已到账；请以实际额度为准。")
        content.userInfo = ["url": event.safeURL.absoluteString]
        try await center.add(UNNotificationRequest(identifier: "codexReset.\(event.id)", content: content, trigger: nil))
    }
    func sendTest() async throws {
        let content = UNMutableNotificationContent(); content.title = L10n.tr("Codex Reset 通知测试")
        content.body = L10n.tr("这是本机通知测试，不是新的重置事件。"); content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "codexReset.test.\(UUID().uuidString)", content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["url"] as? String
        guard raw != nil else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(CodexResetEvent.safeURL(raw)) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

struct CodexResetSavedState: Codable {
    var events: [CodexResetEvent] = []
    var ledger = CodexResetLedger()
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var sourceUpdatedAt: Date?
    var sourceExpiresAt: Date?
    var sourceCheckedAt: Date?
    var nextAllowedAt = Date.distantPast
}

@MainActor
final class CodexResetMonitor: ObservableObject {
    static let enabledKey = "codexReset.enabled.v1"
    static let migrationKey = "codexReset.migratedTiboEnabled.v1"
    static let cacheKey = "codexReset.cache.v1"
    @Published private(set) var isEnabled: Bool
    @Published private(set) var saved: CodexResetSavedState
    @Published private(set) var isChecking = false
    @Published private(set) var failure: String?
    @Published private(set) var lastHTTPStatus: Int?
    @Published private(set) var notificationPermission = "unknown"
    @Published private(set) var notificationIssue: String?
    @Published private(set) var testStatus = ""
    private let defaults: UserDefaults
    private let client: any CodexResetFetching
    private let notifications: any CodexResetNotificationSending
    private let schedulesAutomatically: Bool
    private var requestTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var generation = 0

    init(defaults: UserDefaults = .standard, client: (any CodexResetFetching)? = nil,
         notifications: (any CodexResetNotificationSending)? = nil, schedulesAutomatically: Bool = true) {
        self.defaults = defaults; self.client = client ?? CodexResetHTTPClient()
        self.notifications = notifications ?? CodexResetSystemNotifications()
        self.schedulesAutomatically = schedulesAutomatically
        if !defaults.bool(forKey: Self.migrationKey) {
            if defaults.object(forKey: Self.enabledKey) == nil { defaults.set(defaults.bool(forKey: "tiboMonitorEnabled"), forKey: Self.enabledKey) }
            defaults.set(true, forKey: Self.migrationKey)
        }
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        saved = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(CodexResetSavedState.self, from: $0) } ?? CodexResetSavedState()
    }
    deinit { requestTask?.cancel(); pollTask?.cancel() }
    var events: [CodexResetEvent] { saved.events }
    var latestEvent: CodexResetEvent? { events.first }
    var latestConfirmedReset: CodexResetEvent? { events.first { $0.kind == .confirmedReset } }
    func isStale(at now: Date = .now) -> Bool {
        guard let last = saved.lastSuccessAt else { return true }
        guard let sourceTime = saved.sourceCheckedAt ?? saved.sourceUpdatedAt else { return true }
        return now.timeIntervalSince(last) > 180 || now.timeIntervalSince(sourceTime) > 300 || saved.sourceExpiresAt.map { $0 <= now } == true
    }
    func status(at now: Date = .now) -> String {
        if !isEnabled { return L10n.tr("通知已关闭；不请求 Codex Reset 数据") }
        if isChecking { return L10n.tr("正在检查 Codex Reset…") }
        if failure == "429" { return L10n.tr("请求受限；将按服务要求稍后重试") }
        if failure != nil { return saved.lastSuccessAt == nil ? L10n.tr("无法更新；尚无成功读取的数据") : L10n.tr("无法更新；保留上次成功数据") }
        if saved.lastSuccessAt == nil { return L10n.tr("等待首次检查；首次成功仅建立基线") }
        return isStale(at: now) ? L10n.tr("来源数据已过期；保留上次成功数据") : L10n.tr("来源数据已更新；无新事件也属正常")
    }
    func startIfEnabled() {
        guard isEnabled else { return }
        Task { notificationPermission = await notifications.permission() }
        if saved.nextAllowedAt > .now { scheduleNext() } else { checkNow() }
    }
    func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value; defaults.set(value, forKey: Self.enabledKey)
        if value { startIfEnabled() } else { shutdown() }
    }
    /// Cancellation never changes the saved preference (used at normal app termination).
    func shutdown() {
        generation += 1; requestTask?.cancel(); requestTask = nil; pollTask?.cancel(); pollTask = nil; isChecking = false
    }
    @discardableResult
    func checkNow(at now: Date = .now) -> Task<Void, Never>? {
        guard isEnabled, requestTask == nil, now >= saved.nextAllowedAt else { return nil }
        pollTask?.cancel(); pollTask = nil
        saved.lastAttemptAt = now; saved.nextAllowedAt = now.addingTimeInterval(60); persist()
        isChecking = true
        let epoch = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == epoch { self.isChecking = false; self.requestTask = nil; self.scheduleNext() }
            }
            do {
                let wallStart = Date.now
                let response = try await self.client.fetch(locale: L10n.language == .simplifiedChinese ? "zh" : "en")
                // Add actual elapsed time to the supplied clock, so tests and Retry-After share response receipt time.
                let receivedAt = now.addingTimeInterval(max(0, Date.now.timeIntervalSince(wallStart)))
                guard !Task.isCancelled, self.generation == epoch, self.isEnabled else { return }
                self.lastHTTPStatus = response.status
                self.saved.nextAllowedAt = response.nextAllowed(at: receivedAt)
                guard response.status == 200 else {
                    self.failure = response.status == 429 ? "429" : "http"
                    self.persist(); return
                }
                let timeline = try CodexResetTimeline.parse(response.data, now: receivedAt)
                let priorSourceTime = self.saved.sourceUpdatedAt
                // A cached older publication must not roll back confirmation state or replace newer data.
                if let older = timeline.updatedAt, let priorSourceTime, older < priorSourceTime {
                    self.failure = "olderPublication"; self.persist(); return
                }
                self.saved.events = Array(timeline.events.prefix(200))
                self.saved.lastSuccessAt = receivedAt
                self.saved.sourceUpdatedAt = timeline.updatedAt
                self.saved.sourceExpiresAt = CodexResetTimeline.date(response.header("x-published-expires-at"))
                self.saved.sourceCheckedAt = CodexResetTimeline.date(response.header("x-published-checked-at"))
                // Stale publications remain visible, but cannot establish or advance notification history.
                let candidates = self.isStale(at: receivedAt) ? [] : self.saved.ledger.ingest(timeline.events)
                self.failure = nil; self.notificationIssue = nil; self.persist()
                // Persist deduplication before best-effort delivery, avoiding replay after relaunch.
                if !candidates.isEmpty, !self.isStale(at: receivedAt) {
                    self.notificationPermission = await self.notifications.permission()
                    guard !Task.isCancelled, self.generation == epoch, self.isEnabled else { return }
                    if self.notificationPermission == "authorized" {
                        for event in candidates {
                            guard !Task.isCancelled, self.generation == epoch, self.isEnabled else { return }
                            do { try await self.notifications.send(event) }
                            catch { self.notificationIssue = "deliveryFailed" }
                        }
                    } else { self.notificationIssue = "permission" }
                }
            } catch {
                guard !Task.isCancelled, self.generation == epoch, self.isEnabled else { return }
                self.failure = "fetchOrParse"; self.persist()
            }
        }
        requestTask = task
        return task
    }
    func authorizeNotifications() {
        Task { _ = await notifications.authorize(); notificationPermission = await notifications.permission() }
    }
    func testNotification() {
        Task {
            notificationPermission = await notifications.permission()
            guard notificationPermission == "authorized" else { testStatus = L10n.tr("请先允许 macOS 通知"); return }
            do { try await notifications.sendTest(); testStatus = L10n.tr("测试通知已提交；显示效果取决于 macOS 通知设置") }
            catch { testStatus = L10n.tr("测试通知未能提交") }
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.cacheKey) }
    }
    private func scheduleNext() {
        guard schedulesAutomatically, isEnabled else { return }
        pollTask?.cancel()
        let delay = max(1, saved.nextAllowedAt.timeIntervalSinceNow)
        pollTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.pollTask = nil; self.checkNow()
        }
    }
}

#if SETTINGS_PREVIEW
@MainActor
final class CodexResetPreviewClient: CodexResetFetching {
    func fetch(locale: String) async throws -> CodexResetHTTPResponse {
        let now = Date.now
        let iso = ISO8601DateFormatter()
        let object: [String: Any] = ["updated_at": iso.string(from: now), "events": [
            ["id": "preview-reset", "announced_at": iso.string(from: now.addingTimeInterval(-3600)),
             "group": "reset", "type": "reset", "announcement_state": "announced",
             "summary": "Synthetic global reset report for the offline preview.",
             "localized_summary": "离线预览的全局重置示例报告。"]
        ]]
        return CodexResetHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200,
                                      headers: ["Cache-Control": "max-age=60"])
    }
}
@MainActor
final class CodexResetPreviewNotifications: CodexResetNotificationSending {
    func permission() async -> String { "authorized" }
    func authorize() async -> Bool { true }
    func send(_ event: CodexResetEvent) async throws {}
    func sendTest() async throws {}
}
#endif
