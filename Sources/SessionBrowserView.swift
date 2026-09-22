import SwiftUI
import AppKit

struct SessionBrowserView: View {
    @ObservedObject var store: SessionStore
    @State private var searchText = ""
    @State private var selectedCWD = ""
    @State private var recentOnly = true
    @State private var selectedSession: CodexSession?
    @State private var copied = false
    @State private var cleanupDays = 7
    @State private var deletionRequest: DeletionRequest?

    private var projectPaths: [String] {
        Array(Set(store.sessions.map(\.cwd))).sorted()
    }

    private var filteredSessions: [CodexSession] {
        let threshold = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return store.sessions.filter { session in
            let matchesProject = selectedCWD.isEmpty || session.cwd == selectedCWD
            let matchesTime = !recentOnly || session.updatedAt >= threshold
            let matchesQuery = query.isEmpty || [session.displayTitle, session.preview, session.cwd, session.id]
                .contains { $0.localizedLowercase.contains(query) }
            return matchesProject && matchesTime && matchesQuery
        }
    }

    private var cleanupCandidates: [CodexSession] {
        let threshold = Calendar.current.date(byAdding: .day, value: -cleanupDays, to: .now) ?? .distantPast
        return store.sessions.filter { $0.updatedAt < threshold && !$0.status.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("定位 Codex 会话", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if store.isDeleting { ProgressView().controlSize(.small) }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新会话列表")
            }

            TextField("搜索标题、任务、项目目录或 Session ID", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Picker("项目", selection: $selectedCWD) {
                    Text("全部项目").tag("")
                    ForEach(projectPaths, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Toggle("最近 7 天", isOn: $recentOnly)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(filteredSessions.count) 个会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("批量清理")
                    .font(.caption.weight(.semibold))
                Stepper(value: $cleanupDays, in: 1...365) {
                    Text("\(cleanupDays) 天前")
                        .font(.caption)
                }
                Text("\(cleanupCandidates.count) 个非活跃会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("删除", role: .destructive) {
                    deletionRequest = .batch(days: cleanupDays, sessions: cleanupCandidates)
                }
                .disabled(cleanupCandidates.isEmpty || store.isDeleting)
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            List(filteredSessions, selection: $selectedSession) { session in
                SessionRow(session: session)
                    .tag(session)
            }
            .overlay {
                if !store.isLoading && filteredSessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("未找到会话").font(.subheadline)
                        Text("尝试清除搜索条件或关闭“最近 7 天”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 260)

            if let session = selectedSession {
                SessionDetail(session: session, copied: copied) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.resumeCommand, forType: .string)
                    copied = true
                } openProject: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
                } deleteSession: {
                    deletionRequest = .single(session)
                }
            } else {
                Text("选择一个会话以复制续接命令或打开对应项目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            }
        }
        .padding(16)
        .frame(width: 580, height: 600)
        .task { await store.refresh() }
        .onChange(of: selectedSession) { _ in copied = false }
        .alert(item: $deletionRequest) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text("终止并删除")) {
                    Task {
                        let didDelete = await store.delete(request.sessions)
                        if didDelete, let selectedSession,
                           request.sessions.contains(where: { $0.id == selectedSession.id }) {
                            self.selectedSession = nil
                        }
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }
}

private struct SessionRow: View {
    let session: CodexSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle).lineLimit(1)
                Spacer()
                Text(session.status.label).font(.caption).foregroundStyle(statusColor)
            }
            Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text(session.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                Text("·")
                Text(session.preview).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch session.status {
        case .active: .green
        case .systemError: .red
        default: .secondary
        }
    }
}

private struct SessionDetail: View {
    let session: CodexSession
    let copied: Bool
    let copyCommand: () -> Void
    let openProject: () -> Void
    let deleteSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(session.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(session.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(copied ? "已复制续接命令" : "复制续接命令", action: copyCommand)
                Button("打开项目目录", action: openProject)
                Button(session.status.isActive ? "终止并删除会话…" : "删除会话…", role: .destructive, action: deleteSession)
                Spacer()
                Text("在终端粘贴后即可继续会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeletionRequest: Identifiable {
    enum Kind { case single, batch(days: Int) }

    let id = UUID()
    let kind: Kind
    let sessions: [CodexSession]

    static func single(_ session: CodexSession) -> Self {
        Self(kind: .single, sessions: [session])
    }

    static func batch(days: Int, sessions: [CodexSession]) -> Self {
        Self(kind: .batch(days: days), sessions: sessions)
    }

    var title: String {
        switch kind {
        case .single: "终止并删除会话？"
        case .batch(let days): "删除超过 \(days) 天的会话？"
        }
    }

    var message: String {
        switch kind {
        case .single:
            let session = sessions[0]
            return "“\(session.displayTitle.confirmationExcerpt)”及其派生会话将被永久删除，无法恢复。\(session.status.isActive ? "该会话当前正在运行，会被终止。" : "")"
        case .batch(let days):
            return "将永久删除 \(sessions.count) 个最后活跃于 \(days) 天前的非活跃会话及其派生会话，无法恢复。正在运行的会话不会受影响。"
        }
    }
}

private extension String {
    /// Keeps native confirmation alerts compact even when a session title is unusually long.
    var confirmationExcerpt: String {
        let normalized = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let maximumCharacterCount = 48
        guard normalized.count > maximumCharacterCount else { return normalized }
        return String(normalized.prefix(maximumCharacterCount - 1)) + "…"
    }
}
