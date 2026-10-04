import Foundation
import XCTest
@testable import Codex_Quota

@MainActor
final class QuotaFreshnessTests: XCTestCase {
    func testQuotaReadPreservesAccountAndUsagePermissionForRecoveryDetection() throws {
        let result: [String: Any] = [
            "accountId": "test-account",
            "ordinaryUsageAllowed": false,
            "rateLimits": ["primary": ["usedPercent": 0, "resetsAt": 2_000_000_000, "windowDurationMins": 300]]
        ]
        let snapshot = try CodexAppServerUsageDataSource().makeSnapshot(from: result)
        XCTAssertEqual(snapshot.accountID, "test-account")
        XCTAssertEqual(snapshot.ordinaryUsageAllowed, false)
        XCTAssertEqual(snapshot.shortTerm.remainingPercent, 100)
    }

    func testResetCreditsParsesCompleteAvailableDetails() throws {
        let snapshot = try resetCreditsSnapshot([
            "availableCount": 2,
            "credits": [
                ["id": "first", "resetType": "codexRateLimits", "status": "available", "expiresAt": 2_000_000_100],
                ["id": "second", "resetType": "codexRateLimits", "status": "available", "expiresAt": 2_000_000_200]
            ]
        ])
        let summary = try XCTUnwrap(snapshot.rateLimitResetCredits)
        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertEqual(summary.earliestKnownExpiration, Date(timeIntervalSince1970: 2_000_000_100))
        XCTAssertTrue(summary.hasCompleteDetails)
    }

    func testResetCreditsMissingNullAndInvalidDoNotBreakQuota() throws {
        let values: [Any?] = [nil, NSNull(), ["availableCount": "bad"]]
        for value in values {
            let snapshot = try resetCreditsSnapshot(value)
            XCTAssertEqual(snapshot.shortTerm.remainingPercent, 70)
            XCTAssertNil(snapshot.rateLimitResetCredits)
        }
    }

    func testResetCreditsZeroAndNullDetails() throws {
        let zero = try XCTUnwrap(resetCreditsSnapshot(["availableCount": 0, "credits": []]).rateLimitResetCredits)
        XCTAssertEqual(zero.availableCount, 0)
        XCTAssertTrue(zero.hasCompleteDetails)
        XCTAssertNil(zero.earliestKnownExpiration)

        let countOnly = try XCTUnwrap(resetCreditsSnapshot(["availableCount": 3, "credits": NSNull()]).rateLimitResetCredits)
        XCTAssertEqual(countOnly.availableCount, 3)
        XCTAssertNil(countOnly.credits)
        XCTAssertFalse(countOnly.hasCompleteDetails)
    }

    func testResetCreditsPartialDetailsAndRedeemedRows() throws {
        let summary = try XCTUnwrap(resetCreditsSnapshot([
            "availableCount": 3,
            "credits": [
                ["id": "available", "resetType": "codexRateLimits", "status": "available", "expiresAt": 2_000_000_200],
                ["id": "redeemed", "resetType": "codexRateLimits", "status": "redeemed", "expiresAt": 2_000_000_100],
                ["id": "invalid", "resetType": "codexRateLimits", "status": "available", "expiresAt": "bad"]
            ]
        ]).rateLimitResetCredits)
        XCTAssertEqual(summary.availableCount, 3)
        XCTAssertEqual(summary.credits?.count, 2)
        XCTAssertEqual(summary.earliestKnownExpiration, Date(timeIntervalSince1970: 2_000_000_200))
        XCTAssertFalse(summary.hasCompleteDetails)
    }

    func testResetCreditsCompleteWithoutExpiration() throws {
        let summary = try XCTUnwrap(resetCreditsSnapshot([
            "availableCount": 1,
            "credits": [["id": "permanent", "resetType": "codexRateLimits", "status": "available", "expiresAt": NSNull()]]
        ]).rateLimitResetCredits)
        XCTAssertTrue(summary.hasCompleteDetails)
        XCTAssertNil(summary.earliestKnownExpiration)
    }

    func testLegacyRemotePayloadWithoutResetCreditsStillDecodes() throws {
        let data = #"{"shortTerm":{"remainingPercent":65,"resetsAt":"2033-05-18T03:33:20Z","windowDurationMinutes":300},"longTerm":null,"updatedAt":"2033-05-18T03:33:20Z"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RemoteUsagePayload.self, from: data)
        XCTAssertEqual(payload.shortTerm.remainingPercent, 65)
        XCTAssertNil(payload.longTerm)
    }

    func testLegacySnapshotWithoutResetCreditsStillDecodes() throws {
        let data = #"{"shortTerm":{"remainingPercent":65,"resetsAt":"2033-05-18T03:33:20Z","windowDurationMinutes":300},"longTerm":null,"updatedAt":"2033-05-18T03:33:20Z","sourceDescription":"Configured data source"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CodexUsageSnapshot.self, from: data)
        XCTAssertEqual(snapshot.shortTerm.remainingPercent, 65)
        XCTAssertNil(snapshot.rateLimitResetCredits)
        XCTAssertNil(snapshot.accountID)
        XCTAssertNil(snapshot.ordinaryUsageAllowed)
    }

    private func resetCreditsSnapshot(_ value: Any?) throws -> CodexUsageSnapshot {
        var result: [String: Any] = ["rateLimits": ["primary": [
            "usedPercent": 30, "resetsAt": 2_000_000_000, "windowDurationMins": 300
        ]]]
        if let value { result["rateLimitResetCredits"] = value }
        return try CodexAppServerUsageDataSource().makeSnapshot(from: result)
    }

    func testAppServerAcceptsMatchingRateLimitResponse() async throws {
        let fake = try FakeQuotaCLI(script: #"""
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":1,"result":{}}\n' ;;
            *rateLimits*)
              printf '{"id":99,"error":{"message":"unrelated"}}\n'
              printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":30,"resetsAt":2000000000,"windowDurationMins":300}}}}\n'
              ;;
          esac
        done
        """#)
        defer { fake.remove() }
        let source = CodexAppServerUsageDataSource(executableURL: fake.url, requestTimeout: .seconds(2))
        defer { source.stop() }

        let snapshot = try await source.fetchUsage()
        XCTAssertEqual(snapshot.shortTerm.remainingPercent, 70)
    }

    func testAppServerInitializationErrorFailsPromptly() async throws {
        let fake = try FakeQuotaCLI(script: #"""
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":1,"error":{"message":"rejected"}}\n' ;;
          esac
        done
        """#)
        defer { fake.remove() }
        let source = CodexAppServerUsageDataSource(executableURL: fake.url, requestTimeout: .seconds(2))
        defer { source.stop() }

        do {
            _ = try await source.fetchUsage()
            XCTFail("An initialize error must fail the refresh")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.tr("Codex CLI 拒绝了额度请求"))
        }
    }

    func testAppServerInitializationTimeoutAllowsRetry() async throws {
        let fake = try FakeQuotaCLI(script: #"""
        if [ -e "__MARKER__" ]; then
          retry=1
        else
          : > "__MARKER__"
          retry=0
        fi
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              if [ "$retry" -eq 1 ]; then printf '{"id":2,"result":{}}\n'; fi
              ;;
            *rateLimits*)
              printf '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":40,"resetsAt":2000000000}}}}\n'
              ;;
          esac
        done
        """#)
        defer { fake.remove() }
        let source = CodexAppServerUsageDataSource(executableURL: fake.url, requestTimeout: .seconds(2))
        defer { source.stop() }

        do {
            _ = try await source.fetchUsage()
            XCTFail("Initialization should time out")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.tr("Codex CLI 响应超时，请重试"))
        }
        let snapshot = try await source.fetchUsage()
        XCTAssertEqual(snapshot.shortTerm.remainingPercent, 60)
    }

    func testAppServerTimeoutClearsRefreshAndAllowsRetry() async throws {
        let fake = try FakeQuotaCLI(script: #"""
        if [ -e "__MARKER__" ]; then
          retry=1
        else
          : > "__MARKER__"
          retry=0
        fi
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              if [ "$retry" -eq 1 ]; then
                printf '{"id":3,"result":{}}\n'
              else
                printf '{"id":1,"result":{}}\n'
              fi
              ;;
            *rateLimits*)
              if [ "$retry" -eq 1 ]; then
                printf '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":20,"resetsAt":2000000000}}}}\n'
              fi
              ;;
          esac
        done
        """#)
        defer { fake.remove() }
        let source = CodexAppServerUsageDataSource(executableURL: fake.url, requestTimeout: .seconds(2))
        let store = QuotaStore(dataSource: source)
        defer { source.stop() }

        await store.refresh()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.errorMessage)
        await store.refresh()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.snapshot?.shortTerm.remainingPercent, 80)
        XCTAssertNil(store.errorMessage)
    }

    func testSuccessfulReadFailureAndRecoveryTrackFreshness() async {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let recoveredDate = firstDate.addingTimeInterval(240)
        let source = SequencedQuotaSource(outcomes: [
            .success(snapshot(at: firstDate)),
            .failure(TestQuotaError.failed),
            .success(snapshot(at: recoveredDate))
        ])
        let store = QuotaStore(dataSource: source)

        XCTAssertEqual(store.freshness(at: firstDate), .loading)
        await store.refresh()
        XCTAssertEqual(store.freshness(at: firstDate.addingTimeInterval(180)), .current)
        XCTAssertEqual(store.freshness(at: firstDate.addingTimeInterval(181)), .stale)

        await store.refresh()
        XCTAssertEqual(store.snapshot?.updatedAt, firstDate)
        XCTAssertEqual(store.freshness(at: firstDate.addingTimeInterval(20)), .stale)
        XCTAssertNotNil(store.errorMessage)

        await store.refresh()
        XCTAssertEqual(store.snapshot?.updatedAt, recoveredDate)
        XCTAssertEqual(store.freshness(at: recoveredDate), .current)
        XCTAssertNil(store.errorMessage)
    }

    func testFailureWithoutSnapshotIsUnavailableAndLiveUpdateClearsError() async {
        let source = LiveQuotaSource()
        let store = QuotaStore(dataSource: source)
        await store.start()
        defer { store.stop() }

        XCTAssertEqual(store.freshness(), .unavailable)
        XCTAssertNotNil(store.errorMessage)
        let current = snapshot(at: .now)
        source.emit(current)
        XCTAssertEqual(store.freshness(at: current.updatedAt), .current)
        XCTAssertNil(store.errorMessage)
    }

    func testRetainedSnapshotStaysStaleWhileRetryIsInFlight() async {
        let started = expectation(description: "retry entered data source")
        let date = Date(timeIntervalSince1970: 1_000)
        let source = SuspendedRetryQuotaSource(snapshot: snapshot(at: date))
        source.onRetry = { started.fulfill() }
        let store = QuotaStore(dataSource: source)
        await store.refresh()
        await store.refresh()
        let retry = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)

        XCTAssertEqual(store.freshness(at: date.addingTimeInterval(1)), .stale)
        source.completeRetry(with: snapshot(at: date.addingTimeInterval(2)))
        await retry.value
        XCTAssertEqual(store.freshness(at: date.addingTimeInterval(2)), .current)
    }

    private func snapshot(at date: Date) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            shortTerm: UsageWindow(remainingPercent: 60, resetsAt: date.addingTimeInterval(3_600), windowDurationMinutes: 300),
            longTerm: nil,
            updatedAt: date,
            sourceDescription: "Test"
        )
    }
}

private final class FakeQuotaCLI {
    let url: URL
    private let directory: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("fake-codex")
        let text = "#!/bin/sh\n" + script.replacingOccurrences(of: "__MARKER__", with: directory.appendingPathComponent("started").path) + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private enum TestQuotaError: Error { case failed }

@MainActor
private final class SequencedQuotaSource: UsageDataSource {
    private var outcomes: [Result<CodexUsageSnapshot, Error>]

    init(outcomes: [Result<CodexUsageSnapshot, Error>]) { self.outcomes = outcomes }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        try outcomes.removeFirst().get()
    }
}

@MainActor
private final class LiveQuotaSource: LiveUsageDataSource {
    private var updateHandler: ((CodexUsageSnapshot) -> Void)?

    func fetchUsage() async throws -> CodexUsageSnapshot { throw TestQuotaError.failed }
    func setUpdateHandler(_ handler: @escaping (CodexUsageSnapshot) -> Void) { updateHandler = handler }
    func emit(_ snapshot: CodexUsageSnapshot) { updateHandler?(snapshot) }
    func stop() { updateHandler = nil }
}

@MainActor
private final class SuspendedRetryQuotaSource: UsageDataSource {
    private let initial: CodexUsageSnapshot
    private var calls = 0
    private var continuation: CheckedContinuation<CodexUsageSnapshot, Error>?
    var onRetry: (() -> Void)?

    init(snapshot: CodexUsageSnapshot) { initial = snapshot }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        calls += 1
        if calls == 1 { return initial }
        if calls == 2 { throw TestQuotaError.failed }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onRetry?()
        }
    }

    func completeRetry(with snapshot: CodexUsageSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
