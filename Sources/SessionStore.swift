import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private var lastError: Error?
    private var deletionFailed = false
    var errorMessage: String? {
        guard let lastError else { return nil }
        return deletionFailed ? L10n.tr("删除会话时出错：\(lastError.localizedDescription)") : lastError.localizedDescription
    }

    private let dataSource = CodexSessionDataSource()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await dataSource.listSessions()
            lastError = nil
            deletionFailed = false
        } catch {
            lastError = error
            deletionFailed = false
        }
    }

    func stop() { dataSource.stop() }

    func delete(_ session: CodexSession) async -> Bool {
        await delete([session])
    }

    func delete(_ targets: [CodexSession]) async -> Bool {
        guard !targets.isEmpty, !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            for session in targets {
                try await dataSource.deleteSession(id: session.id)
            }
            let deletedIDs = Set(targets.map(\.id))
            sessions.removeAll { deletedIDs.contains($0.id) }
            lastError = nil
            deletionFailed = false
            return true
        } catch {
            await refresh()
            deletionFailed = true
            lastError = error
            return false
        }
    }
}
