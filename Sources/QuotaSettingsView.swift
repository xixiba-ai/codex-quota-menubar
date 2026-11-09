import SwiftUI

struct QuotaSettingsActions {
    var refresh: () -> Void
    var editSchedule: () -> Void
    var showSessions: () -> Void
    var showHelp: () -> Void
    var showAbout: () -> Void
    var quit: () -> Void
}

struct QuotaSettingsView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var scheduler: AutoRefreshScheduler
    @ObservedObject var codexReset: CodexResetMonitor
    @ObservedObject var reminder: ResetReminderStore
    @ObservedObject var language: AppLanguageStore
    let actions: QuotaSettingsActions
    var offlinePreview = false
    @State private var redHours: String
    @State private var orangeHours: String
    @State private var saved = false

    init(store: QuotaStore, scheduler: AutoRefreshScheduler, codexReset: CodexResetMonitor,
         reminder: ResetReminderStore, language: AppLanguageStore, actions: QuotaSettingsActions,
         offlinePreview: Bool = false) {
        self.store = store; self.scheduler = scheduler; self.codexReset = codexReset
        self.reminder = reminder; self.language = language; self.actions = actions
        self.offlinePreview = offlinePreview
        _redHours = State(initialValue: String(reminder.configuration.redHours))
        _orangeHours = State(initialValue: String(reminder.configuration.orangeHours))
    }

    private var candidate: ResetReminderConfiguration? {
        guard let red = Int(redHours.trimmingCharacters(in: .whitespaces)),
              let orange = Int(orangeHours.trimmingCharacters(in: .whitespaces)) else { return nil }
        let value = ResetReminderConfiguration(isEnabled: reminder.configuration.isEnabled, redHours: red, orangeHours: orange)
        return value.isValid ? value : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("设置")).font(.title2.bold())
                    Text(L10n.tr("管理额度提醒、自动使用和常用工具。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if offlinePreview {
                Text(L10n.tr("离线预览 · 示例数据 · 不连接 Codex 或外部网站"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TabView {
                page { general }
                    .tabItem { Label(L10n.tr("通用"), systemImage: "gearshape") }
                page { automation }
                    .tabItem { Label(L10n.tr("自动使用与通知"), systemImage: "clock.arrow.circlepath") }
                page { tools }
                    .tabItem { Label(L10n.tr("工具与帮助"), systemImage: "wrench.and.screwdriver") }
            }
            .id(language.selection)
        }
        .padding(22)
        .frame(minWidth: 650, idealWidth: 650, minHeight: 690, idealHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(L10n.tr("长期／周额度重置提醒"), icon: "calendar.badge.clock") {
                Toggle(L10n.tr("启用颜色提醒"), isOn: Binding(
                    get: { reminder.configuration.isEnabled }, set: { reminder.setEnabled($0) }
                ))
                Text(L10n.tr("仅针对额度的长期／周重置时间；短周期和第三方动态不参与提醒。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    thresholdField(L10n.tr("红色提醒"), value: $redHours, color: .red)
                    thresholdField(L10n.tr("橙色提醒"), value: $orangeHours, color: .orange)
                }
                .disabled(!reminder.configuration.isEnabled)
                HStack {
                    Button(L10n.tr("保存阈值")) {
                        if let candidate, reminder.save(candidate) { saved = true }
                    }
                    .disabled(candidate == nil || candidate == reminder.configuration || !reminder.configuration.isEnabled)
                    if saved { Text(L10n.tr("已保存")).font(.caption).foregroundStyle(.secondary) }
                    if candidate == nil {
                        Text(L10n.tr("请输入正整数小时，且橙色阈值必须大于红色阈值。"))
                            .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(L10n.tr("小于红色阈值显示红色；从红色阈值起、小于橙色阈值显示橙色；其余保持正常。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let tier = ResetReminderPolicy.tier(resetAt: store.snapshot?.longTermResetWindow?.resetsAt,
                                                   now: .now, configuration: reminder.configuration)
                Label(tier.statusText, systemImage: "circle.fill")
                    .font(.callout).foregroundStyle(Color(nsColor: tier.color ?? .labelColor))
                Text(L10n.tr("到期后保持“等待新周期确认”，直到读取到新的长期重置时间。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card(L10n.tr("额度数据"), icon: "gauge.with.dots.needle.50percent") {
                HStack {
                    Text(store.freshnessText()).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.isRefreshing ? L10n.tr("正在刷新…") : L10n.tr("立即刷新"), action: actions.refresh)
                        .disabled(store.isRefreshing)
                }
                if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text(L10n.tr("只更新额度显示，不会发起对话任务。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            card(L10n.tr("语言"), icon: "globe") {
                Picker(L10n.tr("界面语言"), selection: Binding(
                    get: { language.selection }, set: { language.select($0) }
                )) {
                    Text(L10n.tr("跟随系统")).tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }.frame(maxWidth: 330)
            }
        }
        .onChange(of: redHours) { _ in saved = false }
        .onChange(of: orangeHours) { _ in saved = false }
    }

    private func thresholdField(_ title: String, value: Binding<String>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "circle.fill").foregroundStyle(color).font(.callout)
            HStack {
                Text(L10n.tr("剩余小于"))
                TextField("", text: value).frame(width: 56).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title)
                Text(L10n.tr("小时"))
            }.font(.callout)
        }
    }

    private var automation: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(L10n.tr("自动刷新额度"), icon: "clock.arrow.circlepath") {
                Toggle(L10n.tr("自动刷新额度"), isOn: Binding(
                    get: { scheduler.state.autoRefreshEnabled }, set: { scheduler.setEnabled($0) }
                )).disabled(offlinePreview)
                Text(L10n.tr("按计划或检测到重置后的额度恢复时发起最小 Codex 请求，可能消耗少量额度。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("5 小时／短周期模式的计划")).font(.callout.weight(.medium))
                HStack {
                    Text(L10n.tr("触发时间：\(AutoRefreshSchedule.formattedTimeList(scheduler.state.triggerMinutes))"))
                    Spacer()
                    Button(L10n.tr("修改触发时间…"), action: actions.editSchedule).disabled(offlinePreview)
                }.font(.callout)
                if scheduler.state.hasOnlyLongTermWindow {
                    Text(L10n.tr("当前仅长期／周额度：此计划暂不执行。设置会保留，恢复短周期额度后生效；重置后的自动使用仍由上方开关控制。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                autoRefreshDiagnostics
            }
            codexResetCard
        }
    }

    private var codexResetCard: some View {
        card(L10n.tr("Codex Reset 动态通知"), icon: "bell") {
            Toggle(L10n.tr("启用 Codex Reset 动态通知"), isOn: Binding(
                get: { codexReset.isEnabled }, set: { codexReset.setEnabled($0) }
            ))
            Text(codexReset.status()).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("上次成功：\(formatDate(codexReset.saved.lastSuccessAt))"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("第三方报告，不代表你的账号已到账；请以实际额度为准。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link(L10n.tr("数据来源：codex-reset.com（第三方）"), destination: CodexResetEvent.timelineURL)
                .font(.caption).disabled(offlinePreview)
            HStack {
                Button(L10n.tr("立即检查动态")) { codexReset.checkNow() }
                    .disabled(!codexReset.isEnabled || codexReset.isChecking || Date.now < codexReset.saved.nextAllowedAt)
                Button(L10n.tr("允许 macOS 通知")) { codexReset.authorizeNotifications() }.disabled(offlinePreview)
                Button(L10n.tr("测试通知")) { codexReset.testNotification() }.disabled(offlinePreview)
            }
            if !codexReset.testStatus.isEmpty { Text(codexReset.testStatus).font(.caption).foregroundStyle(.secondary) }
            if let issue = codexReset.notificationIssue {
                Text(issue == "permission" ? L10n.tr("新动态未发送通知：请在 macOS 中允许通知") : L10n.tr("新动态通知未能提交；可查看下方事件"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.tr("检查与通知诊断")) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("最近检查：\(formatDate(codexReset.saved.lastAttemptAt))"))
                    Text(L10n.tr("来源更新时间：\(formatDate(codexReset.saved.sourceUpdatedAt))"))
                    Text(L10n.tr("下次允许请求：\(formatDate(codexReset.saved.nextAllowedAt))"))
                    Text(L10n.tr("通知权限：\(permissionText)"))
                    if let code = codexReset.lastHTTPStatus { Text("HTTP \(code)") }
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if codexReset.events.isEmpty {
                Text(L10n.tr("尚无事件数据；首次成功读取仅建立通知基线。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(Array(codexReset.events.prefix(5))) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.label).font(.callout.weight(.medium))
                        Text(event.displaySummary).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        HStack {
                            Text(formatDate(event.announcedAt)).font(.caption).foregroundStyle(.secondary)
                            Link(L10n.tr("查看来源 ↗"), destination: event.safeURL).font(.caption).disabled(offlinePreview)
                        }
                    }
                }
            }
        }
    }

    private var permissionText: String {
        switch codexReset.notificationPermission {
        case "authorized": return L10n.tr("已允许")
        case "denied": return L10n.tr("未允许；请检查 macOS 通知设置")
        case "notDetermined": return L10n.tr("尚未授权")
        default: return L10n.tr("尚未检查")
        }
    }

    private var autoRefreshDiagnostics: some View {
        let state = scheduler.state
        let result = state.lastTriggerResult?.localizedText ?? L10n.tr("尚未执行")
        let reason = state.lastTriggerReason.map { " · " + $0.localizedText } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("当前状态：\(state.autoRefreshEnabled ? L10n.tr("开启") : L10n.tr("关闭"))"))
            Text(L10n.tr("最近一次触发：\(formatDate(state.lastTriggerTime))"))
            Text(L10n.tr("执行结果：\(result)\(reason)"))
            if state.lastTriggerResult == .failed {
                Text(L10n.tr("失败原因：\((state.lastFailureKind ?? .unknown).localizedText)"))
            }
            if !state.hasOnlyLongTermWindow { Text(L10n.tr("下一次计划触发：\(formatDate(state.nextTriggerTime))")) }
            if state.autoRefreshEnabled, let retry = state.pendingQuotaResetRetryTime {
                Text(L10n.tr("额度重置后重试：\(formatDate(retry))"))
            }
        }
        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func formatDate(_ date: Date?) -> String {
        date?.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)) ?? "—"
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(L10n.tr("会话"), icon: "bubble.left.and.bubble.right") {
                Text(L10n.tr("查找、续接或整理本机 Codex 会话。"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L10n.tr("定位 Codex 会话…"), action: actions.showSessions).disabled(offlinePreview)
            }
            card(L10n.tr("帮助与版本"), icon: "questionmark.circle") {
                HStack {
                    Button(L10n.tr("新手引导与帮助…"), action: actions.showHelp)
                    Button(L10n.tr("关于与更新…"), action: actions.showAbout).disabled(offlinePreview)
                }
            }
            card(L10n.tr("应用"), icon: "power") {
                HStack {
                    Text(L10n.tr("退出后停止菜单栏显示及后台检查。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("退出 Codex Quota"), action: actions.quit)
                }
            }
        }
    }
}
