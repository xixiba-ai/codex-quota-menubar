import SwiftUI

struct QuotaHelpView: View {
    @ObservedObject private var language: AppLanguageStore
    @ObservedObject var store: QuotaStore
    let openSessions: () -> Void
    let dismiss: () -> Void
    @State private var section: HelpSection = .gettingStarted

    init(store: QuotaStore, languageStore: AppLanguageStore = .shared,
         openSessions: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.store = store
        self.language = languageStore
        self.openSessions = openSessions
        self.dismiss = dismiss
    }

    private enum HelpSection: CaseIterable {
        case gettingStarted, features, questions

        var title: String {
            switch self {
            case .gettingStarted: L10n.tr("快速上手")
            case .features: L10n.tr("功能说明")
            case .questions: L10n.tr("常见问题")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 60, height: 60)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("额度，一眼有数")).font(.title2.bold())
                    Text(L10n.tr("从菜单栏查看 Codex 额度，找回最近的工作。"))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Picker(L10n.tr("帮助主题"), selection: $section) {
                ForEach(HelpSection.allCases, id: \.self) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .id(language.selection)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .gettingStarted: gettingStarted
                    case .features: features
                    case .questions: questions
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .id(section)

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(L10n.tr("语言"), selection: Binding(
                        get: { language.selection },
                        set: { language.select($0) }
                    )) {
                        Text(L10n.tr("跟随系统")).tag(AppLanguage.system)
                        Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                        Text(verbatim: "English").tag(AppLanguage.english)
                    }
                    .id(language.selection)
                    .frame(width: 210)
                    Spacer()
                    Button(L10n.tr("开始使用"), action: dismiss)
                        .keyboardShortcut(.defaultAction)
                }
                Text(L10n.tr("随时从“设置 → 工具与帮助”重新打开帮助。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(width: 620, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard("1", title: L10n.tr("先连接本机 Codex")) {
                Text(L10n.tr("默认使用这台 Mac 上已安装并登录的 Codex CLI。登录由 CLI 处理，Quota 不保存你的登录凭据。"))
                connectionStatus
            }
            helpCard("2", title: L10n.tr("在屏幕顶部找到 Quota")) {
                Text(L10n.tr("Quota 常驻 macOS 菜单栏，没有 Dock 图标。关闭这个帮助窗口后，它仍会继续显示额度。"))
                HStack(spacing: 12) {
                    Text("55% " + TimeFormatter.resetDate(.now.addingTimeInterval(86400)))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Text(L10n.tr("示例：长期额度剩余 55%，在显示的日期重置。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.tr("菜单栏显示长期额度剩余比例与重置日期；点击可查看短周期等明细。若只有短周期额度，则显示其剩余比例和倒计时。"))
            }
            helpCard("3", title: L10n.tr("先用默认设置就够了")) {
                Text(L10n.tr("额度每 60 秒自动读取一次，也会接收本机 CLI 的额度变动。需要最新数据时，打开“设置 → 通用 → 立即刷新”。"))
                Text(L10n.tr("“自动刷新额度”默认关闭，可在“设置 → 自动使用与通知”按需开启。长期重置颜色提醒默认开启，可在“通用”调整。"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("正在读取额度…"))
                } else if store.errorMessage != nil || store.freshness() == .stale {
                    Label(L10n.tr("暂时无法读取额度"), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if store.snapshot != nil {
                    Label(L10n.tr("已读取到额度"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.tr("等待连接额度数据源"))
                }
                Spacer()
                Button(L10n.tr("检查连接")) { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(L10n.tr("查看连接排查")) { section = .questions }
                    .buttonStyle(.link)
            } else if let snapshot = store.snapshot {
                Text(L10n.tr("\(snapshot.localizedSourceDescription) · 更新于 \(snapshot.updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard("arrow.clockwise", title: L10n.tr("读取额度与自动刷新额度")) {
                Text(L10n.tr("“立即刷新”和每 60 秒的自动读取用于更新额度显示，不会发起对话任务。"))
                Text(L10n.tr("开启“自动刷新额度”后，会在设定时间，以及检测到主动或官方重置后的额度恢复时，发起一次最小 Codex 请求，可能消耗少量额度。"))
                Text(L10n.tr("重置后随本机额度推送或下一次 60 秒读取检测恢复；重复读取不会重复使用。首次读取和切换账号只建立基线。"))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("默认时间：\(AutoRefreshSchedule.formattedTimeList(AutoRefreshSchedule.defaultTriggerMinutes))（本机时间）。在“设置 → 自动使用与通知 → 修改触发时间…”中调整；应用需保持运行，休眠后会补偿最近一个错过的时间点。"))
                    .foregroundStyle(.secondary)
            }
            helpCard("bell", title: L10n.tr("Codex Reset 动态通知")) {
                Text(L10n.tr("在“设置 → 自动使用与通知”开启 Codex Reset 动态通知，读取 codex-reset.com 的公开时间线，无需 X 登录。首次成功读取仅建立基线，不通知历史事件。"))
                Text(L10n.tr("这是第三方报告；全局重置与重置券动态分开显示，不代表你的账号已到账，也不会修改长期额度重置时间或自动使用规则。关闭后不请求数据，失败保留缓存并显示上次成功时间。"))
                    .foregroundStyle(.secondary)
            }
            helpCard("bubble.left.and.bubble.right", title: L10n.tr("定位与整理会话")) {
                Text(L10n.tr("按标题、任务、项目目录或 Session ID 搜索本机保存的 CLI 和 VS Code 会话。选中后点击“在终端续接”，也可复制命令或打开项目目录。"))
                Text(L10n.tr("默认只看最近 7 天，找旧会话时可取消筛选。删除会永久移除记录及派生会话；批量清理会跳过仍在运行的会话，并在执行前确认。"))
                    .foregroundStyle(.secondary)
                Button(L10n.tr("打开会话列表…"), action: openSessions)
            }
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("遇到问题，从这里开始")).font(.headline)
            question(L10n.tr("显示“未找到 Codex CLI”或无法读取额度？"), expanded: true) {
                Text(L10n.tr("先确认本机已安装 Codex CLI，并能在终端中正常打开和登录。完成后回到“快速上手”，点击“检查连接”。"))
                Text(L10n.tr("已安装但仍找不到？Quota 会检查 ~/.local/bin/codex、/opt/homebrew/bin/codex 和 /usr/local/bin/codex。自定义安装位置可通过 codexExecutablePath 配置，修改后重启 Quota。"))
                Text(L10n.tr("若提示登录、网络或额度数据异常，请按具体错误检查 CLI 登录状态和网络，然后重试。"))
            }
            question(L10n.tr("为什么百分比没变，或只显示一个周期？")) {
                Text(L10n.tr("百分比表示剩余额度，会取整显示；小幅使用不一定立即改变数字。周期取决于数据源和套餐，未提供的周期不会补成虚构数据。"))
                Text(L10n.tr("刷新失败时可能保留上次成功读取的数值，请查看菜单中的更新时间。可以在“快速上手”检查连接并查看错误。"))
            }
            question(L10n.tr("开启自动刷新，能恢复用完的额度吗？")) {
                Text(L10n.tr("不能保证。实际额度与重置由服务决定；开启后会按时间以及在检测到额度恢复时使用一次。只想更新显示时，使用“立即刷新”即可。"))
            }
            question(L10n.tr("为什么找不到之前的会话？")) {
                Text(L10n.tr("先关闭“最近 7 天”，选择“全部项目”并清空搜索条件，然后刷新会话列表。这里只显示本机可读取的 CLI 和 VS Code 会话，其他设备或未保存在本机的会话不会出现。"))
            }
            question(L10n.tr("关掉窗口后，怎么重新打开？")) {
                Text(L10n.tr("点击菜单栏额度数字，可直接选择“定位 Codex 会话…”。打开“设置… → 工具与帮助”可重新打开帮助或退出 Quota。也可按 ⌘, 打开设置。首次启动时帮助会自动显示一次。"))
            }
        }
    }

    private func helpCard<Content: View>(_ icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Group {
                    if Int(icon) != nil {
                        Text(icon).font(.caption.bold())
                    } else {
                        Image(systemName: icon).font(.caption.bold())
                    }
                }
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
                Text(title).font(.headline)
            }
            content()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func question<Content: View>(_ title: String, expanded: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HelpQuestion(title: title, initiallyExpanded: expanded, content: content())
    }
}

private struct HelpQuestion<Content: View>: View {
    let title: String
    let content: Content
    @State private var isExpanded: Bool

    init(title: String, initiallyExpanded: Bool, content: Content) {
        self.title = title
        self.content = content
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Text(title).font(.headline)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
