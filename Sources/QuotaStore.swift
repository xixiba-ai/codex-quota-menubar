import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var state: QuotaState = .loading(nil)
    @Published private(set) var isRefreshing = false

    private var latestError: Error?
    private var liveUpdateRevision = 0
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration = .seconds(60)
    private let dataSource: any UsageDataSource

    init(dataSource: (any UsageDataSource)? = nil) {
        self.dataSource = dataSource ?? UsageDataSourceFactory.make()
    }

    deinit {
        refreshTask?.cancel()
    }

    var snapshot: CodexUsageSnapshot? { state.snapshot }
    func freshness(at date: Date = .now) -> QuotaFreshness {
        if latestError != nil, snapshot != nil { return .stale }
        return state.freshness(at: date)
    }
    func freshnessText(at date: Date = .now) -> String { freshness(at: date).localizedText }
    var errorMessage: String? {
        if case .unavailable(let message, _) = state { return latestError?.localizedDescription ?? message }
        return nil
    }

    func start() async {
        guard refreshTask == nil else { return }
        (dataSource as? any LiveUsageDataSource)?.setUpdateHandler { [weak self] snapshot in
            self?.liveUpdateRevision += 1
            self?.latestError = nil
            self?.state = .available(snapshot)
        }
        await refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let previous = snapshot
        let revisionAtStart = liveUpdateRevision
        state = .loading(previous)
        do {
            let snapshot = try await dataSource.fetchUsage()
            guard revisionAtStart == liveUpdateRevision else { return }
            latestError = nil
            state = .available(snapshot)
        } catch {
            guard revisionAtStart == liveUpdateRevision else { return }
            latestError = error
            state = .unavailable(message: error.localizedDescription, lastKnown: previous)
        }
    }

    func stop() {
        refreshTask?.cancel()
        (dataSource as? any LiveUsageDataSource)?.stop()
    }
}
