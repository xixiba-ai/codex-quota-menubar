import Foundation
#if !CODEX_RESET_CLI_TEST
import XCTest
@testable import Codex_Quota
final class CodexResetMonitorTests: XCTestCase {
    @MainActor
    func testPublicTimelineAndMonitor() async throws { XCTAssertGreaterThan(try await CodexResetChecks.run(), 40) }
}
#endif

@MainActor
final class CodexResetFakeClient: CodexResetFetching {
    var replies: [CodexResetHTTPResponse] = []
    var calls = 0
    var delay: Duration = .zero
    var fails = false
    var locales: [String] = []
    func fetch(locale: String) async throws -> CodexResetHTTPResponse {
        calls += 1; locales.append(locale)
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw URLError(.notConnectedToInternet) }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}
@MainActor
final class CodexResetFakeNotifications: CodexResetNotificationSending {
    var delivered: [String] = []
    var permissionValue = "authorized"
    var authorizeCalls = 0
    var fails = false
    func permission() async -> String { permissionValue }
    func authorize() async -> Bool { authorizeCalls += 1; return true }
    func send(_ event: CodexResetEvent) async throws {
        if fails { throw URLError(.unknown) }
        delivered.append(event.id)
    }
    func sendTest() async throws {}
}

@MainActor
enum CodexResetChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(description: message) }; checks += 1
        }
        let now = Date.now
        let iso = ISO8601DateFormatter()
        func row(_ id: String, seconds: Double, state: String? = "announced", group: String = "reset", banked: String? = nil) -> [String: Any] {
            var r: [String: Any] = ["id": id, "announced_at": iso.string(from: now.addingTimeInterval(seconds)), "group": group,
                                  "type": group, "summary": "Public synthetic event", "url": "https://x.com/codex_reset/status/12345"]
            if let state { r["announcement_state"] = state }
            if let banked { r["banked_state"] = banked; r["reset_kind"] = "banked" }
            return r
        }
        func response(_ rows: [[String: Any]], at date: Date? = nil, status: Int = 200,
                      headers: [String: String] = [:]) throws -> CodexResetHTTPResponse {
            CodexResetHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["updated_at": iso.string(from: date ?? now), "events": rows]), status: status, headers: headers)
        }
        func parsed(_ rows: [[String: Any]]) throws -> [CodexResetEvent] { try CodexResetTimeline.parse(response(rows).data, now: now).events }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-reset-timeline-20261109.json")
        let real = try CodexResetTimeline.parse(Data(contentsOf: fixture), now: max(now, Date(timeIntervalSince1970: 1794210000)))
        try expect(real.events.count == 73, "real API fixture all 73 entries parsed")
        try expect(real.events[0].kind == .availableCredit, "latest real entry is banked credit, not global reset")
        try expect(real.events[0].safeURL == CodexResetEvent.timelineURL, "null source falls back to timeline")
        try expect(real.events[2].kind == .confirmedReset, "announced reset classified")
        try expect(real.events[3].kind == .unconfirmed, "none not confirmation despite free-form flags")
        try expect(real.events.filter { $0.kind == .confirmedReset }.count == 17, "only explicit announced states confirm")
        try expect(real.events.filter { $0.group == "reset" && $0.announcementState == nil }.allSatisfy { !$0.isNotifiable }, "missing announcement state never notifies")
        for bad in [Data("{}".utf8), Data("{\"events\":null}".utf8), Data("not JSON".utf8), try response([["id": "bad"]]).data] {
            do { _ = try CodexResetTimeline.parse(bad, now: now); throw Failure(description: "invalid payload accepted") }
            catch is CodexResetParsingError { checks += 1 }
        }
        try expect(try CodexResetTimeline.parse(response([]).data, now: now).events.isEmpty, "valid empty timeline")
        let credit = try parsed([row("credit", seconds: -100, state: nil, group: "credits", banked: "available")])[0]
        let arriving = try parsed([row("arriving", seconds: -100, state: nil, group: "credits", banked: "arriving")])[0]
        try expect(credit.kind == .availableCredit && credit.isNotifiable, "available banked credit separate category")
        try expect(arriving.kind == .creditUpdate && !arriving.isNotifiable, "arriving is not available credit")
        let tease = try parsed([row("tease", seconds: -100, state: "none")])[0]
        try expect(!tease.isNotifiable, "tease never confirms")
        for url in ["http://x.com/codex_reset/status/12", "https://evil.com/a", "https://x.com/evil/status/12", "https://codex-reset.com.evil.com/timeline", "https://user:pass@codex-reset.com/timeline", "https://x.com/codex_reset/status/12/extra", "javascript:alert(1)"] {
            try expect(CodexResetEvent.safeURL(url) == CodexResetEvent.timelineURL, "unsafe source URL fallback")
        }
        try expect(CodexResetEvent.safeURL("https://x.com/thsottiaux/status/123") != CodexResetEvent.timelineURL, "known original source allowed")
        var ledger = CodexResetLedger()
        try expect(ledger.ingest([]).isEmpty && !ledger.established, "empty first success cannot establish an unbounded historical baseline")
        let old = try parsed([row("old", seconds: -120), row("tease", seconds: -100, state: "none")])
        try expect(ledger.ingest(old).isEmpty && ledger.established, "first nonempty response silently baselines")
        try expect(ledger.ingest(Array(old.reversed())).isEmpty, "reordered duplicate baseline silent")
        let fresh = try parsed([row("new", seconds: -10), row("old-backfill", seconds: -400)])
        try expect(ledger.ingest(fresh).map(\.id) == ["new"], "new confirmation notifies; old unseen backfill does not")
        let transition = try parsed([row("tease", seconds: -100, state: "announced")])
        try expect(ledger.ingest(transition).map(\.id) == ["tease"], "known unconfirmed to announced transition notifies")
        try expect(ledger.ingest(try parsed([row("tease", seconds: -100, state: "none")])).isEmpty, "retraction never notifies")
        try expect(ledger.ingest(transition).isEmpty, "reannouncing already observed confirmation does not repeat")
        var restoredLedger = try JSONDecoder().decode(CodexResetLedger.self, from: JSONEncoder().encode(ledger))
        try expect(restoredLedger.ingest(fresh).isEmpty, "deduplication survives restart")
        let retry = CodexResetHTTPResponse(data: Data(), status: 429, headers: ["Retry-After": "120"])
        try expect(retry.nextAllowed(at: now).timeIntervalSince(now) == 120, "numeric Retry-After")
        let httpDate = DateFormatter(); httpDate.locale = Locale(identifier: "en_US_POSIX"); httpDate.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"; httpDate.timeZone = TimeZone(secondsFromGMT: 0)
        let retryDate = CodexResetHTTPResponse(data: Data(), status: 429, headers: ["retry-after": httpDate.string(from: now.addingTimeInterval(180))])
        try expect(retryDate.nextAllowed(at: now).timeIntervalSince(now) >= 179, "HTTP date Retry-After")
        let cached = CodexResetHTTPResponse(data: Data(), status: 200, headers: ["Cache-Control": "public, max-age=300", "Age": "30"])
        try expect(cached.nextAllowed(at: now).timeIntervalSince(now) == 270, "cache max-age minus age")
        var suites: [String] = []
        func defaults() -> UserDefaults {
            let name = "CodexResetChecks.\(UUID().uuidString)"; suites.append(name); return UserDefaults(suiteName: name)!
        }
        defer { suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) } }
        let d = defaults(); d.set(true, forKey: "tiboMonitorEnabled"); d.set(Data("old tweet cache".utf8), forKey: "tiboPostHighlights")
        let client = CodexResetFakeClient(); let notifications = CodexResetFakeNotifications()
        client.replies = [try response([row("first", seconds: -100)]), try response([row("second", seconds: -1),row("first",seconds: -100)], at: now.addingTimeInterval(61))]
        let monitor = CodexResetMonitor(defaults: d, client: client, notifications: notifications, schedulesAutomatically: false)
        try expect(monitor.isEnabled && monitor.events.isEmpty && !monitor.saved.ledger.established, "migrate enabled only, never old cache/cursor")
        await monitor.checkNow(at: now)?.value
        try expect(client.calls == 1 && notifications.delivered.isEmpty, "monitor first baseline silent")
        try expect(notifications.authorizeCalls == 0, "reading/migration never requests new system authorization")
        try expect(monitor.checkNow(at: now.addingTimeInterval(30)) == nil, "manual refresh honors one-minute throttle")
        await monitor.checkNow(at: now.addingTimeInterval(61))?.value
        try expect(notifications.delivered == ["second"], "monitor delivers new confirmed event")
        let beforeFailure = monitor.events
        client.fails = true
        await monitor.checkNow(at: now.addingTimeInterval(122))?.value
        try expect(monitor.failure != nil && monitor.events == beforeFailure && monitor.saved.lastSuccessAt != nil, "failure retains cache and previous success")
        monitor.setEnabled(false)
        try expect(!monitor.isChecking && monitor.checkNow(at: now.addingTimeInterval(200)) == nil, "disabled never fetches")
        d.set(true, forKey: "tiboMonitorEnabled")
        let restart = CodexResetMonitor(defaults: d, client: client, notifications: notifications, schedulesAutomatically: false)
        try expect(!restart.isEnabled && restart.events == beforeFailure, "one-time migration does not re-enable user's new disabled preference")
        let cancellationDefaults = defaults(); cancellationDefaults.set(true, forKey: CodexResetMonitor.enabledKey)
        let slow = CodexResetFakeClient();slow.delay = .milliseconds(250);slow.replies = [try response([row("cancel", seconds: -1)])]
        let cancelled = CodexResetMonitor(defaults: cancellationDefaults, client: slow, notifications: notifications, schedulesAutomatically: false)
        let pending = cancelled.checkNow(at: now)
        await Task.yield();cancelled.setEnabled(false);await pending?.value
        try expect(cancelled.saved.lastSuccessAt == nil && cancelled.events.isEmpty && !cancelled.isChecking, "cancelled disabled request cannot publish cache or notifications")
        let rateDefaults = defaults();rateDefaults.set(true, forKey: CodexResetMonitor.enabledKey)
        let rateClient = CodexResetFakeClient();rateClient.delay = .milliseconds(40);rateClient.replies = [CodexResetHTTPResponse(data: Data(), status: 429, headers: ["Retry-After":"90"])]
        let rateMonitor = CodexResetMonitor(defaults: rateDefaults,client: rateClient,notifications: notifications,schedulesAutomatically:false)
        await rateMonitor.checkNow(at:now)?.value
        try expect(rateMonitor.failure == "429" && rateMonitor.saved.nextAllowedAt.timeIntervalSince(now) >= 90.035, "Retry-After starts at response receipt, including network elapsed time")
        try expect(rateMonitor.checkNow(at: now.addingTimeInterval(70)) == nil && rateClient.calls == 1, "429 manual retry blocked")
        let staleDefaults = defaults();staleDefaults.set(true, forKey: CodexResetMonitor.enabledKey)
        let staleClient = CodexResetFakeClient();staleClient.replies = [try response([row("stale",seconds:-1000)],at: now.addingTimeInterval(-1000)),try response([row("stale",seconds:-1000)],at:now.addingTimeInterval(61))]
        let staleMonitor = CodexResetMonitor(defaults:staleDefaults,client:staleClient,notifications:notifications,schedulesAutomatically:false)
        await staleMonitor.checkNow(at:now)?.value
        try expect(staleMonitor.isStale(at:now) && !staleMonitor.saved.ledger.established, "old updated_at without expires is stale and cannot advance baseline")
        await staleMonitor.checkNow(at:now.addingTimeInterval(61))?.value
        try expect(!staleMonitor.isStale(at:now.addingTimeInterval(61)) && staleMonitor.saved.ledger.established, "first fresh publication establishes silent baseline")
        let latestCount = notifications.delivered.count
        staleClient.replies = [try response([row("stale",seconds:-1000),row("wait-for-fresh",seconds:65)],at:now.addingTimeInterval(122),headers:["x-published-expires-at":iso.string(from:now.addingTimeInterval(100))]), try response([row("stale",seconds:-1000),row("wait-for-fresh",seconds:65)],at:now.addingTimeInterval(183))]
        await staleMonitor.checkNow(at:now.addingTimeInterval(122))?.value
        try expect(!staleMonitor.saved.ledger.records.keys.contains("wait-for-fresh"), "expired payload cannot prematurely acknowledge an unsent event")
        await staleMonitor.checkNow(at:now.addingTimeInterval(183))?.value
        try expect(notifications.delivered.count == latestCount + 1 && notifications.delivered.last == "wait-for-fresh", "fresh copy delivers event previously withheld by stale source")
        let coldDefaults = defaults();let coldClient = CodexResetFakeClient();let cold = CodexResetMonitor(defaults:coldDefaults,client:coldClient,notifications:notifications,schedulesAutomatically:false)
        cold.startIfEnabled();await Task.yield();try expect(coldClient.calls == 0 && !cold.isEnabled, "fresh disabled install has no requests")
        [monitor,restart,cancelled,rateMonitor,staleMonitor,cold].forEach { $0.shutdown() }
        return checks
    }
}
#if CODEX_RESET_CLI_TEST
@main
struct CodexResetCheckRunner {
    @MainActor
    static func main() async throws { print("PASS: \(try await CodexResetChecks.run()) Codex Reset checks") }
}
#endif
