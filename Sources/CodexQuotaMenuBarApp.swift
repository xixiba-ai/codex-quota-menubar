import SwiftUI
import AppKit
import Combine

@main
struct CodexQuotaMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = QuotaStore()
    let sessionStore = SessionStore()
    let autoRefreshScheduler = AutoRefreshScheduler()
    let resetForecastStore = ResetForecastStore()
    private var statusItem: NSStatusItem?
    private var languageObservation: AnyCancellable?
    private var stateObservation: AnyCancellable?
    private var autoRefreshObservation: AnyCancellable?
    private var resetForecastObservation: AnyCancellable?
    private var freshnessTimer: AnyCancellable?
    private var activeQuotaRefreshObservation: AnyCancellable?
    private var lastObservedScheduledRefresh: Date?
    private let shortTermItem = NSMenuItem(title: L10n.tr("正在读取额度…"), action: nil, keyEquivalent: "")
    private let longTermItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let freshnessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetForecastItem = NSMenuItem(title: L10n.tr("48 小时重置概率：未启用"), action: nil, keyEquivalent: "")
    private let resetForecastSourceItem = NSMenuItem(title: L10n.tr("第三方估算 · willcodexquotareset.com"), action: nil, keyEquivalent: "")
    private let resetForecastToggleItem = NSMenuItem(title: L10n.tr("开启重置概率预测"), action: nil, keyEquivalent: "")
    private let autoRefreshToggleItem = NSMenuItem(title: L10n.tr("自动刷新额度"), action: nil, keyEquivalent: "")
    private let autoRefreshScheduleItem = NSMenuItem(title: L10n.tr("修改触发时间…"), action: nil, keyEquivalent: "")
    private let autoRefreshTimesItem = NSMenuItem(title: L10n.tr("触发时间：—"), action: nil, keyEquivalent: "")
    private let autoRefreshStatusItem = NSMenuItem(title: L10n.tr("当前状态：关闭"), action: nil, keyEquivalent: "")
    private let lastAutoRefreshItem = NSMenuItem(title: L10n.tr("最近一次触发：—"), action: nil, keyEquivalent: "")
    private let nextAutoRefreshItem = NSMenuItem(title: L10n.tr("下一次计划触发：—"), action: nil, keyEquivalent: "")
    private let lastResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastFailureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pendingRetryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var aboutWindow: NSWindow?
    private var sessionPanel: NSPanel?
    private var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Unit tests must not launch the real CLI or restore scheduled activity.
        guard NSClassFromString("XCTestCase") == nil else { return }
        configureStatusItem()
        languageObservation = AppLanguageStore.shared.$selection.sink { [weak self] _ in
            Task { @MainActor in self?.applyLanguage() }
        }
        stateObservation = store.$state.sink { [weak self] _ in
            Task { @MainActor in self?.renderStatusItem() }
        }
        autoRefreshObservation = autoRefreshScheduler.$state.sink { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.renderAutoRefreshMenu(state)
                if state.lastTriggerTime != self.lastObservedScheduledRefresh {
                    self.lastObservedScheduledRefresh = state.lastTriggerTime
                    if state.lastTriggerResult == .inProgress, state.lastTriggerTime != nil {
                        await self.resetForecastStore.refreshForActiveQuotaRead()
                    }
                }
            }
        }
        resetForecastObservation = resetForecastStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.renderResetForecastMenu() }
        }
        activeQuotaRefreshObservation = NotificationCenter.default.publisher(for: .codexQuotaActiveRefresh)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.resetForecastStore.refreshForActiveQuotaRead() }
            }
        freshnessTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.renderStatusItem()
        }
        Task { await store.start() }
        autoRefreshScheduler.start()
        if !UserDefaults.standard.bool(forKey: "hasShownGettingStarted") {
            showHelp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        freshnessTimer?.cancel()
        store.stop()
        sessionStore.stop()
        autoRefreshScheduler.stop()
        resetForecastStore.stop()
    }

    private func configureStatusItem() {
        let statusItem = self.statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu?.removeAllItems()
        let menu = NSMenu()
        menu.delegate = self
        [shortTermItem, longTermItem, freshnessItem, sourceItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())
        [resetForecastItem, resetForecastSourceItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        resetForecastToggleItem.action = #selector(toggleResetForecast)
        resetForecastToggleItem.target = self
        menu.addItem(resetForecastToggleItem)
        menu.addItem(.separator())
        autoRefreshToggleItem.action = #selector(toggleAutoRefresh)
        autoRefreshToggleItem.target = self
        menu.addItem(autoRefreshToggleItem)
        autoRefreshScheduleItem.action = #selector(editAutoRefreshSchedule)
        autoRefreshScheduleItem.target = self
        menu.addItem(autoRefreshScheduleItem)
        [autoRefreshTimesItem, autoRefreshStatusItem, lastAutoRefreshItem, lastResultItem, lastFailureItem, nextAutoRefreshItem, pendingRetryItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("定位 Codex 会话…"), action: #selector(showSessionBrowser), keyEquivalent: "f").target = self
        menu.addItem(withTitle: L10n.tr("立即刷新"), action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let languageItem = NSMenuItem(title: L10n.tr("语言"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let choices: [(AppLanguage, String)] = [
            (.system, L10n.tr("跟随系统")), (.simplifiedChinese, "简体中文"), (.english, "English")
        ]
        for (language, title) in choices {
            let item = NSMenuItem(title: title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            item.target = self
            item.state = AppLanguageStore.shared.selection == language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(withTitle: L10n.tr("新手引导与帮助…"), action: #selector(showHelp), keyEquivalent: "?").target = self
        menu.addItem(withTitle: L10n.tr("关于与更新…"), action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.tr("退出"), action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        self.statusItem = statusItem
        renderStatusItem()
        renderResetForecastMenu()
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        AppLanguageStore.shared.select(language)
    }

    private func applyLanguage() {
        autoRefreshScheduleItem.title = L10n.tr("修改触发时间…")
        configureStatusItem()
        sessionPanel?.title = L10n.tr("定位 Codex 会话")
        helpWindow?.title = L10n.tr("Codex Quota · 新手引导与帮助")
        aboutWindow?.title = L10n.tr("关于与更新")
    }

    func menuWillOpen(_ menu: NSMenu) { renderStatusItem() }

    private func renderStatusItem() {
        freshnessItem.title = store.freshnessText()
        statusItem?.button?.toolTip = store.freshnessText()
        renderAutoRefreshMenu(autoRefreshScheduler.state)
        guard let snapshot = store.snapshot else {
            let message = store.errorMessage
            statusItem?.button?.title = message == nil ? L10n.tr("读取中…") : L10n.tr("额度不可用")
            shortTermItem.title = message ?? L10n.tr("正在连接 Codex CLI…")
            longTermItem.title = ""
            sourceItem.title = ""
            return
        }

        let isLongTermOnly = snapshot.hasOnlyLongTermWindow
        let shortTermText = isLongTermOnly
            ? "\(snapshot.shortTerm.clampedPercent)% \(TimeFormatter.resetDate(snapshot.shortTerm.resetsAt))"
            : "\(snapshot.shortTerm.clampedPercent)% \(TimeFormatter.remaining(snapshot.shortTerm.resetsAt))"
        statusItem?.button?.title = snapshot.longTerm.map { "\(shortTermText) · \($0.clampedPercent)%" } ?? shortTermText
        if store.freshness() == .stale {
            statusItem?.button?.title = "⚠ " + (statusItem?.button?.title ?? "")
        }
        shortTermItem.title = isLongTermOnly
            ? L10n.tr("长期：剩余 \(snapshot.shortTerm.clampedPercent)% · \(TimeFormatter.fullDate(snapshot.shortTerm.resetsAt)) 重置")
            : L10n.tr("短周期：剩余 \(snapshot.shortTerm.clampedPercent)% · \(TimeFormatter.remaining(snapshot.shortTerm.resetsAt)) 后重置")
        longTermItem.title = snapshot.longTerm.map { L10n.tr("长期：剩余 \($0.clampedPercent)% · \(TimeFormatter.fullDate($0.resetsAt)) 重置") } ?? (isLongTermOnly ? L10n.tr("短周期：当前套餐未提供此额度周期") : L10n.tr("长期：当前套餐未提供此额度周期"))
        freshnessItem.title = store.freshnessText() + " · " + TimeFormatter.dataAge(snapshot.updatedAt)
        statusItem?.button?.toolTip = freshnessItem.title
        sourceItem.title = L10n.tr("更新于 \(snapshot.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) · \(snapshot.localizedSourceDescription)")
    }

    private func renderAutoRefreshMenu(_ state: AutoRefreshState) {
        let statusText = state.autoRefreshEnabled ? L10n.tr("开启") : L10n.tr("关闭")
        autoRefreshToggleItem.title = state.autoRefreshEnabled ? L10n.tr("关闭自动刷新额度") : L10n.tr("开启自动刷新额度")
        autoRefreshToggleItem.state = .off
        autoRefreshTimesItem.title = L10n.tr("触发时间：\(AutoRefreshSchedule.formattedTimeList(state.triggerMinutes))")
        autoRefreshStatusItem.title = L10n.tr("当前状态：\(statusText)")
        lastAutoRefreshItem.title = L10n.tr("最近一次触发：\(formatAutoRefreshDate(state.lastTriggerTime))")
        let result = state.lastTriggerResult?.localizedText ?? L10n.tr("尚未执行")
        let reason = state.lastTriggerReason.map { " · " + $0.localizedText } ?? ""
        lastResultItem.title = L10n.tr("执行结果：\(result)\(reason)")
        lastFailureItem.isHidden = state.lastTriggerResult != .failed
        lastFailureItem.title = L10n.tr("失败原因：\((state.lastFailureKind ?? .unknown).localizedText)")
        pendingRetryItem.isHidden = state.pendingQuotaResetRetryTime == nil || !state.autoRefreshEnabled
        pendingRetryItem.title = L10n.tr("额度重置后重试：\(formatAutoRefreshDate(state.pendingQuotaResetRetryTime))")
        nextAutoRefreshItem.title = L10n.tr("下一次计划触发：\(formatAutoRefreshDate(state.nextTriggerTime))")
    }

    private func formatAutoRefreshDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))
    }

    @objc private func refresh() {
        Task { await store.refresh() }
    }

    private func renderResetForecastMenu() {
        resetForecastToggleItem.title = resetForecastStore.isEnabled ? L10n.tr("关闭重置概率预测") : L10n.tr("开启重置概率预测")
        guard resetForecastStore.isEnabled else {
            resetForecastItem.title = L10n.tr("48 小时重置概率：未启用")
            resetForecastSourceItem.title = L10n.tr("第三方估算 · willcodexquotareset.com")
            return
        }
        guard let forecast = resetForecastStore.forecast else {
            resetForecastItem.title = resetForecastStore.errorMessage ?? L10n.tr("48 小时重置概率：读取中…")
            resetForecastSourceItem.title = L10n.tr("第三方估算 · willcodexquotareset.com")
            return
        }
        let stale = resetForecastStore.errorMessage == nil ? "" : L10n.tr(" · 数据可能已过期")
        resetForecastItem.title = L10n.tr("\(forecast.horizonHours) 小时重置概率：\(forecast.score)%\(stale)")
        resetForecastSourceItem.title = L10n.tr("第三方估算 · 更新于 \(forecast.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) · willcodexquotareset.com")
    }

    @objc private func toggleResetForecast() {
        resetForecastStore.setEnabled(!resetForecastStore.isEnabled)
    }

    @objc private func showSessionBrowser() {
        if let sessionPanel {
            sessionPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.tr("定位 Codex 会话")
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: SessionBrowserView(store: sessionStore))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sessionPanel = panel
    }

    @objc private func toggleAutoRefresh() {
        autoRefreshScheduler.setEnabled(!autoRefreshScheduler.state.autoRefreshEnabled)
    }

    @objc private func showHelp() {
        if let helpWindow {
            helpWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Codex Quota · 新手引导与帮助")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QuotaHelpView(
            store: store,
            openSessions: { [weak self] in self?.showSessionBrowser() },
            dismiss: { [weak window] in window?.close() }
        ))
        window.center()
        helpWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: "hasShownGettingStarted")
    }

    @objc private func showAbout() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 438, height: 290),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.tr("关于与更新")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func editAutoRefreshSchedule() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("修改自动刷新触发时间")
        alert.informativeText = L10n.tr("使用 24 小时制，以英文逗号分隔，例如：06:00, 12:30, 18:00。")
        alert.addButton(withTitle: L10n.tr("保存"))
        alert.addButton(withTitle: L10n.tr("取消"))

        let field = NSTextField(string: AutoRefreshSchedule.formattedTimeList(autoRefreshScheduler.state.triggerMinutes))
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let triggerMinutes = AutoRefreshSchedule.parseTimeList(field.stringValue),
              autoRefreshScheduler.setTriggerMinutes(triggerMinutes) else {
            showInvalidScheduleAlert()
            return
        }
    }

    private func showInvalidScheduleAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("无法保存触发时间")
        alert.informativeText = L10n.tr("请输入有效的 24 小时时间，并用英文逗号分隔，例如：06:00, 12:30, 18:00。")
        alert.addButton(withTitle: L10n.tr("好"))
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
