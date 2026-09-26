import Foundation
import XCTest
@testable import Codex_Quota

@MainActor
final class QuotaFreshnessTests: XCTestCase {
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
