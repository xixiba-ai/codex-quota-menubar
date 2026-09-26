import SwiftUI

struct AboutView: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var status: Status = .idle
    private let currentTag: String
    private let checker: AppUpdateChecker

    init(currentTag: String = AppVersion.currentTag(), checker: AppUpdateChecker = AppUpdateChecker()) {
        self.currentTag = currentTag
        self.checker = checker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex Quota").font(.title2.bold())
                Text(L10n.tr("版本：\(currentTag)"))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("开源许可：MIT"))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Link(L10n.tr("查看 GitHub 发布页"), destination: AppUpdateChecker.releasesURL)
                Button(L10n.tr("检查更新")) {
                    status = .checking
                    Task {
                        do { status = .result(try await checker.check(currentTag: currentTag)) }
                        catch { status = .failed }
                    }
                }
                .disabled(status == .checking)
            }

            switch status {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView(L10n.tr("正在检查更新…"))
            case .result(.upToDate):
                Text(L10n.tr("当前已是最新版本。"))
            case .result(.updateAvailable(let release)):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("发现新版本：\(release.tag)"))
                    Link(L10n.tr("查看新版本并手动下载"), destination: release.url)
                }
            case .failed:
                Text(L10n.tr("无法检查更新，请稍后重试。"))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr("仅在点击“检查更新”时访问公开的 GitHub 发布列表（含预览版）。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.body)
        .frame(width: 390, alignment: .leading)
        .padding(24)
    }

    private enum Status: Equatable {
        case idle
        case checking
        case result(AppUpdateResult)
        case failed
    }
}
