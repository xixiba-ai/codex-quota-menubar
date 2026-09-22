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
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()
    let sessionStore = SessionStore()
    let autoRefreshScheduler = AutoRefreshScheduler()
    let resetForecastStore = ResetForecastStore()
    private var statusItem: NSStatusItem?
    private var stateObservation: AnyCancellable?
    private var autoRefreshObservation: AnyCancellable?
    private var resetForecastObservation: AnyCancellable?
    private var activeQuotaRefreshObservation: AnyCancellable?
    private var lastObservedScheduledRefresh: Date?
    private let shortTermItem = NSMenuItem(title: "正在读取额度…", action: nil, keyEquivalent: "")
    private let longTermItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetForecastItem = NSMenuItem(title: "48 小时重置概率：未启用", action: nil, keyEquivalent: "")
    private let resetForecastSourceItem = NSMenuItem(title: "第三方估算 · willcodexquotareset.com", action: nil, keyEquivalent: "")
    private let resetForecastToggleItem = NSMenuItem(title: "开启重置概率预测", action: nil, keyEquivalent: "")
    private let autoRefreshToggleItem = NSMenuItem(title: "自动刷新额度", action: nil, keyEquivalent: "")
    private let autoRefreshScheduleItem = NSMenuItem(title: "修改触发时间…", action: nil, keyEquivalent: "")
    private let autoRefreshTimesItem = NSMenuItem(title: "触发时间：—", action: nil, keyEquivalent: "")
    private let autoRefreshStatusItem = NSMenuItem(title: "当前状态：关闭", action: nil, keyEquivalent: "")
    private let lastAutoRefreshItem = NSMenuItem(title: "最近一次触发：—", action: nil, keyEquivalent: "")
    private let nextAutoRefreshItem = NSMenuItem(title: "下一次计划触发：—", action: nil, keyEquivalent: "")
    private var sessionPanel: NSPanel?
    private var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        stateObservation = store.$state.sink { [weak self] _ in
            self?.renderStatusItem()
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
        Task { await store.start() }
        autoRefreshScheduler.start()
        if !UserDefaults.standard.bool(forKey: "hasShownGettingStarted") {
            showHelp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        sessionStore.stop()
        autoRefreshScheduler.stop()
        resetForecastStore.stop()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        [shortTermItem, longTermItem, sourceItem].forEach {
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
        [autoRefreshTimesItem, autoRefreshStatusItem, lastAutoRefreshItem, nextAutoRefreshItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "定位 Codex 会话…", action: #selector(showSessionBrowser), keyEquivalent: "f").target = self
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "新手引导与帮助…", action: #selector(showHelp), keyEquivalent: "?").target = self
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        self.statusItem = statusItem
        renderStatusItem()
        renderResetForecastMenu()
    }

    private func renderStatusItem() {
        renderAutoRefreshMenu(autoRefreshScheduler.state)
        guard let snapshot = store.snapshot else {
            let message = store.errorMessage
            statusItem?.button?.title = message == nil ? "读取中…" : "额度不可用"
            shortTermItem.title = message ?? "正在连接 Codex CLI…"
            longTermItem.title = ""
            sourceItem.title = ""
            return
        }

        let isLongTermOnly = snapshot.hasOnlyLongTermWindow
        let shortTermText = isLongTermOnly
            ? "\(snapshot.shortTerm.clampedPercent)% \(TimeFormatter.resetDate(snapshot.shortTerm.resetsAt))"
            : "\(snapshot.shortTerm.clampedPercent)% \(TimeFormatter.remaining(snapshot.shortTerm.resetsAt))"
        statusItem?.button?.title = snapshot.longTerm.map { "\(shortTermText) · \($0.clampedPercent)%" } ?? shortTermText
        shortTermItem.title = isLongTermOnly
            ? "长期：剩余 \(snapshot.shortTerm.clampedPercent)% · \(TimeFormatter.fullDate(snapshot.shortTerm.resetsAt)) 重置"
            : "短周期：剩余 \(snapshot.shortTerm.clampedPercent)% · \(TimeFormatter.remaining(snapshot.shortTerm.resetsAt)) 后重置"
        longTermItem.title = snapshot.longTerm.map { "长期：剩余 \($0.clampedPercent)% · \(TimeFormatter.fullDate($0.resetsAt)) 重置" } ?? (isLongTermOnly ? "短周期：当前套餐未提供此额度周期" : "长期：当前套餐未提供此额度周期")
        sourceItem.title = "更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened)) · \(snapshot.sourceDescription)"
    }

    private func renderAutoRefreshMenu(_ state: AutoRefreshState) {
        let statusText = state.autoRefreshEnabled ? "开启" : "关闭"
        autoRefreshToggleItem.title = state.autoRefreshEnabled ? "关闭自动刷新额度" : "开启自动刷新额度"
        autoRefreshToggleItem.state = .off
        autoRefreshTimesItem.title = "触发时间：\(AutoRefreshSchedule.formattedTimeList(state.triggerMinutes))"
        autoRefreshStatusItem.title = "当前状态：\(statusText)"
        lastAutoRefreshItem.title = "最近一次触发：\(formatAutoRefreshDate(state.lastTriggerTime))"
        nextAutoRefreshItem.title = "下一次计划触发：\(formatAutoRefreshDate(state.nextTriggerTime))"
    }

    private func formatAutoRefreshDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    @objc private func refresh() {
        Task { await store.refresh() }
    }

    private func renderResetForecastMenu() {
        resetForecastToggleItem.title = resetForecastStore.isEnabled ? "关闭重置概率预测" : "开启重置概率预测"
        guard resetForecastStore.isEnabled else {
            resetForecastItem.title = "48 小时重置概率：未启用"
            resetForecastSourceItem.title = "第三方估算 · willcodexquotareset.com"
            return
        }
        guard let forecast = resetForecastStore.forecast else {
            resetForecastItem.title = resetForecastStore.errorMessage ?? "48 小时重置概率：读取中…"
            resetForecastSourceItem.title = "第三方估算 · willcodexquotareset.com"
            return
        }
        let stale = resetForecastStore.errorMessage == nil ? "" : " · 数据可能已过期"
        resetForecastItem.title = "\(forecast.horizonHours) 小时重置概率：\(forecast.score)%\(stale)"
        resetForecastSourceItem.title = "第三方估算 · 更新于 \(forecast.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · willcodexquotareset.com"
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "定位 Codex 会话"
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
        window.title = "Codex Quota · 新手引导与帮助"
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

    @objc private func editAutoRefreshSchedule() {
        let alert = NSAlert()
        alert.messageText = "修改自动刷新触发时间"
        alert.informativeText = "使用 24 小时制；以逗号或顿号分隔，例如：06:00、12:30、18:00。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: AutoRefreshSchedule.formattedTimeList(autoRefreshScheduler.state.triggerMinutes))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
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
        alert.messageText = "无法保存触发时间"
        alert.informativeText = "请输入至少一个有效时间，格式例如：06:00、12:30、18:00。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
