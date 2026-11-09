import AppKit
import Combine
import SwiftUI
import UserNotifications
import WebKit

struct TiboVisiblePost: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let publishedAt: Date
    var url: URL { URL(string: "https://x.com/thsottiaux/status/\(id)")! }
    var isValid: Bool { !id.isEmpty && id.allSatisfy { $0 >= "0" && $0 <= "9" } && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A public post cache for display, independent of the notification delivery cursor.
struct TiboPostHighlights: Codable {
    var latest: TiboVisiblePost?
    var resets: [TiboVisiblePost] = []
    var reset: TiboVisiblePost? { resets.first }
    var checkedAt: Date?

    static func mentionsReset(_ text: String) -> Bool {
        text.range(of: #"\breset(?:s|ting)?\b|重置"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    mutating func merge(_ posts: [TiboVisiblePost], now: Date = .now) {
        let valid = posts.filter { $0.isValid && $0.publishedAt <= now.addingTimeInterval(300) }
        func newer(_ candidate: TiboVisiblePost?, than cached: TiboVisiblePost?) -> TiboVisiblePost? {
            guard let candidate else { return cached }
            guard let cached else { return candidate }
            return TiboPostCursor.less(cached.id, candidate.id) ? candidate : cached
        }
        latest = newer(valid.max { TiboPostCursor.less($0.id, $1.id) }, than: latest)
        var unique: [String: TiboVisiblePost] = [:]
        for post in resets + valid.filter({ Self.mentionsReset($0.text) }) { unique[post.id] = post }
        resets = Array(unique.values.sorted { TiboPostCursor.less($1.id, $0.id) }.prefix(3))
        checkedAt = now
    }
    var menuSummary: String {
        guard let reset else { return L10n.tr("尚未获取 Reset 相关原文") }
        let excerpt = reset.text.replacingOccurrences(of: "\n", with: " ").prefix(90)
        return "Reset · \(reset.publishedAt.formatted(date: .numeric, time: .shortened)) · \(excerpt)"
    }
    static var interpretation: String { L10n.tr("以下为 Tibo 原文；具体重置时间和是否已重置，请以原文及实际额度为准。") }
}

struct TiboPageSnapshot: Decodable {
    let authenticated: Bool
    let targetTimeline: Bool
    let posts: [TiboVisiblePost]
    var loginRequired: Bool? = nil
}

/// Snowflake IDs exceed the exact integer range of JavaScript's Number / Swift Double.
struct TiboPostCursor {
    private(set) var latestID: String?
    init(latestID: String? = nil) { self.latestID = latestID }
    static func less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
    mutating func baseline(_ posts: [TiboVisiblePost]) {
        if let newest = posts.filter({ $0.isValid && $0.publishedAt <= Date().addingTimeInterval(300) }).map(\.id).max(by: Self.less),
           latestID.map({ Self.less($0, newest) }) ?? true { latestID = newest }
    }
    func unseen(_ posts: [TiboVisiblePost], now: Date = .now) -> [TiboVisiblePost] {
        guard let latestID else { return [] }
        var seen = Set<String>()
        return posts.filter { $0.isValid && $0.publishedAt <= now.addingTimeInterval(300)
            && Self.less(latestID, $0.id) && seen.insert($0.id).inserted }
            .sorted { Self.less($0.id, $1.id) }
    }
    mutating func acknowledge(_ post: TiboVisiblePost) {
        if latestID.map({ Self.less($0, post.id) }) ?? true { latestID = post.id }
    }
}

@MainActor
protocol TiboNotificationSending {
    func authorize() async -> Bool
    func isAuthorized() async -> Bool
    func send(_ post: TiboVisiblePost) async throws
    func send(_ post: TiboVisiblePost, summary: String) async throws
    func permissionStatus() async -> String
    func sendTest() async throws -> Bool
}

extension TiboNotificationSending {
    func send(_ post: TiboVisiblePost, summary: String) async throws { try await send(post) }
    func permissionStatus() async -> String { await isAuthorized() ? "authorized" : "notAllowed" }
    func sendTest() async throws -> Bool { false }
}

struct TiboMonitorDiagnostics: Codable {
    var attemptedAt: Date?
    var lastSuccessAt: Date?
    var source = "none"
    var state = "notChecked"
    var active = false
    var authenticated: Bool?
    var targetMatched: Bool?
    var postCount: Int?
    var notificationPermission = "unknown"
    var nextScheduledAt: Date?
    var testRequestedAt: Date?
    var testAccepted: Bool?
    var testDelivered: Bool?
}

final class TiboSystemNotifications: NSObject, TiboNotificationSending, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    override init() { super.init(); center.delegate = self }
    func authorize() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { return false }
    }
    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    func permissionStatus() async -> String {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
    func sendTest() async throws -> Bool {
        let id = "quota.test.\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = "Quota 测试通知"
        content.body = "本机通知链路测试，不是 Tibo 新动态。"
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        for _ in 0..<5 {
            if await center.deliveredNotifications().contains(where: { $0.request.identifier == id }) { return true }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
    func send(_ post: TiboVisiblePost) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Tibo @thsottiaux"
        content.body = post.text
        content.sound = .default
        content.userInfo = ["postURL": post.url.absoluteString]
        try await center.add(UNNotificationRequest(identifier: "tibo.\(post.id)", content: content, trigger: nil))
    }
    func send(_ post: TiboVisiblePost, summary: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("Tibo 动态提醒")
        content.body = summary + "\n" + L10n.tr("原文：") + String(post.text.prefix(350))
        content.sound = .default
        content.userInfo = ["postURL": post.url.absoluteString]
        try await center.add(UNNotificationRequest(identifier: "tibo.\(post.id)", content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["postURL"] as? String,
           let url = URL(string: value), url.scheme == "https", url.host == "x.com",
           url.path.hasPrefix("/thsottiaux/status/") {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}

/// Reads only rendered page content. No cookies, credentials, or private X APIs are accessed.
enum TiboPageReader {
    static let script = #"""
    (() => {
      const accountSwitcher = !!document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]');
      const profileNavigation = !!document.querySelector('a[data-testid="AppTabBar_Profile_Link"]');
      const homeNavigation = !!document.querySelector('a[data-testid="AppTabBar_Home_Link"][href="/home"]');
      const memberNavigation = !!document.querySelector('a[data-testid="AppTabBar_Notifications_Link"], a[data-testid="AppTabBar_DirectMessage_Link"], nav a[href="/notifications"], nav a[href="/messages"]');
      const authenticated = accountSwitcher || profileNavigation || (homeNavigation && memberNavigation);
      const officialHost = ['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com'].includes(location.hostname);
      const targetTimeline = officialHost && /^\/thsottiaux(?:\/with_replies)?\/?$/i.test(location.pathname);
      const loginRoute = /^\/(?:login|i\/flow\/login)\/?$/i.test(location.pathname);
      const guestActions = !!document.querySelector('a[data-testid="loginButton"], [data-testid="LoginForm_Login_Button"]');
      const loginRequired = officialHost && !authenticated && (loginRoute || guestActions);
      const posts = [];
      if (officialHost && authenticated && targetTimeline) {
        for (const article of document.querySelectorAll('article[data-testid="tweet"]')) {
          const social = article.querySelector('[data-testid="socialContext"]');
          if (social && /\bpinned\b|置顶/i.test(social.textContent)) continue;
          const time = article.querySelector('time[datetime]');
          const link = time && time.closest('a');
          const match = link && new URL(link.href, location.href).pathname.match(/^\/thsottiaux\/status\/(\d+)$/i);
          const text = article.querySelector('[data-testid="tweetText"]');
          if (!match) continue;
          let body = text && text.innerText.trim();
          if (!body) {
            const photos = article.querySelectorAll('[data-testid="tweetPhoto"] img[alt]');
            body = Array.from(photos).map(image => image.alt).filter(Boolean).join('\n');
            if (!body && article.querySelector('[data-testid="videoPlayer"], [data-testid="tweetPhoto"]')) body = '[Media post — open original]';
          }
          if (!body) continue;
          const publishedAt = time.getAttribute('datetime');
          if (!publishedAt || !Number.isFinite(Date.parse(publishedAt))) continue;
          posts.push({id: match[1], text: body, publishedAt});
        }
      }
      return JSON.stringify({authenticated: officialHost && authenticated, targetTimeline, posts, loginRequired});
    })()
    """#
    static func decode(_ json: String) throws -> TiboPageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid post timestamp"))
        }
        return try decoder.decode(TiboPageSnapshot.self, from: Data(json.utf8))
    }
}

/// A literal cutoff parser only. Production callers must first verify the announcement/thread relationship.
/// No notification, preferences, or page access is performed by this value type.
struct TiboResetCutoff: Codable, Equatable {
    enum Semantics: String, Codable { case by, before }
    let deadline: Date
    let sourceZone: String
    let semantics: Semantics

    func chineseHeadline(now: Date) -> String {
        guard now < deadline else { return "预计截止时间已过，尚未确认重置" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日HH:mm"
        return "即将重置｜北京时间\(formatter.string(from: deadline))前"
    }

    static func parse(_ source: String, publishedAt: Date) -> TiboResetCutoff? {
        // Deliberately narrow: unrecognized dates, zones, or surrounding claims require human/context verification.
        let pattern = #"^\s*(by|before)\s+(?:(today|tomorrow)\s+)?(midnight|\d{1,2}(?::\d{2})?\s*(?:am|pm))\s+(PST|PDT)(?:\s+(today|tomorrow))?\s*[.!]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: source) else { return nil }
            return String(source[range])
        }
        guard let word = capture(1), let semantics = Semantics(rawValue: word.lowercased()),
              let clockText = capture(3), let zone = capture(4) else { return nil }
        let firstDay = capture(2)?.lowercased(), lastDay = capture(5)?.lowercased()
        guard firstDay == nil || lastDay == nil else { return nil }
        let day = firstDay ?? lastDay
        let clock = clockText.lowercased().replacingOccurrences(of: " ", with: "")
        let midnight = clock == "midnight"
        var hour = 0, minute = 0
        if !midnight {
            let digits = clock.dropLast(2).split(separator: ":")
            guard let first = digits.first, let value = Int(first), (1...12).contains(value) else { return nil }
            hour = value % 12 + (clock.hasSuffix("pm") ? 12 : 0)
            if digits.count == 2 {
                guard let value = Int(digits[1]), (0...59).contains(value) else { return nil }
                minute = value
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: zone.uppercased() == "PST" ? -28_800 : -25_200)!
        let start = calendar.startOfDay(for: publishedAt)
        // Midnight means the end of the named local day; an ordinary past clock time has no implied next day.
        let offset = (day == "tomorrow" ? 1 : 0) + (midnight ? 1 : 0)
        guard let localDay = calendar.date(byAdding: .day, value: offset, to: start),
              let deadline = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: localDay) else { return nil }
        if !midnight && day == nil && deadline <= publishedAt { return nil }
        return TiboResetCutoff(deadline: deadline, sourceZone: zone, semantics: semantics)
    }
}

struct TiboConversationSnapshot: Decodable {
    let focusID: String?
    let conversation: Bool
    let posts: [TiboVisiblePost]
    let ancestorIDs: [String]
}

/// A deadline is usable only after the official reply detail identifies a Tibo announcement in its ancestor chain.
struct TiboResetAnnouncement: Codable, Equatable {
    let source: TiboVisiblePost
    let timingReply: TiboVisiblePost
    let cutoff: TiboResetCutoff
    let verifiedAt: Date
    let relationshipEvidence: String

    var sourceURL: URL { source.url }
    var timingURL: URL { timingReply.url }
    func chineseHeadline(now: Date) -> String { cutoff.chineseHeadline(now: now) }
    func headline(now: Date, language: AppLanguage) -> String {
        guard language.resolved() == .english else { return chineseHeadline(now: now) }
        guard now < cutoff.deadline else { return "Expected cutoff has passed; reset is not yet confirmed" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.timeZone = TimeZone(identifier: "Asia/Shanghai")
        format.dateFormat = "MMM d, HH:mm"
        return "Reset expected | by \(format.string(from: cutoff.deadline)) Beijing time"
    }
    func explanation(language: AppLanguage) -> String {
        let zone = cutoff.sourceZone.uppercased()
        let offset = zone == "PDT" ? "UTC−7" : "UTC−8"
        return language.resolved() == .english
            ? "Tibo’s stated cutoff, converted from the original \(zone) (\(offset))"
            : "Tibo 给出的截止时间，按原文 \(zone)（\(offset)）换算"
    }

    static func verified(_ context: TiboConversationSnapshot, now: Date = .now) -> TiboResetAnnouncement? {
        guard context.conversation, let focus = context.focusID,
              let timing = context.posts.first(where: { $0.id == focus }),
              let cutoff = TiboResetCutoff.parse(timing.text, publishedAt: timing.publishedAt) else { return nil }
        let sources = context.posts.filter { post in
            guard context.ancestorIDs.contains(post.id) else { return false }
            let text = post.text.lowercased()
            guard text.range(of: #"\b(?:not|no|never|maybe|might|could|wish|hope|joke)\b|put.{0,25}reset.{0,25}bag"#, options: .regularExpression) == nil else { return false }
            return text.range(of: #"\brest and reset\b|\b(?:we will|we are going to|we're going to|will|going to) reset\b|将(?:会)?重置"#, options: .regularExpression) != nil
        }
        guard let source = sources.max(by: { TiboPostCursor.less($0.id, $1.id) }) else { return nil }
        return TiboResetAnnouncement(source: source, timingReply: timing, cutoff: cutoff,
            verifiedAt: now, relationshipEvidence: "officialConversationAncestor")
    }
}

enum TiboConversationReader {
    static let script = #"""
    (() => {
      const focus = location.pathname.match(/^\/thsottiaux\/status\/(\d+)\/?$/i);
      const sections = Array.from(document.querySelectorAll('section[aria-label], section[aria-labelledby]'));
      const conversation = sections.find(s => {
        const label = s.getAttribute('aria-label') || (s.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.textContent || '').join(' ');
        return /conversation|对话/i.test(label);
      });
      const scope = conversation || document.querySelector('[data-testid="primaryColumn"]') || document.querySelector('main');
      const posts = [];
      if (scope && ['x.com', 'www.x.com'].includes(location.hostname)) {
        for (const article of scope.querySelectorAll('article[data-testid="tweet"]')) {
          const time = article.querySelector('time[datetime]');
          const link = time && time.closest('a');
          const match = link && new URL(link.href, location.href).pathname.match(/^\/([^/]+)\/status\/(\d+)$/i);
          const text = article.querySelector('[data-testid="tweetText"]');
          const rect = article.getBoundingClientRect();
          if (match && text && time && rect.height > 0 && !posts.some(p => p.id === match[2])) {
            posts.push({id: match[2], author: match[1].toLowerCase(), text: text.innerText.trim(), publishedAt: time.getAttribute('datetime'), top: rect.top});
          }
        }
      }
      posts.sort((a,b) => a.top - b.top);
      const index = focus ? posts.findIndex(p => p.id === focus[1]) : -1;
      return JSON.stringify({focusID: focus && focus[1], conversation: !!conversation,
        posts: posts.filter(p => p.author === 'thsottiaux'),
        ancestorIDs: conversation && index > 0 ? posts.slice(0,index).map(p => p.id) : []});
    })()
    """#
    static func decode(_ json: String) throws -> TiboConversationSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: value) { return date }
            format.formatOptions = [.withInternetDateTime]
            if let date = format.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid timestamp"))
        }
        return try decoder.decode(TiboConversationSnapshot.self, from: Data(json.utf8))
    }
}

/// Displays navigation state, never interprets a loaded login page as successful authentication.
@MainActor
final class TiboLoginPage: NSObject, ObservableObject, WKNavigationDelegate {
    enum Phase { case waiting, loading, ready, failed }
    let webView: WKWebView
    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var origin = "—"
    @Published private(set) var requestedOrigin = "—"
    private var retryURL: URL?

    init(webView: WKWebView, request: URLRequest) {
        self.webView = webView
        super.init()
        remember(request)
        webView.navigationDelegate = self
    }
    var status: String {
        switch phase {
        case .waiting: return L10n.tr("等待网站打开登录页面…")
        case .loading: return L10n.tr("正在加载登录页面…")
        case .ready: return L10n.tr("页面已加载；请按网站提示继续，登录结果尚未核验。")
        case .failed: return L10n.tr("页面加载失败。请检查网络后重试，或关闭窗口重新发起登录。")
        }
    }
    var canRetry: Bool { phase == .failed && retryURL != nil }
    private func remember(_ request: URLRequest) {
        requestedOrigin = TiboMonitor.safeOrigin(request.url)
        // Keep only a GET destination in memory. Never capture or replay login form bodies.
        retryURL = (request.httpMethod ?? "GET") == "GET" ? request.url : nil
    }
    func retry() {
        guard canRetry, let retryURL else { return }
        webView.load(URLRequest(url: retryURL))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true { remember(navigationAction.request) }
        // Let the website handle its own authorization flow, including Google. No host-level block,
        // user-agent override, authorization URL forwarding, or synthetic OAuth callback.
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { phase = .loading }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        origin = TiboMonitor.safeOrigin(webView.url)
        webView.window?.title = L10n.tr("网页登录窗口") + " · " + origin
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { phase = .ready }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        phase = .failed
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { phase = .failed }
}

private struct TiboLoginPopupView: View {
    @ObservedObject var page: TiboLoginPage
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.origin == "—"
                         ? L10n.tr("目标站点：\(page.requestedOrigin)")
                         : L10n.tr("当前站点：\(page.origin)"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text(page.status).font(.caption).foregroundStyle(page.phase == .failed ? Color.orange : Color.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if page.phase == .loading { ProgressView().controlSize(.small) }
                if page.canRetry { Button(L10n.tr("重试加载")) { page.retry() } }
                Button(L10n.tr("关闭窗口"), action: close)
            }.padding(12)
            Divider()
            TiboWebView(webView: page.webView)
        }
    }
}

/// Keep a real auxiliary browsing context: loading a popup URL in the parent loses
/// window.opener, postMessage callbacks, and the original login page's state.
@MainActor
final class TiboLoginWindows: NSObject, WKUIDelegate, NSWindowDelegate {
    private(set) var windows: [ObjectIdentifier: NSWindow] = [:]
    private(set) var pages: [ObjectIdentifier: TiboLoginPage] = [:]
    var onCountChanged: ((Int) -> Void)?
    var onClose: (() -> Void)?

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Use WebKit's supplied configuration unchanged to preserve the session and opener.
        // WebKit loads the request itself after this method returns.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 700), configuration: configuration)
        popup.uiDelegate = self
        let page = TiboLoginPage(webView: popup, request: navigationAction.request)
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("网页登录窗口")
        window.contentMinSize = NSSize(width: 420, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TiboLoginPopupView(page: page, close: { [weak window] in window?.close() }))
        windows[ObjectIdentifier(popup)] = window
        pages[ObjectIdentifier(popup)] = page
        onCountChanged?(windows.count)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.stopLoading()
        windows[ObjectIdentifier(webView)]?.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }
        pages[key]?.webView.stopLoading()
        pages.removeValue(forKey: key)
        windows.removeValue(forKey: key)
        onCountChanged?(windows.count)
        onClose?()
    }
    func closeAll() {
        for window in Array(windows.values) { window.close() }
    }
    func bringForward() {
        for window in windows.values { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class TiboContextBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var result: TiboConversationSnapshot?
    @Published private(set) var status = L10n.tr("正在读取官方原帖上下文…")
    let webView: WKWebView
    var onResult: ((TiboConversationSnapshot) -> Void)?
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var urlObservation: NSKeyValueObservation?
    private var resolving = false
    private let loginWindows: TiboLoginWindows
    init(dataStore: WKWebsiteDataStore, loginWindows: TiboLoginWindows? = nil) {
        self.loginWindows = loginWindows ?? TiboLoginWindows()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 650), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self.loginWindows
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.scheduleReads() }
        }
    }
    private func ensureWindow() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 750), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            value.title = L10n.tr("Tibo 原帖上下文")
            value.isReleasedWhenClosed = false
            value.contentView = NSHostingView(rootView: TiboContextView(browser: self))
            value.center()
            window = value
        }
    }
    func show(_ post: TiboVisiblePost) {
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result = nil
        status = L10n.tr("正在读取官方原帖上下文…")
        webView.load(URLRequest(url: post.url))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scheduleReads() }
    private func scheduleReads() {
        guard !resolving else { return }
        task?.cancel()
        task = Task { [weak self] in
            for _ in 0..<15 {
                guard let self, !Task.isCancelled else { return }
                if let value = try? await self.webView.evaluateJavaScript(TiboConversationReader.script) as? String,
                   let result = try? TiboConversationReader.decode(value), !result.posts.isEmpty {
                    self.result = result
                    self.onResult?(result)
                    self.status = L10n.tr("官方会话：焦点 \(result.focusID ?? "—") · 已读取 \(result.posts.count) 条 Tibo 原文 · 祖先链 \(result.ancestorIDs.count) 条")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    /// One official page, at most thirty seconds. A hidden attached window supplies a real viewport for X rendering.
    func resolve(_ post: TiboVisiblePost) async -> TiboConversationSnapshot? {
        guard !resolving else { return nil }
        resolving = true
        defer { resolving = false; webView.stopLoading() }
        task?.cancel()
        ensureWindow()
        webView.load(URLRequest(url: post.url))
        for _ in 0..<30 {
            guard !Task.isCancelled else { return nil }
            if !webView.isLoading,
               let value = try? await webView.evaluateJavaScript(TiboConversationReader.script) as? String,
               let context = try? TiboConversationReader.decode(value), context.focusID == post.id,
               context.conversation, !context.ancestorIDs.isEmpty,
               context.posts.contains(where: { $0.id == post.id }) {
                return context
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return nil }
        }
        return nil
    }
}

private struct TiboContextView: View {
    @ObservedObject var browser: TiboContextBrowser
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(browser.status).font(.caption).textSelection(.enabled)
            TiboWebView(webView: browser.webView)
        }.padding(12)
    }
}

@MainActor
final class TiboMonitor: NSObject, ObservableObject, WKNavigationDelegate {
    static let profileURL = URL(string: "https://x.com/thsottiaux/with_replies")!
    @Published private(set) var requested = false
    @Published private(set) var active = false
    @Published private(set) var clearingSession = false
    @Published private(set) var status = L10n.tr("未启用；登录 X 后可开启页面监测") { didSet { persistDiagnostics() } }
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var pageOrigin = "—"
    @Published private(set) var pageDiagnostics = ""
    @Published private(set) var highlights = TiboPostHighlights()
    @Published private(set) var announcement: TiboResetAnnouncement?
    var latestPost: TiboVisiblePost? { highlights.latest }
    @Published private(set) var notificationTestStatus = ""
    @Published private(set) var testingNotification = false
    @Published private(set) var loginWindowCount = 0
    lazy var loginWindows: TiboLoginWindows = {
        let windows = TiboLoginWindows()
        windows.onCountChanged = { [weak self] count in self?.loginWindowsChanged(count) }
        return windows
    }()
    private(set) var diagnostics = TiboMonitorDiagnostics()
    private let defaults: UserDefaults
    private let notifier: any TiboNotificationSending
    private let websiteDataStore: WKWebsiteDataStore?
    private let contextResolver: (@MainActor (TiboVisiblePost) async -> TiboConversationSnapshot?)?
    private var contextAttempts: [String: Date] = [:]
    private lazy var automaticContextBrowser = TiboContextBrowser(dataStore: websiteDataStore ?? .default(), loginWindows: loginWindows)
    private var cursor: TiboPostCursor
    private var timer: Timer?
    private var inspectionTask: Task<Void, Never>?
    private var generation = 0
    private var inspecting = false
    private var shouldRetryPage = false
    private var view: WKWebView?
    private var urlObservation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    private var window: NSWindow?
    private lazy var contextBrowser: TiboContextBrowser = {
        let browser = TiboContextBrowser(dataStore: websiteDataStore ?? .default(), loginWindows: loginWindows)
        browser.onResult = { [weak self] context in self?.acceptContext(context) }
        return browser
    }()

    init(defaults: UserDefaults = .standard, notifier: (any TiboNotificationSending)? = nil,
         websiteDataStore: WKWebsiteDataStore? = nil,
         contextResolver: (@MainActor (TiboVisiblePost) async -> TiboConversationSnapshot?)? = nil) {
        self.contextResolver = contextResolver
        self.defaults = defaults
        self.notifier = notifier ?? TiboSystemNotifications()
        self.websiteDataStore = websiteDataStore
        cursor = TiboPostCursor(latestID: defaults.string(forKey: "tiboLastNotifiedPostID"))
        if let data = defaults.data(forKey: "tiboPostHighlights"),
           let cached = try? JSONDecoder().decode(TiboPostHighlights.self, from: data) {
            highlights = cached
        }
        if let data = defaults.data(forKey: "tiboResetAnnouncement") {
            announcement = try? JSONDecoder().decode(TiboResetAnnouncement.self, from: data)
        }
        super.init()
        // Deliberately no web view, page load, timer, or notification permission prompt at launch.
    }

    var webView: WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration()
        // The default store belongs to this app, separate from Safari. Popups share this store.
        configuration.websiteDataStore = websiteDataStore ?? .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let result = WKWebView(frame: .zero, configuration: configuration)
        result.navigationDelegate = self
        result.uiDelegate = loginWindows
        view = result
        urlObservation = result.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.scheduleInspection() }
        }
        return result
    }

    static func needsInitialPageLoad(_ url: URL?) -> Bool { url == nil || url?.scheme == "about" }

    private func loginWindowsChanged(_ count: Int) {
        loginWindowCount = count
        guard !clearingSession else { return }
        if count > 0 {
            generation += 1
            active = false
            shouldRetryPage = false
            inspectionTask?.cancel(); inspectionTask = nil
            pageDiagnostics = ""
            status = L10n.tr("登录窗口已打开；请在该窗口继续，关闭后将重新核验 X 页面。")
        } else if requested {
            status = L10n.tr("登录窗口已关闭；正在重新核验 X 页面，尚未确认登录。")
            scheduleInspection(source: "loginWindowClosed")
        } else {
            status = L10n.tr("登录窗口已关闭；尚未启用页面监测。")
        }
    }

    func showDirectSignIn() {
        guard !clearingSession, loginWindowCount == 0 else { return }
        showLogin()
        webView.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
    }

    var displayLanguage: AppLanguage { AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system }
    func resetHeadline(now: Date = .now) -> String {
        announcement?.headline(now: now, language: displayLanguage) ?? L10n.tr("重置时间尚未确认")
    }
    func acceptContext(_ context: TiboConversationSnapshot) {
        guard let candidate = TiboResetAnnouncement.verified(context) else { return }
        if let prior = announcement, TiboPostCursor.less(candidate.timingReply.id, prior.timingReply.id) { return }
        announcement = candidate
        if let data = try? JSONEncoder().encode(candidate) { defaults.set(data, forKey: "tiboResetAnnouncement") }
    }
    func notificationSummary(for post: TiboVisiblePost, now: Date = .now) -> String {
        if let announcement, post.id == announcement.timingReply.id || post.id == announcement.source.id {
            return announcement.headline(now: now, language: displayLanguage) + "\n" + announcement.explanation(language: displayLanguage)
        }
        if TiboPostHighlights.mentionsReset(post.text) { return L10n.tr("Tibo 提及重置｜具体时间尚未确认") }
        return L10n.tr("Tibo 发布了新动态；原文如下")
    }
    private func resolveTimingCandidate(in posts: [TiboVisiblePost], epoch: Int) async {
        // Tests use nonpersistent stores and an injected resolver; they never fetch real X pages.
        guard contextResolver != nil || websiteDataStore == nil else { return }
        let candidate = posts.filter { post in
            TiboResetCutoff.parse(post.text, publishedAt: post.publishedAt) != nil &&
            announcement?.timingReply.id != post.id &&
            (contextAttempts[post.id].map { Date().timeIntervalSince($0) >= 3600 } ?? true)
        }.max { TiboPostCursor.less($0.id, $1.id) }
        guard let candidate else { return }
        contextAttempts[candidate.id] = .now
        let context: TiboConversationSnapshot?
        if let contextResolver { context = await contextResolver(candidate) }
        else { context = await automaticContextBrowser.resolve(candidate) }
        guard generation == epoch, requested, let context else { return }
        acceptContext(context)
    }
    func showContext(_ post: TiboVisiblePost) { contextBrowser.show(post) }

    func showLogin() {
        guard !clearingSession else { return }
        if window == nil {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 750),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            result.title = L10n.tr("Tibo 动态通知（实验性）")
            result.isReleasedWhenClosed = false
            result.contentView = NSHostingView(rootView: TiboMonitorView(monitor: self))
            result.center()
            window = result
        }
        if loginWindowCount == 0, Self.needsInitialPageLoad(webView.url) { webView.load(URLRequest(url: Self.profileURL)) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleInspection(source: "openWindow")
    }

    func restoreIfEnabled() async {
        guard !clearingSession, !requested, defaults.bool(forKey: "tiboMonitorEnabled") else { return }
        let epoch = generation
        diagnostics.notificationPermission = await notifier.permissionStatus()
        guard await notifier.isAuthorized() else {
            status = L10n.tr("通知权限未允许；请在系统设置中允许 Codex Quota 通知")
            return
        }
        guard generation == epoch, !requested, !clearingSession else { return }
        beginMonitoring()
        diagnostics.source = "startupRestore"
        if loginWindowCount == 0 { webView.load(URLRequest(url: Self.profileURL)) }
    }

    func enable(openWindow: Bool = true) async {
        guard !requested, !clearingSession else { return }
        let epoch = generation
        guard await notifier.authorize() else {
            guard generation == epoch else { return }
            status = L10n.tr("通知权限未允许；请在系统设置中允许 Codex Quota 通知")
            return
        }
        guard generation == epoch, !requested, !clearingSession else { return }
        beginMonitoring()
        if openWindow { showLogin() }
        scheduleInspection()
    }

    private func beginMonitoring() {
        generation += 1
        requested = true
        defaults.set(true, forKey: "tiboMonitorEnabled")
        status = loginWindowCount > 0
            ? L10n.tr("登录窗口已打开；请在该窗口继续，关闭后将重新核验 X 页面。")
            : L10n.tr("等待登录并验证 @thsottiaux 时间线；尚未激活")
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll(source: "scheduled") }
        }
        persistDiagnostics()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.poll(source: "wake") }
        }
    }

    func stop(preservePreference: Bool = false) {
        generation += 1
        if !preservePreference { defaults.set(false, forKey: "tiboMonitorEnabled") }
        requested = false
        active = false
        timer?.invalidate(); timer = nil
        inspectionTask?.cancel(); inspectionTask = nil
        view?.stopLoading()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        status = L10n.tr("页面监测已停止")
    }

    func logout() async {
        guard !clearingSession else { return }
        clearingSession = true
        defer { clearingSession = false }
        stop()
        loginWindows.closeAll()
        status = L10n.tr("已退出并清除本应用的 X 登录数据；通知未激活")
        let epoch = generation
        guard let view else { return }
        view.loadHTMLString("", baseURL: nil)
        let dataStore = view.configuration.websiteDataStore
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        guard generation == epoch else { return }
        let targets = records.filter { record in
            ["x.com", "twitter.com", "twimg.com"].contains { record.displayName == $0 || record.displayName.hasSuffix("." + $0) }
        }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets)
        guard generation == epoch else { return }
        status = L10n.tr("已退出并清除本应用的 X 登录数据；通知未激活")
    }

    func poll(source: String) {
        guard requested, loginWindowCount == 0, !inspecting, view?.isLoading != true else { return }
        active = false
        diagnostics.source = source
        status = L10n.tr("正在重新核验 X 页面；提醒暂未激活")
        if let url = view?.url, ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
           url.path.lowercased().hasPrefix("/thsottiaux") {
            view?.reload()
        } else { scheduleInspection() }
    }

    private func scheduleInspection(source: String? = nil) {
        guard requested, loginWindowCount == 0 else { return }
        if let source { diagnostics.source = source }
        inspectionTask?.cancel()
        let epoch = generation
        shouldRetryPage = true
        inspectionTask = Task { [weak self] in
            // Re-read the already loaded DOM for up to roughly two minutes. Never reload X here.
            for delay in [0, 2, 3, 5, 10, 20, 30, 60] {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
                guard let self, self.requested, self.generation == epoch else { return }
                await self.inspect(epoch: epoch)
                if self.active || !self.shouldRetryPage { return }
            }
            guard let self, self.requested, self.generation == epoch, !self.active else { return }
            self.completePageRetries()
        }
    }

    func completePageRetries() {
        guard requested, loginWindowCount == 0, !active, shouldRetryPage else { return }
        status = L10n.tr("本次页面核验暂未完成；打开窗口可立即重试，下次常规检查约 60 分钟后")
    }

    private func inspect(epoch: Int) async {
        guard loginWindowCount == 0, !inspecting, let view, !view.isLoading else { return }
        diagnostics.attemptedAt = .now
        diagnostics.authenticated = nil
        diagnostics.targetMatched = nil
        diagnostics.postCount = nil
        persistDiagnostics()
        inspecting = true
        defer { inspecting = false }
        do {
            guard let json = try await view.evaluateJavaScript(TiboPageReader.script) as? String else { return }
            guard generation == epoch, requested else { return }
            let page = try TiboPageReader.decode(json)
            await receive(page, epoch: epoch)
            guard generation == epoch, requested else { return }
            if page.authenticated && !page.targetTimeline {
                view.load(URLRequest(url: Self.profileURL))
            }
        } catch {
            guard generation == epoch, requested else { return }
            active = false
            shouldRetryPage = false
            status = L10n.tr("页面读取失败，监测已暂停；请打开 X 窗口检查")
        }
    }

    // Kept independent of WebKit so permission, login loss, baseline, and delivery can be verified.
    func receive(_ page: TiboPageSnapshot, epoch: Int? = nil) async {
        let epoch = epoch ?? generation
        guard requested, loginWindowCount == 0, generation == epoch else { return }
        diagnostics.attemptedAt = .now
        diagnostics.authenticated = page.authenticated
        diagnostics.targetMatched = page.targetTimeline
        diagnostics.postCount = page.posts.filter(\.isValid).count
        diagnostics.notificationPermission = await notifier.permissionStatus()
        guard requested, generation == epoch else { return }
        defer { persistDiagnostics() }
        shouldRetryPage = false
        let readablePosts = page.posts.filter(\.isValid)
        let loginState = page.authenticated ? L10n.tr("已确认") : (page.loginRequired == true ? L10n.tr("需要登录") : L10n.tr("未知"))
        let targetState = page.targetTimeline ? L10n.tr("匹配") : L10n.tr("未匹配")
        pageDiagnostics = L10n.tr("页面检查：登录标识 \(loginState) · 目标时间线 \(targetState) · 可读动态 \(readablePosts.count)")
        guard page.authenticated else {
            active = false
            shouldRetryPage = page.loginRequired != true
            status = page.loginRequired == true
                ? L10n.tr("X 页面要求登录；请在窗口中登录后重试")
                : L10n.tr("暂未识别登录标识；正在重试，请查看 X 窗口")
            return
        }
        guard page.targetTimeline else {
            active = false
            shouldRetryPage = true
            status = L10n.tr("已识别登录；等待打开 Tibo 时间线")
            return
        }
        guard !readablePosts.isEmpty else {
            active = false
            shouldRetryPage = true
            status = L10n.tr("已识别登录；时间线尚未就绪，正在重试")
            return
        }
        highlights.merge(readablePosts)
        await resolveTimingCandidate(in: readablePosts, epoch: epoch)
        guard generation == epoch, requested else { return }
        if let data = try? JSONEncoder().encode(highlights) { defaults.set(data, forKey: "tiboPostHighlights") }
        guard await notifier.isAuthorized() else {
            guard generation == epoch, requested else { return }
            active = false
            status = L10n.tr("通知权限未允许；请在系统设置中允许 Codex Quota 通知")
            return
        }
        guard generation == epoch, requested else { return }
        if cursor.latestID == nil {
            cursor.baseline(page.posts)
        } else {
            for post in cursor.unseen(page.posts) {
                guard generation == epoch, requested else { return }
                do { try await notifier.send(post, summary: notificationSummary(for: post)) }
                catch {
                    active = false
                    status = L10n.tr("通知发送失败，稍后重试；请检查系统通知设置")
                    return
                }
                guard generation == epoch, requested else { return }
                cursor.acknowledge(post)
                persistCursor()
            }
        }
        persistCursor()
        active = true
        lastCheckedAt = .now
        diagnostics.lastSuccessAt = lastCheckedAt
        status = L10n.tr("页面监测中 · 约每 60 分钟检查 · 尽力提醒")
    }

    private func persistDiagnostics() {
        diagnostics.state = status
        diagnostics.active = active
        diagnostics.nextScheduledAt = timer?.fireDate
        if let data = try? JSONEncoder().encode(diagnostics), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: "tiboMonitorDiagnostics")
        }
    }

    func sendTestNotification() async {
        guard !testingNotification else { return }
        testingNotification = true
        defer { testingNotification = false; persistDiagnostics() }
        diagnostics.testRequestedAt = .now
        diagnostics.testAccepted = nil
        diagnostics.testDelivered = nil
        diagnostics.notificationPermission = await notifier.permissionStatus()
        guard await notifier.isAuthorized() else {
            notificationTestStatus = L10n.tr("测试未发送：系统通知权限未允许")
            return
        }
        notificationTestStatus = L10n.tr("正在验证本机测试通知…")
        do {
            let delivered = try await notifier.sendTest()
            diagnostics.testAccepted = true
            diagnostics.testDelivered = delivered
            notificationTestStatus = delivered
                ? L10n.tr("测试通知：系统已接受，已在通知中心核验送达；横幅是否可见取决于系统设置")
                : L10n.tr("测试通知：系统已接受，暂未在通知中心核验送达")
        } catch {
            diagnostics.testAccepted = false
            diagnostics.testDelivered = false
            notificationTestStatus = L10n.tr("测试通知请求失败")
        }
    }

    private func persistCursor() { defaults.set(cursor.latestID, forKey: "tiboLastNotifiedPostID") }

    static func safeOrigin(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else { return "—" }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageOrigin = Self.safeOrigin(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scheduleInspection() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        active = false
        if requested { status = L10n.tr("页面读取失败，监测已暂停；请打开 X 窗口检查") }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}

private struct TiboWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct TiboMonitorView: View {
    @ObservedObject var monitor: TiboMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { tick in
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.resetHeadline(now: tick.date)).font(.title3.bold())
                    if let announcement = monitor.announcement {
                        Text(announcement.explanation(language: monitor.displayLanguage)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(monitor.status).font(.caption).foregroundStyle(.secondary)
            if !monitor.pageDiagnostics.isEmpty {
                Text(monitor.pageDiagnostics).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.tr("请在下方官方 X 页面自行登录，再开启通知。仅监测可见的 Tibo 原文；首次建立基线，不发送历史通知。网页变化、休眠或断网可能漏报，无法保证实时。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Button(L10n.tr("使用 X 账号登录")) { monitor.showDirectSignIn() }
                    .disabled(monitor.clearingSession || monitor.loginWindowCount > 0)
                if monitor.loginWindowCount > 0 {
                    Button(L10n.tr("显示登录窗口")) { monitor.loginWindows.bringForward() }
                }
                Text(L10n.tr("第三方登录会在独立窗口中打开；能否完成登录以网站提示为准。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.tr("原文与时间依据")) {
                if let announcement = monitor.announcement {
                    VStack(alignment: .leading, spacing: 5) {
                        postCard(announcement.source, title: L10n.tr("重置公告原文"))
                        postCard(announcement.timingReply, title: L10n.tr("时间回复原文"))
                        Text(L10n.tr("已核实官方回复祖先链。PST 按固定 UTC−8 换算；若作者泛指美西夏令时，时间可能相差一小时，原文未澄清。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(L10n.tr("其他已获取原文")) {
            if monitor.highlights.reset != nil || monitor.highlights.latest != nil {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(monitor.highlights.resets) { post in
                        postCard(post, title: L10n.tr("Reset 相关原文"))
                    }
                    if let post = monitor.highlights.latest, !monitor.highlights.resets.contains(where: { $0.id == post.id }) {
                        postCard(post, title: L10n.tr("最新 Tibo 动态"))
                    }
                    Text(TiboPostHighlights.interpretation).font(.caption).foregroundStyle(.secondary)
                    if let checked = monitor.highlights.checkedAt {
                        Text(L10n.tr("内容最近核验：\(checked.formatted(date: .numeric, time: .standard))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !monitor.active {
                        Text(L10n.tr("显示上次获取的内容；当前检查尚未成功，信息可能已过时。"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(L10n.tr("尚未获取 Reset 相关原文")).font(.caption)
            }
            }
            HStack {
                Button(L10n.tr("开启页面监测通知")) { Task { await monitor.enable() } }.disabled(monitor.requested || monitor.clearingSession)
                Button(L10n.tr("停止监测")) { monitor.stop() }.disabled(!monitor.requested)
                Button(L10n.tr("退出 X 并清除登录")) { Task { await monitor.logout() } }.disabled(monitor.clearingSession)
                if let time = monitor.lastCheckedAt { Text(time.formatted(date: .omitted, time: .standard)).font(.caption) }
            }
            HStack {
                Button(L10n.tr("发送测试通知")) { Task { await monitor.sendTestNotification() } }
                    .disabled(monitor.testingNotification)
                Text(monitor.notificationTestStatus).font(.caption)
            }
            Text(L10n.tr("当前站点：\(monitor.pageOrigin)"))
                .font(.caption.monospaced()).textSelection(.enabled)
            TiboWebView(webView: monitor.webView)
        }.padding(12)
    }
    private func postCard(_ post: TiboVisiblePost, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.bold())
                Text(post.publishedAt.formatted(date: .numeric, time: .standard)).font(.caption)
                Link(L10n.tr("查看原文 ↗"), destination: post.url).font(.caption)
                Button(L10n.tr("查看上下文")) { monitor.showContext(post) }.font(.caption)
            }
            Text(post.text).font(.callout).lineLimit(3).textSelection(.enabled)
        }
    }

}
