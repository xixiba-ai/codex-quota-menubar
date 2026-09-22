import XCTest
@testable import Codex_Quota

final class ResetForecastServiceTests: XCTestCase {
    override func tearDown() {
        ForecastURLProtocol.handler = nil
        super.tearDown()
    }

    func testParsesFractionalISODateAndScore() async throws {
        ForecastURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let body = #"{"fetchedAt":"2026-09-10T12:34:56.789Z","forecast":{"score":32,"horizonHours":48,"other":"ignored"}}"#
            return (200, Data(body.utf8))
        }
        let value = try await makeService().fetch()
        XCTAssertEqual(value.score, 32)
        XCTAssertEqual(value.horizonHours, 48)
        XCTAssertEqual(value.fetchedAt.timeIntervalSince1970, 1_789_043_696.789, accuracy: 0.001)
    }

    func testRejectsHTTPFailureAndOutOfRangeScore() async {
        ForecastURLProtocol.handler = { _ in (503, Data()) }
        do {
            _ = try await makeService().fetch()
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? ResetForecastError, .httpStatus(503))
        }

        ForecastURLProtocol.handler = { _ in
            (200, Data(#"{"fetchedAt":"2026-09-10T12:34:56Z","forecast":{"score":101,"horizonHours":48}}"#.utf8))
        }
        do {
            _ = try await makeService().fetch()
            XCTFail("Expected validation error")
        } catch {
            XCTAssertEqual(error as? ResetForecastError, .invalidScore)
        }
    }

    func testConcurrentRequestsCoalesce() async throws {
        let lock = NSLock()
        var requests = 0
        ForecastURLProtocol.handler = { _ in
            lock.lock(); requests += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            return (200, Data(#"{"fetchedAt":"2026-09-10T12:34:56Z","forecast":{"score":32,"horizonHours":48}}"#.utf8))
        }
        let service = makeService()
        async let first = service.fetch()
        async let second = service.fetch()
        _ = try await (first, second)
        XCTAssertEqual(requests, 1)
    }

    func testCompletedRequestDoesNotRemainCached() async throws {
        let lock = NSLock()
        var requests = 0
        ForecastURLProtocol.handler = { _ in
            lock.lock(); requests += 1; lock.unlock()
            return (200, Data(#"{"fetchedAt":"2026-09-10T12:34:56Z","forecast":{"score":32,"horizonHours":48}}"#.utf8))
        }
        let service = makeService()
        _ = try await service.fetch()
        _ = try await service.fetch()
        XCTAssertEqual(requests, 2)
    }

    private func makeService() -> ResetForecastService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForecastURLProtocol.self]
        return ResetForecastService(session: URLSession(configuration: configuration))
    }
}

@MainActor
final class ResetForecastStoreTests: XCTestCase {
    func testToggleDefaultsOffPersistsAndEnablingFetchesImmediately() async {
        let defaults = makeDefaults()
        let fetcher = StubForecastFetcher(results: [.success(sample(score: 44))])
        let store = ResetForecastStore(fetcher: fetcher, defaults: defaults)
        XCTAssertFalse(store.isEnabled)

        store.setEnabled(true)
        await eventually { store.forecast?.score == 44 }
        XCTAssertTrue(defaults.bool(forKey: ResetForecastStore.enabledDefaultsKey))
        XCTAssertEqual(fetcher.callCount, 1)
    }

    func testFailureKeepsLastGoodValueAndMarksItStale() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: ResetForecastStore.enabledDefaultsKey)
        let fetcher = StubForecastFetcher(results: [.success(sample(score: 44)), .failure(TestError.failed)])
        let store = ResetForecastStore(fetcher: fetcher, defaults: defaults)
        await store.refreshForActiveQuotaRead()
        await store.refreshForActiveQuotaRead()
        XCTAssertEqual(store.forecast?.score, 44)
        XCTAssertNotNil(store.errorMessage)
    }

    func testDisablingCancelsAndLateResultCannotPublish() async {
        let defaults = makeDefaults()
        let fetcher = SuspendedForecastFetcher()
        let store = ResetForecastStore(fetcher: fetcher, defaults: defaults)
        store.setEnabled(true)
        await fetcher.waitUntilStarted()
        store.setEnabled(false)
        fetcher.resume(with: sample(score: 88))
        await fetcher.waitUntilFinished()
        XCTAssertNil(store.forecast)
        XCTAssertEqual(fetcher.cancelCount, 1)
    }

    func testDisabledRefreshDoesNotFetchAndStopKeepsPreference() async {
        let defaults = makeDefaults()
        let fetcher = StubForecastFetcher(results: [.success(sample(score: 12))])
        let store = ResetForecastStore(fetcher: fetcher, defaults: defaults)
        await store.refreshForActiveQuotaRead()
        XCTAssertEqual(fetcher.callCount, 0)

        store.setEnabled(true)
        await eventually { fetcher.callCount == 1 }
        store.stop()
        XCTAssertTrue(defaults.bool(forKey: ResetForecastStore.enabledDefaultsKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ResetForecastStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func eventually(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "Condition was not met")
    }
}

private final class ForecastURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private enum TestError: Error { case failed }

private func sample(score: Int) -> ResetForecast {
    ResetForecast(score: score, horizonHours: 48, fetchedAt: Date(timeIntervalSince1970: 1_788_957_296))
}

private final class StubForecastFetcher: ResetForecastFetching, @unchecked Sendable {
    private var results: [Result<ResetForecast, Error>]
    private(set) var callCount = 0
    init(results: [Result<ResetForecast, Error>]) { self.results = results }
    func fetch() async throws -> ResetForecast {
        callCount += 1
        return try results.removeFirst().get()
    }
    func cancel() {}
}

private final class SuspendedForecastFetcher: ResetForecastFetching, @unchecked Sendable {
    private var continuation: CheckedContinuation<ResetForecast, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var hasFinished = false
    private(set) var cancelCount = 0
    func fetch() async throws -> ResetForecast {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        let result = try await withCheckedThrowingContinuation { continuation = $0 }
        hasFinished = true
        finishedContinuation?.resume()
        finishedContinuation = nil
        return result
    }
    func cancel() { cancelCount += 1 }
    func resume(with value: ResetForecast) { continuation?.resume(returning: value); continuation = nil }
    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func waitUntilFinished() async {
        if hasFinished { return }
        await withCheckedContinuation { finishedContinuation = $0 }
    }
}
