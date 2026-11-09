import XCTest
import WebKit
import SwiftUI
@testable import Codex_Quota

@MainActor
final class TiboMonitorTests: XCTestCase {
    func testLoginViewsHandleAuxiliaryWindowsWithoutEnablingAutomaticPopups() {
        let (monitor, _, _) = makeMonitor()
        XCTAssertTrue(monitor.webView.uiDelegate === monitor.loginWindows)
        XCTAssertFalse(monitor.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        let context = TiboContextBrowser(dataStore: .nonPersistent(), loginWindows: monitor.loginWindows)
        XCTAssertTrue(context.webView.uiDelegate === monitor.loginWindows)
        XCTAssertFalse(context.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(monitor.requested)
        XCTAssertNil(monitor.webView.url)
    }

    func testPopupRetainsOpenerSessionCallbackAndClosesCleanly() async throws {
        let (view, windows) = try await loginFixture()
        defer { windows.closeAll(); view.stopLoading() }
        var closes = 0
        windows.onClose = { closes += 1 }
        _ = try await view.evaluateJavaScript("window.fixturePopup = window.open('about:blank', 'oauth-fixture'); true")
        try await waitForLoginFixture { !windows.windows.isEmpty }
        let popup = try XCTUnwrap(windows.pages.values.first?.webView)
        XCTAssertTrue(popup.configuration.websiteDataStore === view.configuration.websiteDataStore)
        XCTAssertTrue(popup.uiDelegate === windows)
        try await waitForLoginFixture { (try? await popup.evaluateJavaScript("window.opener !== null")) as? Bool == true }
        _ = try await popup.evaluateJavaScript("window.opener.postMessage('oauth-fixture', '*'); true")
        try await waitForLoginFixture { (try? await view.evaluateJavaScript("window.gotReply === true")) as? Bool == true }
        let parentText = try await view.evaluateJavaScript("document.getElementById('fixture-root').textContent") as? String
        XCTAssertEqual(parentText, "Parent login page")
        _ = try? await popup.evaluateJavaScript("window.close(); true")
        try await waitForLoginFixture { windows.windows.isEmpty }
        XCTAssertEqual(closes, 1)

        // Native window closure and logout cleanup must release retained web views too.
        _ = try await view.evaluateJavaScript("window.open('about:blank', 'second-fixture'); true")
        try await waitForLoginFixture { !windows.windows.isEmpty }
        windows.windows.values.first?.close()
        XCTAssertTrue(windows.windows.isEmpty)
        _ = try await view.evaluateJavaScript("window.open('about:blank', 'third-fixture'); true")
        try await waitForLoginFixture { !windows.windows.isEmpty }
        windows.closeAll()
        XCTAssertTrue(windows.windows.isEmpty)
        XCTAssertEqual(closes, 3)
    }

    func testGoogleHostPopupFromIframeAndBlankPopupRedirectAreAllowedWithoutNetwork() async throws {
        let handler = LoginFixtureSchemeHandler()
        let (view, windows) = try await loginFixture(handler: handler)
        defer { windows.closeAll(); view.stopLoading() }
        // The custom scheme is served locally. Its Google hostname catches the old host-level
        // rejection without sending any request to Google's authentication service.
        _ = try await view.evaluateJavaScript("document.querySelector('iframe').contentWindow.open('tibo-login-fixture://accounts.google.com/iframe', 'google-fixture'); true")
        try await waitForLoginFixture { windows.pages.values.first?.phase == .ready }
        let page = try XCTUnwrap(windows.pages.values.first)
        XCTAssertEqual(page.origin, "tibo-login-fixture://accounts.google.com")
        XCTAssertEqual(handler.received.map(\.path), ["/iframe"])
        XCTAssertTrue(page.webView.configuration.websiteDataStore === view.configuration.websiteDataStore)
        XCTAssertEqual(page.webView.customUserAgent ?? "", view.customUserAgent ?? "")
        windows.closeAll()

        _ = try await view.evaluateJavaScript("window.open('about:blank', 'redirect-fixture'); true")
        try await waitForLoginFixture { !windows.pages.isEmpty }
        let redirected = try XCTUnwrap(windows.pages.values.first)
        _ = try await redirected.webView.evaluateJavaScript("location.href = 'tibo-login-fixture://accounts.google.com/redirect'; true")
        try await waitForLoginFixture { redirected.phase == .ready && redirected.origin == "tibo-login-fixture://accounts.google.com" }
        XCTAssertEqual(handler.received.map(\.path), ["/iframe", "/redirect"])
        XCTAssertEqual(windows.windows.count, 1)
        XCTAssertEqual(TiboMonitor.safeOrigin(URL(string: "https://accounts.google.com/oauth?state=private#secret")), "https://accounts.google.com")
    }

    func testPopupFailureOffersGETRetryWithoutLeakingURLOrTreatingCancellationAsFailure() async throws {
        let handler = LoginFixtureSchemeHandler()
        handler.failNext = true
        let (view, windows) = try await loginFixture(handler: handler)
        defer { windows.closeAll(); view.stopLoading() }
        _ = try await view.evaluateJavaScript("window.open('tibo-login-fixture://accounts.google.com/retry?state=fixture-private', 'retry-fixture'); true")
        try await waitForLoginFixture { windows.pages.values.first?.phase == .failed }
        let page = try XCTUnwrap(windows.pages.values.first)
        XCTAssertTrue(page.canRetry)
        XCTAssertEqual(page.requestedOrigin, "tibo-login-fixture://accounts.google.com")
        XCTAssertFalse(page.status.contains("fixture-private"))
        page.retry()
        try await waitForLoginFixture { page.phase == .ready }
        XCTAssertEqual(handler.received.count, 2)
        XCTAssertFalse(page.canRetry)
        page.webView(page.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(page.phase, .ready, "Replacing a navigation must not display a login failure")

        let postRequest = NSMutableURLRequest(url: URL(string: "tibo-login-fixture://accounts.google.com/form")!)
        postRequest.httpMethod = "POST"
        let postPage = TiboLoginPage(webView: view, request: postRequest as URLRequest)
        postPage.webView(view, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(postPage.phase, .failed)
        XCTAssertFalse(postPage.canRetry, "Native retry must not replay login form submissions")
    }

    func testOpenLoginWindowPausesMonitoringAndLogoutClosesIt() async throws {
        let (monitor, notifier, defaults) = makeMonitor()
        defer { monitor.stop(); monitor.loginWindows.closeAll() }
        let view = monitor.webView
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        view.loadHTMLString("<p id='fixture-root'>Original login page</p>", baseURL: nil)
        try await waitForLoginFixture {
            guard !view.isLoading else { return false }
            return (try? await view.evaluateJavaScript("!!document.getElementById('fixture-root')")) as? Bool == true
        }
        await monitor.enable(openWindow: false)
        await monitor.receive(page([post("10")]))
        XCTAssertTrue(monitor.active)
        _ = try await view.evaluateJavaScript("window.open('about:blank', 'monitor-fixture'); true")
        try await waitForLoginFixture { monitor.loginWindowCount == 1 }
        XCTAssertFalse(monitor.active)
        XCTAssertTrue(monitor.requested)
        let waiting = monitor.status
        let source = monitor.diagnostics.source
        monitor.poll(source: "scheduled")
        monitor.poll(source: "wake")
        monitor.completePageRetries()
        await monitor.receive(page([post("11")]))
        XCTAssertEqual(monitor.status, waiting)
        XCTAssertEqual(monitor.diagnostics.source, source)
        XCTAssertEqual(defaults.string(forKey: "tiboLastNotifiedPostID"), "10")
        XCTAssertTrue(notifier.sent.isEmpty)
        XCTAssertEqual(monitor.loginWindowCount, 1)
        monitor.loginWindows.closeAll()
        XCTAssertEqual(monitor.loginWindowCount, 0)
        XCTAssertFalse(monitor.active, "Closing a window does not prove authentication succeeded")
        XCTAssertEqual(monitor.diagnostics.source, "loginWindowClosed")
        _ = try await view.evaluateJavaScript("window.open('about:blank', 'logout-fixture'); true")
        try await waitForLoginFixture { monitor.loginWindowCount == 1 }
        await monitor.logout()
        XCTAssertEqual(monitor.loginWindowCount, 0)
        XCTAssertTrue(monitor.loginWindows.pages.isEmpty)
        XCTAssertTrue(monitor.loginWindows.windows.isEmpty)
        XCTAssertFalse(monitor.requested)
        XCTAssertFalse(monitor.active)
    }

    private func loginFixture(handler: LoginFixtureSchemeHandler? = nil) async throws -> (WKWebView, TiboLoginWindows) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let handler { configuration.setURLSchemeHandler(handler, forURLScheme: "tibo-login-fixture") }
        // evaluateJavaScript has no mouse gesture; allow automatic windows only in this local fixture.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let windows = TiboLoginWindows()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.uiDelegate = windows
        view.loadHTMLString("<p id='fixture-root'>Parent login page</p><iframe srcdoc='<p>Login button frame</p>'></iframe><script>window.gotReply = false; addEventListener('message', e => { if (e.data === 'oauth-fixture') window.gotReply = true; });</script>", baseURL: nil)
        try await waitForLoginFixture {
            (try? await view.evaluateJavaScript("!!document.getElementById('fixture-root') && !!document.querySelector('iframe').contentDocument.querySelector('p')")) as? Bool == true
        }
        return (view, windows)
    }

    private func waitForLoginFixture(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Local login window fixture did not reach the expected state")
        throw NSError(domain: "TiboLoginFixture", code: 1)
    }

    func testAutomaticContextPrecedesLocalizedNewNotificationAndOldPostsRemainSilent() async throws {
        let iso = ISO8601DateFormatter()
        let source = TiboVisiblePost(id: "2114200152701575656", text: "Day 20/ Rest and reset", publishedAt: iso.date(from: "2026-10-25T03:39:31Z")!)
        let reply = TiboVisiblePost(id: "2114200291319124163", text: "By midnight PST", publishedAt: iso.date(from: "2026-10-25T03:40:04Z")!)
        let context = TiboConversationSnapshot(focusID: reply.id, conversation: true, posts: [source, reply], ancestorIDs: [source.id])
        let defaults = UserDefaults(suiteName: "TiboTests.\(UUID().uuidString)")!
        defaults.set("zh-Hans", forKey: AppLanguage.defaultsKey)
        defaults.set(source.id, forKey: "tiboLastNotifiedPostID")
        let notifier = TestTiboNotifications()
        var requests = 0
        let monitor = TiboMonitor(defaults: defaults, notifier: notifier, websiteDataStore: .nonPersistent(), contextResolver: { _ in requests += 1; return context })
        defer { monitor.stop() }
        await monitor.enable(openWindow: false)
        await monitor.receive(page([source, reply]))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(notifier.sent.map(\.id), [reply.id])
        let announcement = try XCTUnwrap(monitor.announcement)
        XCTAssertTrue(try XCTUnwrap(notifier.summaries.last).hasPrefix(announcement.chineseHeadline(now: .now)))
        XCTAssertTrue(try XCTUnwrap(notifier.summaries.last).contains("UTC−8"))
        XCTAssertNotNil(defaults.data(forKey: "tiboResetAnnouncement"))
        await monitor.receive(page([source, reply]))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(notifier.sent.count, 1)
        let reopened = TiboMonitor(defaults: defaults, notifier: notifier, websiteDataStore: .nonPersistent(), contextResolver: { _ in XCTFail("Cached timing reply must not refetch"); return nil })
        defer { reopened.stop() }
        await reopened.enable(openWindow: false)
        await reopened.receive(page([source, reply]))
        XCTAssertEqual(notifier.sent.count, 1, "Historical announcement display must not replay notifications")
        XCTAssertEqual(reopened.announcement?.source.id, source.id)
        XCTAssertEqual(announcement.headline(now: reply.publishedAt, language: .english), "Reset expected | by Oct 25, 16:00 Beijing time")
    }

    func testAnnouncementRequiresVerifiedOfficialAncestor() throws {
        let iso = ISO8601DateFormatter()
        let source = TiboVisiblePost(id: "2114200152701575656", text: "Day 20/ Rest and reset", publishedAt: iso.date(from: "2026-10-25T03:39:31Z")!)
        let reply = TiboVisiblePost(id: "2114200291319124163", text: "By midnight PST", publishedAt: iso.date(from: "2026-10-25T03:40:04Z")!)
        let context = TiboConversationSnapshot(focusID: reply.id, conversation: true, posts: [source, reply], ancestorIDs: [source.id])
        let announcement = try XCTUnwrap(TiboResetAnnouncement.verified(context, now: reply.publishedAt))
        XCTAssertEqual(announcement.chineseHeadline(now: reply.publishedAt), "即将重置｜北京时间10月25日16:00前")
        XCTAssertEqual(announcement.chineseHeadline(now: announcement.cutoff.deadline), "预计截止时间已过，尚未确认重置")
        XCTAssertEqual(announcement.sourceURL.absoluteString, "https://x.com/thsottiaux/status/2114200152701575656")
        XCTAssertEqual(try JSONDecoder().decode(TiboResetAnnouncement.self, from: JSONEncoder().encode(announcement)), announcement)
        XCTAssertNil(TiboResetAnnouncement.verified(TiboConversationSnapshot(focusID: reply.id, conversation: true, posts: [source, reply], ancestorIDs: [])))
        XCTAssertNil(TiboResetAnnouncement.verified(TiboConversationSnapshot(focusID: reply.id, conversation: false, posts: [source, reply], ancestorIDs: [source.id])))
        let joke = TiboVisiblePost(id: source.id, text: "Not a real improvement, put the reset in the bag", publishedAt: source.publishedAt)
        XCTAssertNil(TiboResetAnnouncement.verified(TiboConversationSnapshot(focusID: reply.id, conversation: true, posts: [joke, reply], ancestorIDs: [joke.id])))
    }

    func testLiteralResetCutoffPSTPDTAndExpiry() throws {
        let iso = ISO8601DateFormatter()
        let published = try XCTUnwrap(iso.date(from: "2026-10-25T03:40:04Z"))
        let pst = try XCTUnwrap(TiboResetCutoff.parse("By midnight PST", publishedAt: published))
        XCTAssertEqual(pst.deadline, iso.date(from: "2026-10-25T08:00:00Z"))
        XCTAssertEqual(pst.sourceZone, "PST")
        XCTAssertEqual(pst.semantics, .by)
        XCTAssertEqual(pst.chineseHeadline(now: published), "即将重置｜北京时间10月25日16:00前")
        XCTAssertEqual(pst.chineseHeadline(now: pst.deadline), "预计截止时间已过，尚未确认重置")
        let pdt = try XCTUnwrap(TiboResetCutoff.parse("Before midnight PDT", publishedAt: published))
        XCTAssertEqual(pdt.deadline, iso.date(from: "2026-10-25T07:00:00Z"))
        XCTAssertEqual(pdt.semantics, .before)
        XCTAssertEqual(pdt.chineseHeadline(now: published), "即将重置｜北京时间10月25日15:00前")
        XCTAssertNil(TiboResetCutoff.parse("By 2pm PST", publishedAt: published))
        let today = try XCTUnwrap(TiboResetCutoff.parse("By 2pm PST today", publishedAt: published))
        XCTAssertEqual(today.deadline, iso.date(from: "2026-10-24T22:00:00Z"))
        XCTAssertEqual(today.chineseHeadline(now: published), "预计截止时间已过，尚未确认重置")
        let tomorrow = try XCTUnwrap(TiboResetCutoff.parse("Before tomorrow 2:30 PM PST", publishedAt: published))
        XCTAssertEqual(tomorrow.deadline, iso.date(from: "2026-10-25T22:30:00Z"))
        XCTAssertNil(TiboResetCutoff.parse("By midnight PT", publishedAt: published))
        XCTAssertNil(TiboResetCutoff.parse("By midnight", publishedAt: published))
        XCTAssertNil(TiboResetCutoff.parse("By 2 PM PST October 26", publishedAt: published))
        XCTAssertNil(TiboResetCutoff.parse("By 13 PM PST", publishedAt: published))
        XCTAssertNil(TiboResetCutoff.parse("By 2:70 PM PST", publishedAt: published))
    }

    func testOfficialConversationAncestorsExcludeRepliesAfterFocus() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 650), configuration: config)
        let article: (String, String) -> String = { id, text in
            "<article data-testid='tweet'><a href='https://x.com/thsottiaux/status/\(id)'><time datetime='2026-10-25T03:40:04.000Z'></time></a><div data-testid='tweetText'>\(text)</div></article>"
        }
        view.loadHTMLString("<main><section aria-label='Timeline: Conversation'>" + article("2114200152701575656", "Day 20/ Rest and reset") + article("2114200291319124163", "By midnight PST") + article("2114228044072403055", "put the reset in the bag") + "</section></main>", baseURL: nil)
        for _ in 0..<100 {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.querySelectorAll('article').length")) as? Int == 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let script = TiboConversationReader.script.replacingOccurrences(of: "location.hostname", with: "'x.com'").replacingOccurrences(of: "location.pathname", with: "'/thsottiaux/status/2114200291319124163'")
        let value = try await view.evaluateJavaScript(script)
        let json = try XCTUnwrap(value as? String)
        let result = try TiboConversationReader.decode(json)
        XCTAssertTrue(result.conversation)
        XCTAssertEqual(result.ancestorIDs, ["2114200152701575656"])
        XCTAssertEqual(result.focusID, "2114200291319124163")
        XCTAssertEqual(result.posts.count, 3)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        // X may insert the focused reply before its parent in DOM order, then position the parent above it.
        let root = article("2114200152701575656", "Day 20/ Rest and reset").replacingOccurrences(of: "<article ", with: "<article style='position:absolute;top:10px' ")
        let reply = article("2114200291319124163", "By midnight PST").replacingOccurrences(of: "<article ", with: "<article style='position:absolute;top:150px' ")
        let hidden = article("99", "We will reset").replacingOccurrences(of: "<article ", with: "<article style='display:none' ")
        view.loadHTMLString("<main><h1 id='conversation-heading'>Timeline: Conversation</h1><section aria-labelledby='conversation-heading' data-fixture='visual'>" + reply + hidden + root + "</section></main>", baseURL: nil)
        for _ in 0..<100 {
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.querySelector('[data-fixture=visual]')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let visualValue = try await view.evaluateJavaScript(script)
        let visual = try TiboConversationReader.decode(try XCTUnwrap(visualValue as? String))
        XCTAssertTrue(visual.conversation)
        XCTAssertEqual(visual.ancestorIDs, ["2114200152701575656"])
        XCTAssertFalse(visual.posts.contains { $0.id == "99" })
    }

    func testResetHighlightsSurviveNewerRepliesRestartAndDeliveryCursor() async throws {
        let (monitor, notifier, defaults) = makeMonitor()
        let reset = TiboVisiblePost(id: "2114200152701575656", text: "Day 20/ Rest and reset", publishedAt: Date(timeIntervalSince1970: 1792899571))
        let reply = TiboVisiblePost(id: "2114200291319124163", text: "By midnight PST", publishedAt: Date(timeIntervalSince1970: 1792899604))
        defaults.set(reply.id, forKey: "tiboLastNotifiedPostID")
        let restoredCursorMonitor = TiboMonitor(defaults: defaults, notifier: notifier, websiteDataStore: .nonPersistent())
        defer { monitor.stop(); restoredCursorMonitor.stop() }
        await restoredCursorMonitor.enable(openWindow: false)
        await restoredCursorMonitor.receive(page([reset, reply]))
        XCTAssertEqual(restoredCursorMonitor.highlights.reset, reset)
        XCTAssertEqual(restoredCursorMonitor.highlights.latest, reply)
        XCTAssertTrue(notifier.sent.isEmpty, "Displaying cached posts must not replay already-covered notifications")
        XCTAssertTrue(restoredCursorMonitor.highlights.menuSummary.contains("Rest and reset"))
        await restoredCursorMonitor.receive(page([post("2114200291319124164")]))
        XCTAssertEqual(restoredCursorMonitor.highlights.reset, reset, "An unrelated new post must not hide the Reset source")
        let reopened = TiboMonitor(defaults: defaults, notifier: notifier, websiteDataStore: .nonPersistent())
        XCTAssertEqual(reopened.highlights.reset, reset)
        XCTAssertEqual(reopened.highlights.latest?.id, "2114200291319124164")
        var cache = reopened.highlights
        cache.merge([reset, reply])
        XCTAssertEqual(cache.latest?.id, "2114200291319124164", "Older page content cannot regress the cache")
        cache.merge([TiboVisiblePost(id: "2114228044072403055", text: "Not a real improvement, put the reset in the bag", publishedAt: .now)])
        XCTAssertEqual(cache.resets.map(\.id), ["2114228044072403055", reset.id])
        XCTAssertTrue(TiboPostHighlights.mentionsReset("No reset is planned"))
        XCTAssertTrue(TiboPostHighlights.mentionsReset("The reset already happened"))
        XCTAssertTrue(TiboPostHighlights.interpretation.contains("实际额度为准"), "Keyword matching must never assert a future or completed reset")
    }

    func testDiagnosticsRecordLatestFailureWithoutErasingPriorSuccessOrSavingContent() async throws {
        let (monitor, _, defaults) = makeMonitor()
        defer { monitor.stop() }
        await monitor.enable(openWindow: false)
        await monitor.receive(page([post("10")]))
        let success = try XCTUnwrap(monitor.diagnostics.lastSuccessAt)
        await monitor.receive(TiboPageSnapshot(authenticated: false, targetTimeline: true, posts: [], loginRequired: true))
        let json = try XCTUnwrap(defaults.string(forKey: "tiboMonitorDiagnostics"))
        let diagnostic = try JSONDecoder().decode(TiboMonitorDiagnostics.self, from: Data(json.utf8))
        XCTAssertFalse(diagnostic.active)
        XCTAssertEqual(diagnostic.authenticated, false)
        XCTAssertEqual(diagnostic.postCount, 0)
        XCTAssertEqual(diagnostic.lastSuccessAt, success)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(diagnostic.attemptedAt), success)
        XCTAssertEqual(diagnostic.notificationPermission, "authorized")
        XCTAssertNotNil(diagnostic.nextScheduledAt)
        XCTAssertFalse(json.contains("raw message"))
    }

    func testTestNotificationRequiresExistingPermissionAndDoesNotTouchCursor() async {
        let (monitor, notifier, defaults) = makeMonitor()
        defaults.set("10", forKey: "tiboLastNotifiedPostID")
        notifier.allowed = false
        await monitor.sendTestNotification()
        XCTAssertEqual(notifier.testRequests, 0)
        XCTAssertEqual(notifier.authorizationRequests, 0)
        notifier.allowed = true
        await monitor.sendTestNotification()
        XCTAssertEqual(notifier.testRequests, 1)
        XCTAssertEqual(monitor.diagnostics.testAccepted, true)
        XCTAssertEqual(monitor.diagnostics.testDelivered, true)
        XCTAssertEqual(defaults.string(forKey: "tiboLastNotifiedPostID"), "10")
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testDisabledMonitorViewRendersWithoutLoadingX() throws {
        let (monitor, _, _) = makeMonitor()
        XCTAssertEqual(TiboMonitor.safeOrigin(URL(string: "https://x.com/i/flow/login?token=secret")), "https://x.com")
        let host = NSHostingView(rootView: TiboMonitorView(monitor: monitor)
            .frame(width: 820, height: 750, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 750)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/quota-tibo-disabled.png"))
        XCTAssertFalse(monitor.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(monitor.webView.url)
        XCTAssertFalse(monitor.requested)
        XCTAssertFalse(monitor.active)
    }

    func testDefaultOffAndDeniedPermissionNeverActivateOrSetBaseline() async {
        let (monitor, notifier, defaults) = makeMonitor()
        await monitor.restoreIfEnabled()
        XCTAssertFalse(monitor.requested)
        XCTAssertEqual(notifier.authorizationRequests, 0)
        notifier.allowed = false
        await monitor.enable(openWindow: false)
        await monitor.receive(page([post("2103637477760311522")]))
        XCTAssertFalse(monitor.active)
        XCTAssertFalse(monitor.requested)
        XCTAssertNil(defaults.string(forKey: "tiboLastNotifiedPostID"))
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testFirstBaselineSilentThenNewPostsExactlyOnceInChronologicalOrder() async {
        let (monitor, notifier, defaults) = makeMonitor()
        defer { monitor.stop() }
        await monitor.enable(openWindow: false)
        await monitor.receive(page([post("2103637477760311522"), post("2103637477760311521")]))
        XCTAssertTrue(monitor.active)
        XCTAssertTrue(notifier.sent.isEmpty)
        await monitor.receive(page([post("2103637477760311524"), post("2103637477760311523"), post("2103637477760311523"), post("2103637477760311522")]))
        XCTAssertEqual(notifier.sent.map(\.id), ["2103637477760311523", "2103637477760311524"])
        await monitor.receive(page([post("2103637477760311524")]))
        XCTAssertEqual(notifier.sent.count, 2)
        XCTAssertEqual(defaults.string(forKey: "tiboLastNotifiedPostID"), "2103637477760311524")
    }

    func testEmptyLoadingAndLostLoginNeverAdvanceCursorOrNotify() async {
        let (monitor, notifier, defaults) = makeMonitor()
        defer { monitor.stop() }
        await monitor.enable(openWindow: false)
        await monitor.receive(page([]))
        XCTAssertNil(defaults.string(forKey: "tiboLastNotifiedPostID"))
        await monitor.receive(page([post("2103637477760311522")]))
        await monitor.receive(TiboPageSnapshot(authenticated: false, targetTimeline: true, posts: [post("2103637477760311523")]))
        XCTAssertFalse(monitor.active)
        XCTAssertTrue(notifier.sent.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "tiboLastNotifiedPostID"), "2103637477760311522")
        notifier.allowed = false
        await monitor.receive(page([post("2103637477760311523")]))
        XCTAssertFalse(monitor.active)
        XCTAssertTrue(notifier.sent.isEmpty)
        let permissionFailure = monitor.status
        monitor.completePageRetries()
        XCTAssertEqual(monitor.status, permissionFailure)
    }

    func testDeliveryFailureRetriesWithoutSkippingAndStopBlocksLateResults() async {
        let (monitor, notifier, defaults) = makeMonitor()
        await monitor.enable(openWindow: false)
        await monitor.receive(page([post("10")]))
        notifier.fail = true
        await monitor.receive(page([post("11")]))
        XCTAssertEqual(defaults.string(forKey: "tiboLastNotifiedPostID"), "10")
        XCTAssertFalse(monitor.active)
        let deliveryFailure = monitor.status
        monitor.completePageRetries()
        XCTAssertEqual(monitor.status, deliveryFailure)
        notifier.fail = false
        await monitor.receive(page([post("11")]))
        XCTAssertEqual(notifier.sent.map(\.id), ["11"])
        monitor.stop()
        await monitor.receive(page([post("12")]))
        XCTAssertEqual(notifier.sent.count, 1)
        XCTAssertFalse(defaults.bool(forKey: "tiboMonitorEnabled"))
    }

    func testCursorSurvivesRestartAndRejectsInvalidAndFuturePosts() {
        var cursor = TiboPostCursor(latestID: "999999999999999999")
        let now = Date()
        let future = TiboVisiblePost(id: "1000000000000000001", text: "later", publishedAt: now.addingTimeInterval(1000))
        let candidates = [post("1000000000000000000"), post("bad"), future]
        XCTAssertEqual(cursor.unseen(candidates, now: now).map(\.id), ["1000000000000000000"])
        cursor.acknowledge(candidates[0])
        XCTAssertEqual(cursor.latestID, "1000000000000000000")
        XCTAssertTrue(cursor.unseen(candidates, now: now).isEmpty)
    }

    func testLogoutCanReopenAndStoppedAuthorizationCannotReactivate() async {
        XCTAssertTrue(TiboMonitor.needsInitialPageLoad(nil))
        XCTAssertTrue(TiboMonitor.needsInitialPageLoad(URL(string: "about:blank")))
        XCTAssertFalse(TiboMonitor.needsInitialPageLoad(URL(string: "https://x.com/i/flow/login")))
        let (monitor, notifier, defaults) = makeMonitor()
        notifier.delay = true
        let pending = Task { await monitor.enable(openWindow: false) }
        await Task.yield()
        monitor.stop()
        await pending.value
        XCTAssertFalse(monitor.requested)
        notifier.delay = false
        await monitor.enable(openWindow: false)
        await monitor.logout()
        XCTAssertFalse(monitor.requested)
        XCTAssertFalse(monitor.active)
        XCTAssertFalse(monitor.clearingSession)
        XCTAssertFalse(defaults.bool(forKey: "tiboMonitorEnabled"))
        await monitor.enable(openWindow: false)
        XCTAssertTrue(monitor.requested)
        monitor.stop()
    }

    func testConcurrentEnableHasOneLifecycleAndStopsCleanly() async {
        let (monitor, notifier, _) = makeMonitor()
        notifier.delay = true
        async let first: Void = monitor.enable(openWindow: false)
        async let second: Void = monitor.enable(openWindow: false)
        _ = await (first, second)
        XCTAssertTrue(monitor.requested)
        monitor.stop()
        await monitor.receive(page([post("99")]))
        XCTAssertFalse(monitor.active)
    }

    func testDOMExtractionFiltersOtherAuthorsPinnedQuotesAndPreservesExactIDs() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let html = #"""
        <html><body><button data-testid="SideNav_AccountSwitcher_Button">account</button>
        <article data-testid="tweet"><a href="https://x.com/thsottiaux/status/2103637477760311522"><time datetime="2026-10-23T12:00:00.000Z"></time></a><div data-testid="tweetText">A reset announcement, not confirmation.</div></article>
        <article data-testid="tweet"><span data-testid="socialContext">Pinned</span><a href="https://x.com/thsottiaux/status/2103637477760311520"><time datetime="2026-09-23T12:00:00Z"></time></a><div data-testid="tweetText">old pinned</div></article>
        <article data-testid="tweet"><a href="https://x.com/another/status/2103637477760311525"><time datetime="2026-10-23T12:00:00Z"></time></a><div data-testid="tweetText">recommendation</div><a href="https://x.com/thsottiaux/status/2103637477760311524"><time datetime="2026-10-23T12:00:00Z"></time></a></article>
        </body></html>
        """#
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0..<100 {
            if !webView.isLoading, (try? await webView.evaluateJavaScript("document.querySelectorAll('article').length")) as? Int == 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Supply a synthetic target origin for the local fixture; never load or authenticate with X.
        let script = TiboPageReader.script
            .replacingOccurrences(of: "location.hostname", with: "'x.com'")
            .replacingOccurrences(of: "location.pathname", with: "'/thsottiaux/with_replies'")
        let result = try await webView.evaluateJavaScript(script)
        let json = try XCTUnwrap(result as? String)
        let snapshot = try TiboPageReader.decode(json)
        XCTAssertTrue(snapshot.authenticated)
        XCTAssertTrue(snapshot.targetTimeline)
        XCTAssertEqual(snapshot.posts.map(\.id), ["2103637477760311522"])
        XCTAssertEqual(snapshot.posts.first?.text, "A reset announcement, not confirmation.")
        XCTAssertEqual(snapshot.posts.first?.url.absoluteString, "https://x.com/thsottiaux/status/2103637477760311522")
        _ = try await webView.evaluateJavaScript("document.querySelector('button').remove()")
        let logoutResult = try await webView.evaluateJavaScript(script)
        let loggedOut = try TiboPageReader.decode(try XCTUnwrap(logoutResult as? String))
        XCTAssertFalse(loggedOut.authenticated)
        XCTAssertTrue(loggedOut.posts.isEmpty)
    }

    func testResponsiveMemberNavigationAndProfileNavigationConfirmLogin() async throws {
        let article = "<article data-testid='tweet'><a href='https://x.com/thsottiaux/status/2113771215433392478'><time datetime='2026-10-24T00:00:00Z'></time></a><div data-testid='tweetText'>Visible original</div></article>"
        let compact = try await readFixture("<nav><a data-testid='AppTabBar_Home_Link' href='/home'>Home</a><a data-testid='AppTabBar_Notifications_Link' href='/notifications'>Notifications</a></nav>" + article)
        XCTAssertTrue(compact.authenticated)
        XCTAssertEqual(compact.posts.count, 1)
        let profile = try await readFixture("<nav><a data-testid='AppTabBar_Profile_Link' href='/myprofile'>Profile</a></nav>" + article)
        XCTAssertTrue(profile.authenticated)
        XCTAssertEqual(profile.posts.count, 1)
        let guest = try await readFixture(article)
        XCTAssertFalse(guest.authenticated)
        XCTAssertTrue(guest.posts.isEmpty)
        XCTAssertFalse(guest.loginRequired ?? true)
        let signIn = try await readFixture("<a data-testid='loginButton' href='/i/flow/login'>Sign in</a>" + article)
        XCTAssertFalse(signIn.authenticated)
        XCTAssertTrue(signIn.loginRequired ?? false)
        let otherOrigin = try await readFixture("<button data-testid='SideNav_AccountSwitcher_Button'>Account</button>" + article, host: "example.com")
        XCTAssertFalse(otherOrigin.authenticated)
        XCTAssertTrue(otherOrigin.posts.isEmpty)
    }

    func testLoggedInTimelineLoadingRecoversWithoutReloginOrWritingEmptyBaseline() async {
        let (monitor, notifier, defaults) = makeMonitor()
        defer { monitor.stop() }
        await monitor.enable(openWindow: false)
        await monitor.receive(page([]))
        let waiting = monitor.status
        XCTAssertFalse(monitor.active)
        XCTAssertNil(defaults.string(forKey: "tiboLastNotifiedPostID"))
        await monitor.receive(TiboPageSnapshot(authenticated: false, targetTimeline: true, posts: []))
        let unknown = monitor.status
        XCTAssertNotEqual(waiting, unknown)
        await monitor.receive(TiboPageSnapshot(authenticated: false, targetTimeline: true, posts: [], loginRequired: true))
        XCTAssertNotEqual(monitor.status, unknown)
        await monitor.receive(page([post("2113771215433392478")]))
        XCTAssertTrue(monitor.active)
        XCTAssertTrue(notifier.sent.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "tiboLastNotifiedPostID"), "2113771215433392478")
    }

    private func readFixture(_ body: String, host: String = "x.com") async throws -> TiboPageSnapshot {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 700), configuration: config)
        webView.loadHTMLString("<html><body><main id='fixture-root'>" + body + "</main></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if !webView.isLoading, (try? await webView.evaluateJavaScript("!!document.getElementById('fixture-root')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let script = TiboPageReader.script
            .replacingOccurrences(of: "location.hostname", with: "'\(host)'")
            .replacingOccurrences(of: "location.pathname", with: "'/thsottiaux/with_replies'")
        let result = try await webView.evaluateJavaScript(script)
        return try TiboPageReader.decode(try XCTUnwrap(result as? String))
    }

    private func makeMonitor() -> (TiboMonitor, TestTiboNotifications, UserDefaults) {
        let defaults = UserDefaults(suiteName: "TiboTests.\(UUID().uuidString)")!
        let notifier = TestTiboNotifications()
        return (TiboMonitor(defaults: defaults, notifier: notifier, websiteDataStore: .nonPersistent()), notifier, defaults)
    }
    private func post(_ id: String) -> TiboVisiblePost { TiboVisiblePost(id: id, text: "raw message", publishedAt: Date(timeIntervalSince1970: 1_792_728_000)) }
    private func page(_ posts: [TiboVisiblePost]) -> TiboPageSnapshot { TiboPageSnapshot(authenticated: true, targetTimeline: true, posts: posts) }
}

@MainActor
private final class TestTiboNotifications: TiboNotificationSending {
    var allowed = true
    var fail = false
    var delay = false
    var authorizationRequests = 0
    var sent: [TiboVisiblePost] = []
    var summaries: [String] = []
    func send(_ post: TiboVisiblePost, summary: String) async throws {
        summaries.append(summary)
        try await send(post)
    }
    var testRequests = 0
    func sendTest() async throws -> Bool { testRequests += 1; return true }
    func authorize() async -> Bool {
        authorizationRequests += 1
        if delay { try? await Task.sleep(nanoseconds: 30_000_000) }
        return allowed
    }
    func isAuthorized() async -> Bool { allowed }
    func send(_ post: TiboVisiblePost) async throws {
        if fail { throw NSError(domain: "test", code: 1) }
        sent.append(post)
    }
}

/// In-memory documents only: tests never contact X or Google's sign-in servers.
@MainActor
private final class LoginFixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    var received: [URL] = []
    var failNext = false
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        received.append(url)
        if failNext {
            failNext = false
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
            return
        }
        let data = Data("<html><body><p>Local login fixture</p></body></html>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
