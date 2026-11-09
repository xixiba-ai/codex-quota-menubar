import SwiftUI
import AppKit
import Combine

@main
struct CodexQuotaMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                // Replace the standard command; only our single Settings window can open.
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.tr("设置…")) { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
#if SETTINGS_PREVIEW
    let store = QuotaStore(dataSource: SettingsPreviewUsageDataSource())
    private let offlinePreview = true
#else
    let store = QuotaStore()
    private let offlinePreview = false
#endif
    let resetReminder = ResetReminderStore()
    let sessionStore = SessionStore()
#if SETTINGS_PREVIEW
    let codexResetMonitor = CodexResetMonitor(client: CodexResetPreviewClient(), notifications: CodexResetPreviewNotifications(), schedulesAutomatically: false)
#else
    let codexResetMonitor = CodexResetMonitor()
#endif
    let autoRefreshScheduler = AutoRefreshScheduler()
    private var statusItem: NSStatusItem?
    private var reminderObservation: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var languageObservation: AnyCancellable?
    private var stateObservation: AnyCancellable?
    private var refreshingObservation: AnyCancellable?
    private var lastManualRefreshAt: Date?
    private var autoRefreshObservation: AnyCancellable?
    private var codexResetObservation: AnyCancellable?
    private var freshnessTimer: AnyCancellable?
    private var lastObservedSuccessfulRefresh: Date?
    private let shortTermItem = NSMenuItem(title: L10n.tr("正在读取额度…"), action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let longTermItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let freshnessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexResetSummaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexResetSourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexResetSeparator = NSMenuItem.separator()
    private var aboutWindow: NSWindow?
    private var sessionPanel: NSPanel?
    private var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Unit tests must not launch the real CLI or restore scheduled activity.
        guard NSClassFromString("XCTestCase") == nil else { return }
        configureStatusItem()
        reminderObservation = resetReminder.$configuration.sink { [weak self] _ in
            Task { @MainActor in self?.renderStatusItem() }
        }
        languageObservation = AppLanguageStore.shared.$selection.sink { [weak self] _ in
            Task { @MainActor in self?.applyLanguage() }
        }
        stateObservation = store.$state.sink { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.renderStatusItem()
                if !self.offlinePreview, case .available(let snapshot) = state {
                    await self.autoRefreshScheduler.receiveQuotaSnapshot(snapshot)
                }
            }
        }
        refreshingObservation = store.$isRefreshing.sink { [weak self] _ in
            Task { @MainActor in self?.renderStatusItem() }
        }
        autoRefreshObservation = autoRefreshScheduler.$state.sink { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if !self.offlinePreview, state.lastTriggerResult == .succeeded,
                   let time = state.lastTriggerTime,
                   time != self.lastObservedSuccessfulRefresh {
                    self.lastObservedSuccessfulRefresh = time
                    await self.store.refresh()
                }
            }
        }
        codexResetObservation = codexResetMonitor.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.renderCodexResetMenu() }
        }
        freshnessTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.renderStatusItem()
            self?.renderCodexResetMenu()
        }
        if offlinePreview {
            // Separate preview bundle ID isolates defaults; no scheduler, CLI, X, or notification startup.
            Task {
                await store.refresh()
                codexResetMonitor.setEnabled(true)
                codexResetMonitor.startIfEnabled()
                renderStatusItem()
                showSettings()
#if SETTINGS_PREVIEW
                if ProcessInfo.processInfo.arguments.contains("--preview-menu") {
                    try? await Task.sleep(for: .milliseconds(700))
                    if let view = settingsWindow?.contentView {
                        statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 30, y: view.bounds.height - 70), in: view)
                    }
                }
#endif
            }
            return
        }
        codexResetMonitor.startIfEnabled()
        Task {
            await store.start()
            // Establish the quota mode before launch compensation can run.
            if case .available(let snapshot) = store.state {
                await autoRefreshScheduler.receiveQuotaSnapshot(snapshot)
            }
            autoRefreshScheduler.start()
        }
        if !UserDefaults.standard.bool(forKey: "hasShownGettingStarted") {
            showHelp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        freshnessTimer?.cancel()
        store.stop()
        sessionStore.stop()
        codexResetMonitor.shutdown()
        autoRefreshScheduler.stop()
    }

    private func configureStatusItem() {
        let statusItem = self.statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu?.removeAllItems()
        let menu = NSMenu()
        menu.delegate = self
        [shortTermItem, resetCreditsItem, longTermItem, freshnessItem, sourceItem, refreshResultItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.autoenablesItems = false
        menu.addItem(codexResetSeparator)
        [codexResetSummaryItem, codexResetSourceItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())
        let sessionsItem = NSMenuItem(title: L10n.tr("定位 Codex 会话…"), action: #selector(showSessionBrowser), keyEquivalent: "f")
        sessionsItem.target = self
        sessionsItem.isEnabled = !offlinePreview
        menu.addItem(sessionsItem)
        let settingsItem = NSMenuItem(title: L10n.tr("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        statusItem.menu = menu
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        self.statusItem = statusItem
        renderStatusItem()
        renderCodexResetMenu()
    }

    private func applyLanguage() {
        configureStatusItem()
        settingsWindow?.title = L10n.tr("Codex Quota · 设置")
        sessionPanel?.title = L10n.tr("定位 Codex 会话")
        helpWindow?.title = L10n.tr("Codex Quota · 新手引导与帮助")
        aboutWindow?.title = L10n.tr("关于与更新")
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Status-item menus do not otherwise activate this accessory application.
        // Request normal activation so macOS can present its system-managed UI.
        NSApp.activate(ignoringOtherApps: true)
        renderStatusItem()
        renderCodexResetMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Give Finder/Dock reopen requests a window to bring forward, including
        // when the user is trying to resolve a Screen Time restriction.
        showSettings()
        return true
    }

    private func renderStatusItem() {
        if store.isRefreshing {
            refreshResultItem.title = L10n.tr("正在读取额度…")
        } else if let error = store.errorMessage {
            refreshResultItem.title = L10n.tr("额度刷新失败：\(error)")
        } else if let date = lastManualRefreshAt {
            refreshResultItem.title = L10n.tr("额度刷新成功 · \(date.formatted(.dateTime.hour().minute().second().locale(L10n.locale)))")
        } else {
            refreshResultItem.title = ""
        }
        refreshResultItem.isHidden = refreshResultItem.title.isEmpty
        refreshResultItem.toolTip = refreshResultItem.title
        freshnessItem.title = store.freshnessText()
        statusItem?.button?.toolTip = store.freshnessText()
        // Clear every prior appearance first, including when reminders are disabled or data disappears.
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        [shortTermItem, longTermItem].forEach { $0.attributedTitle = nil; $0.view = nil; $0.toolTip = nil }
        let now = Date.now
        let tier = ResetReminderPolicy.tier(resetAt: store.snapshot?.longTermResetWindow?.resetsAt,
                                           now: now, configuration: resetReminder.configuration)
        guard let snapshot = store.snapshot else {
            let message = store.errorMessage
            statusItem?.button?.title = message == nil ? L10n.tr("读取中…") : L10n.tr("额度不可用")
            shortTermItem.title = message ?? L10n.tr("正在连接 Codex CLI…")
            resetCreditsItem.isHidden = true
            longTermItem.isHidden = true
            sourceItem.isHidden = true
#if SETTINGS_PREVIEW
            writePreviewAudit()
#endif
            return
        }

        sourceItem.isHidden = false
        resetCreditsItem.isHidden = snapshot.rateLimitResetCredits == nil
        resetCreditsItem.title = ResetCreditsFormatter.summary(snapshot.rateLimitResetCredits)
        let isLongTermOnly = snapshot.hasOnlyLongTermWindow
        longTermItem.isHidden = snapshot.longTerm == nil
        let statusTitle = QuotaMenuBarPresentation.title(snapshot: snapshot,
                                                       resetDate: TimeFormatter.resetDate,
                                                       remaining: TimeFormatter.remaining)
        statusItem?.button?.title = statusTitle
        shortTermItem.title = isLongTermOnly
            ? L10n.tr("长期：剩余 \(snapshot.shortTerm.clampedPercent)% · \(TimeFormatter.fullDate(snapshot.shortTerm.resetsAt)) 重置")
            : L10n.tr("短周期：剩余 \(snapshot.shortTerm.clampedPercent)% · \(TimeFormatter.remaining(snapshot.shortTerm.resetsAt)) 后重置")
        longTermItem.title = snapshot.longTerm.map { L10n.tr("长期：剩余 \($0.clampedPercent)% · \(TimeFormatter.fullDate($0.resetsAt)) 重置") } ?? (isLongTermOnly ? L10n.tr("短周期：当前套餐未提供此额度周期") : L10n.tr("长期：当前套餐未提供此额度周期"))
        freshnessItem.title = store.freshnessText() + " · " + TimeFormatter.dataAge(snapshot.updatedAt)
        statusItem?.button?.toolTip = freshnessItem.title
        let longTermRow = isLongTermOnly ? shortTermItem : longTermItem
        if let deadline = snapshot.longTermResetWindow?.resetsAt, deadline <= now {
            longTermRow.title += " · " + ResetReminderTier.awaitingConfirmation.statusText
        }
        applyReminder(tier, to: longTermRow)
        if resetReminder.configuration.isEnabled, snapshot.longTermResetWindow != nil {
            statusItem?.button?.toolTip = freshnessItem.title + " · " + tier.statusText
        }
        if let color = tier.color, let button = statusItem?.button {
            button.attributedTitle = NSAttributedString(string: statusTitle, attributes: [.foregroundColor: color])
        }
        sourceItem.title = snapshot.localizedSourceDescription
        sourceItem.toolTip = L10n.tr("更新于 \(snapshot.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) · \(snapshot.localizedSourceDescription)")
#if SETTINGS_PREVIEW
        writePreviewAudit()
#endif
    }

#if SETTINGS_PREVIEW
    private func writePreviewAudit() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--preview-audit"), args.indices.contains(index + 1) else { return }
        let rows: [[String: Any]] = statusItem?.menu?.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
            let label = item.view?.subviews.first as? NSTextField
            return ["title": item.title, "action": item.action.map(NSStringFromSelector) ?? "",
                    "enabled": item.isEnabled, "customLabel": label != nil,
                    "labelColor": label?.textColor?.description ?? "default"]
        } ?? []
        let result: [String: Any] = ["rows": rows,
            "commandCount": rows.filter { !($0["action"] as? String ?? "").isEmpty }.count,
            "statusTitle": statusItem?.button?.title ?? "",
            "attributedStatus": statusItem?.button?.attributedTitle.description ?? "",
            "toolTip": statusItem?.button?.toolTip ?? "",
            "remindersEnabled": resetReminder.configuration.isEnabled,
            "redHours": resetReminder.configuration.redHours, "orangeHours": resetReminder.configuration.orangeHours,
            "offline": true]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
    }
#endif

    private func applyReminder(_ tier: ResetReminderTier, to item: NSMenuItem) {
        guard let color = tier.color else { return }
        item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: color])
        item.view = ResetReminderMenuRow(title: item.title, color: color)
        item.toolTip = tier.statusText
    }

    @objc private func refresh() {
        guard !store.isRefreshing else { return }
        Task {
            await store.refresh()
            lastManualRefreshAt = store.errorMessage == nil ? .now : nil
            renderStatusItem()
        }
    }

    private func renderCodexResetMenu() {
        let event = codexResetMonitor.latestEvent
        let hasSummary = event != nil
        codexResetSeparator.isHidden = !hasSummary
        codexResetSummaryItem.isHidden = !hasSummary
        codexResetSourceItem.isHidden = !hasSummary
        if let event {
            let state: String
            if !codexResetMonitor.isEnabled { state = " · " + L10n.tr("监测已关闭") }
            else if codexResetMonitor.failure != nil { state = " · " + L10n.tr("无法更新，显示缓存") }
            else { state = codexResetMonitor.isStale() ? " · " + L10n.tr("来源数据已过期") : "" }
            let date = event.announcedAt.formatted(.dateTime.month().day().locale(L10n.locale))
            codexResetSummaryItem.title = event.label + " · " + date + " · " + event.displaySummary.replacingOccurrences(of: "\n", with: " ").prefix(70) + state
            let lastSuccess = codexResetMonitor.saved.lastSuccessAt.map { $0.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)) } ?? "—"
            codexResetSummaryItem.toolTip = event.announcedAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))
                + "\n" + codexResetMonitor.status() + "\n" + L10n.tr("上次成功：\(lastSuccess)")
                + "\n" + L10n.tr("第三方报告，不代表你的账号已到账；请以实际额度为准。")
            codexResetSourceItem.title = L10n.tr("数据来源：codex-reset.com（第三方）")
            codexResetSourceItem.toolTip = event.safeURL.absoluteString
        }
    }

    @objc func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 690),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Codex Quota · 设置")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QuotaSettingsView(
            store: store, scheduler: autoRefreshScheduler, codexReset: codexResetMonitor,
            reminder: resetReminder, language: .shared,
            actions: QuotaSettingsActions(
                refresh: { [weak self] in self?.refresh() },
                editSchedule: { [weak self] in self?.editAutoRefreshSchedule() },
                showSessions: { [weak self] in self?.showSessionBrowser() },
                showHelp: { [weak self] in self?.showHelp() },
                showAbout: { [weak self] in self?.showAbout() },
                quit: { [weak self] in self?.quit() }), offlinePreview: offlinePreview))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

#if SETTINGS_PREVIEW
/// Compiled only into the separate offline preview bundle. No external data access.
@MainActor
final class SettingsPreviewUsageDataSource: UsageDataSource {
    func fetchUsage() async throws -> CodexUsageSnapshot {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-no-data") { throw UsageDataSourceError.invalidResponse }
        let index = args.firstIndex(of: "--preview-hours")
        let hours = index.flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 12
        let weekly = UsageWindow(remainingPercent: 55, resetsAt: .now.addingTimeInterval(hours * 3600), windowDurationMinutes: 10080)
        return CodexUsageSnapshot(shortTerm: args.contains("--preview-weekly") ? weekly : UsageWindow(remainingPercent: 65, resetsAt: .now.addingTimeInterval(2 * 3600), windowDurationMinutes: 300),
                                  longTerm: args.contains("--preview-weekly") ? nil : weekly,
                                  updatedAt: .now, sourceDescription: "Sample data")
    }
}
#endif
