import SwiftUI

struct QuotaHelpView: View {
    @ObservedObject var store: QuotaStore
    let openSessions: () -> Void
    let dismiss: () -> Void
    @State private var section: HelpSection = .gettingStarted

    private enum HelpSection: String, CaseIterable {
        case gettingStarted = "快速上手"
        case features = "功能说明"
        case questions = "常见问题"
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
                    Text("额度，一眼有数").font(.title2.bold())
                    Text("从菜单栏查看 Codex 额度，找回最近的工作。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Picker("帮助主题", selection: $section) {
                ForEach(HelpSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
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
            HStack {
                Text("随时从菜单栏的“新手引导与帮助…”回来。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("开始使用", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 620, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard("1", title: "先连接本机 Codex") {
                Text("默认使用这台 Mac 上已安装并登录的 Codex CLI。登录由 CLI 处理，Quota 不保存你的登录凭据。")
                connectionStatus
            }
            helpCard("2", title: "在屏幕顶部找到 Quota") {
                Text("Quota 常驻 macOS 菜单栏，没有 Dock 图标。关闭这个帮助窗口后，它仍会继续显示额度。")
                HStack(spacing: 12) {
                    Text("65% 02:30 · 55%")
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Text("示例：短周期剩余 65%，\n2 小时 30 分后重置；长期剩余 55%。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("点击菜单栏数字，可查看完整重置时间。若套餐只提供长期额度，会显示剩余比例和重置日期。")
            }
            helpCard("3", title: "先用默认设置就够了") {
                Text("额度每 60 秒自动读取一次，也会接收本机 CLI 的额度变动。需要最新数据时，点击菜单中的“立即刷新”。")
                Text("“自动刷新额度”和“重置概率预测”默认关闭，可在了解功能后按需开启。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("正在读取额度…")
                } else if store.errorMessage != nil {
                    Label("暂时无法读取额度", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if store.snapshot != nil {
                    Label("已读取到额度", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("等待连接额度数据源")
                }
                Spacer()
                Button("检查连接") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("查看连接排查") { section = .questions }
                    .buttonStyle(.link)
            } else if let snapshot = store.snapshot {
                Text("\(snapshot.sourceDescription) · 更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpCard("arrow.clockwise", title: "读取额度与自动刷新额度") {
                Text("“立即刷新”和每 60 秒的自动读取用于更新额度显示，不会发起对话任务。")
                Text("开启“自动刷新额度”后，会在设定时间发起一次实际的最小 Codex 请求，可能消耗少量额度；它不会增加或保证重置额度。")
                Text("默认时间：\(AutoRefreshSchedule.formattedTimeList(AutoRefreshSchedule.defaultTriggerMinutes))（本机时间）。在“修改触发时间…”中调整；应用需保持运行，休眠后会补偿最近一个错过的时间点。")
                    .foregroundStyle(.secondary)
            }
            helpCard("chart.line.uptrend.xyaxis", title: "重置概率预测") {
                Text("开启后，会从 willcodexquotareset.com 获取未来 48 小时的第三方重置概率，随主动额度刷新更新。它是估算，不是官方重置承诺。")
                Text("请求不携带 Codex 登录凭据。预测失败不会影响额度读取；显示“数据可能已过期”时，请留意更新时间。")
                    .foregroundStyle(.secondary)
            }
            helpCard("bubble.left.and.bubble.right", title: "定位与整理会话") {
                Text("按标题、任务、项目目录或 Session ID 搜索本机保存的 CLI 和 VS Code 会话。选中后可复制续接命令，在终端执行，或打开项目目录。")
                Text("默认只看最近 7 天，找旧会话时可取消筛选。删除会永久移除记录及派生会话；批量清理会跳过仍在运行的会话，并在执行前确认。")
                    .foregroundStyle(.secondary)
                Button("打开会话列表…", action: openSessions)
            }
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("遇到问题，从这里开始").font(.headline)
            question("显示“未找到 Codex CLI”或无法读取额度？", expanded: true) {
                Text("先确认本机已安装 Codex CLI，并能在终端中正常打开和登录。完成后回到“快速上手”，点击“检查连接”。")
                Text("已安装但仍找不到？Quota 会检查 ~/.local/bin/codex、/opt/homebrew/bin/codex 和 /usr/local/bin/codex。自定义安装位置可通过 codexExecutablePath 配置，修改后重启 Quota。")
                Text("若提示登录、网络或额度数据异常，请按具体错误检查 CLI 登录状态和网络，然后重试。")
            }
            question("为什么百分比没变，或只显示一个周期？") {
                Text("百分比表示剩余额度，会取整显示；小幅使用不一定立即改变数字。周期取决于数据源和套餐，未提供的周期不会补成虚构数据。")
                Text("刷新失败时可能保留上次成功读取的数值，请查看菜单中的更新时间。可以在“快速上手”检查连接并查看错误。")
            }
            question("开启自动刷新，能恢复用完的额度吗？") {
                Text("不能保证。该功能只会按时间发起一次最小 Codex 请求，实际额度与重置由服务决定。只想更新显示时，使用“立即刷新”即可。")
            }
            question("为什么找不到之前的会话？") {
                Text("先关闭“最近 7 天”，选择“全部项目”并清空搜索条件，然后刷新会话列表。这里只显示本机可读取的 CLI 和 VS Code 会话，其他设备或未保存在本机的会话不会出现。")
            }
            question("关掉窗口后，怎么重新打开？") {
                Text("点击屏幕顶部菜单栏中的额度数字，选择“新手引导与帮助…”。首次启动时自动显示一次，以后可随时手动打开。退出 Quota 请使用菜单里的“退出”。")
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
