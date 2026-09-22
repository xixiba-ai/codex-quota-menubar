import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var errorMessage: String?

    private let dataSource = CodexSessionDataSource()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await dataSource.listSessions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = nil
            return true
        } catch {
            errorMessage = "删除会话时出错：\(error.localizedDescription)"
            await refresh()
            return false
        }
    }
}
