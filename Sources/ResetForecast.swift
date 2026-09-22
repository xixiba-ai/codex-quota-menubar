import Combine
import Foundation

struct ResetForecast: Codable, Equatable, Sendable {
    let score: Int
    let horizonHours: Int
    let fetchedAt: Date
}

enum ResetForecastError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case invalidScore
}

extension Notification.Name {
    /// Posted only when quota is actively requested. CLI push updates do not post it.
    static let codexQuotaActiveRefresh = Notification.Name("CodexQuotaActiveRefresh")
}

protocol ResetForecastFetching: Sendable {
    func fetch() async throws -> ResetForecast
    func cancel()
}

final class ResetForecastService: ResetForecastFetching, @unchecked Sendable {
    static let endpoint = URL(string: "https://www.willcodexquotareset.com/api/forecast")!

    private struct Envelope: Decodable {
        struct Forecast: Decodable {
            let score: Int
            let horizonHours: Int
        }

        let fetchedAt: Date
        let forecast: Forecast
    }

    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: (id: UUID, task: Task<ResetForecast, Error>)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func fetch() async throws -> ResetForecast {
        let request = withLock { () -> (id: UUID, task: Task<ResetForecast, Error>) in
            if let inFlight { return inFlight }
            let id = UUID()
            let task = Task { [session] in
                var request = URLRequest(url: Self.endpoint)
                request.timeoutInterval = 10
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw ResetForecastError.invalidResponse
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw ResetForecastError.httpStatus(response.statusCode)
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let value = try container.decode(String.self)
                    let fractional = ISO8601DateFormatter()
                    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = fractional.date(from: value) { return date }
                    let plain = ISO8601DateFormatter()
                    plain.formatOptions = [.withInternetDateTime]
                    if let date = plain.date(from: value) { return date }
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid ISO-8601 fetchedAt"
                    )
                }
                let envelope = try decoder.decode(Envelope.self, from: data)
                guard (0...100).contains(envelope.forecast.score), envelope.forecast.horizonHours > 0 else {
                    throw ResetForecastError.invalidScore
                }
                return ResetForecast(
                    score: envelope.forecast.score,
                    horizonHours: envelope.forecast.horizonHours,
                    fetchedAt: envelope.fetchedAt
                )
            }
            let request = (id, task)
            inFlight = request
            return request
        }

        defer {
            withLock {
                if inFlight?.id == request.id { inFlight = nil }
            }
        }
        return try await request.task.value
    }

    func cancel() {
        let task = withLock {
            let task = inFlight
            inFlight = nil
            return task
        }
        task?.task.cancel()
    }
}

@MainActor
final class ResetForecastStore: ObservableObject {
    static let enabledDefaultsKey = "resetForecastEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var forecast: ResetForecast?
    @Published private(set) var lastAttemptAt: Date?
    @Published private var didFail = false
    var errorMessage: String? { didFail ? L10n.tr("预测更新失败") : nil }

    private let fetcher: any ResetForecastFetching
    private let defaults: UserDefaults
    private var generation = 0

    init(fetcher: any ResetForecastFetching = ResetForecastService(), defaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        generation += 1
        if enabled {
            Task { await refreshForActiveQuotaRead() }
        } else {
            fetcher.cancel()
            didFail = false
        }
    }

    func stop() {
        generation += 1
        fetcher.cancel()
    }

    /// Call this for manual refreshes, the 60-second active read, and CLI scheduled/retry triggers.
    func refreshForActiveQuotaRead() async {
        guard isEnabled else { return }
        let requestGeneration = generation
        lastAttemptAt = .now
        do {
            let result = try await fetcher.fetch()
            guard isEnabled, generation == requestGeneration else { return }
            forecast = result
            didFail = false
        } catch is CancellationError {
            // Disabling intentionally cancels an active request.
        } catch {
            guard isEnabled, generation == requestGeneration else { return }
            didFail = true
        }
    }
}
