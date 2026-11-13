import AppKit
import os
import MiscKitCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let hotkeys = HotkeyCenter.shared
    private let dispatcher = HotkeyDispatcher.shared
    private let doubleTap = DoubleTapMonitor.shared
    private var controller: PanelController<LauncherView>!
    private var statusItem: NSStatusItem?
    private var statusButton: NSStatusBarButton?
    private var switchRows: [MenuSwitchRow] = []
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var wakePermissionObserver: NSObjectProtocol?
    private let reminders = ReminderCenter.shared
    private let log = Logger(subsystem: "app.misckit.launcher", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 抢不到锁 = 已经有一个我在跑。热键、面板、UserDefaults 都只能有一个主人，
        // 两边同时活着时"偶现的输入框/placeholder 毛病"全是它们互相踩出来的。
        if case .blockedBy(let holder) = ProcessGuard.claimSingleton() {
            Breadcrumbs.event("app.duplex", ["holder": String(holder)])
            exit(0)
        }
        Breadcrumbs.event("app.launch", [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
        ])
        // 安装新版本时接收分布式通知正常退出，避免依赖 Apple Event 自动化权限。
        DistributedNotificationCenter.default().addObserver(
            forName: .init("app.misckit.quit"), object: Bundle.main.bundleIdentifier, queue: .main) { _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Breadcrumbs.event("app.wake") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Breadcrumbs.event("app.sleep") }
        }
        NSApp.setActivationPolicy(.accessory)
        prewarmMainExecutor()
        #if DEBUG
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_NO_INDEX"] != "1" {
            AppIndex.shared.start()
        }
        #else
        AppIndex.shared.start()
        #endif
        FileIndex.shared.start()
        FileSearchService.shared.prewarmSpotlightAvailability()
        BuiltinTools.registerAll()
        PermissionCenter.shared.refresh()
        // 剪贴板"几秒前复制的"只能靠盯 changeCount 得知（见 ClipboardWatch 的查证注释）
        if settings.prefillFromClipboard { ClipboardWatch.shared.start() }

        controller = PanelController { panel in
            LauncherView(panel: panel, settings: self.settings)
        }
        controller.prewarm()

        #if DEBUG
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OPEN_SETTINGS"] == "1" {
            openSettings()
        }
        #endif
        hotkeys.onAction = { [weak self] key in self?.handleHotkey(key) }
        doubleTap.onTrigger = { [weak self] in self?.controller.toggle() }
        wireHotkeyHandlers()
        applySummonTrigger()
        syncActionHotkeys()
        observeSummonChange()
        observeActionHotkeysChange()
        startPermissionWatch()
        observeMenuBarItemChange()
        observeCountdownSettingChange()
        observeFeatureChange()
        observeLanguageChange()
        applyStatusItemVisibility()
        #if DEBUG
        installDebugTrigger()
        #endif
        startReminders()
        // Sparkle 要求启动完成后再起 updater：菜单/绑定就绪，首次调度也才安全。
        // 静默策略（每日一查、发现新版只标红点）见 UpdateCenter。
        UpdateCenter.shared.start()
    }

    /// 提醒中枢要在状态项装好之后启动：倒计时标题是挂在状态项按钮上的。
    private func startReminders() {
        reminders.start()
        NotificationCenter.default.addObserver(
            forName: .misckitOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }
    }

    // MARK: 快捷键

    private func handleHotkey(_ key: String) {
        let outcome = dispatcher.dispatch(key: key)
        finish(outcome)
    }

    /// 失败要有声音：面板没开时，按错键不给反馈用户会以为键没生效。
    private func finish(_ outcome: HotkeyOutcome) {
        if outcome.isFailure { NSSound.beep() }
        guard let message = outcome.message else { return }
        log.info("hotkey \(outcome.key, privacy: .public) → \(outcome.status == .failed ? "失败" : " ok"): \(message, privacy: .public)")
    }

    private func wireHotkeyHandlers() {
        dispatcher.handlers.summon = { [weak self] in self?.controller.toggle() }
        dispatcher.handlers.launch = { [weak self] in self?.launchApp($0) }
        dispatcher.handlers.writeHosts = { [weak self] in self?.writeHosts(section: $0) }
        dispatcher.handlers.copySecret = { ClipboardGuard.shared.copySecret($0) }
    }

    private func launchApp(_ bundleID: String) {
        guard let app = AppIndex.shared.app(withID: bundleID) else {
            finish(HotkeyOutcome(key: HotkeyKeys.app(bundleID), status: .failed,
                                 message: L10n.Hotkey.appMissing(bundleID)))
            return
        }
        Task { @MainActor in
            do {
                try await ActionDispatcher.perform(.launchApp(url: app.url, appID: app.id))
            } catch {
                self.finish(HotkeyOutcome(key: HotkeyKeys.app(bundleID), status: .failed,
                                          message: L10n.Hotkey.launchAppFailed(app.name, error.localizedDescription)))
            }
        }
    }

    /// 跨段冲突与"外部改过 hosts"一律不自动确认：动作键是在看不见界面的情况下按的，
    /// 这种时候替用户点「确认覆盖」是不该发生的授权。
    private func writeHosts(section id: UUID) {
        let key = HotkeyKeys.hostsSection(id)
        let name = HostsStore.shared.sections.first { $0.id == id }?.name ?? L10n.Hotkey.thisSection
        Task { @MainActor in
            do {
                _ = try await HostsStore.shared.apply()
                self.finish(HotkeyOutcome(key: key, status: .done, message: L10n.Hosts.UI.appliedToast(name)))
            } catch {
                self.finish(HotkeyOutcome(key: key, status: .failed,
                                          message: L10n.Hotkey.hostsWriteFailed(error.localizedDescription)))
            }
        }
    }

    private func syncActionHotkeys() {
        let wanted = settings.hotkeys
        for key in Array(hotkeys.registeredKeys) where key != HotkeyKeys.summon {
            if wanted[key] == nil { hotkeys.unregister(key: key) }
        }
        // 唤起键存在 settings.summonCombo 里，由 applySummonTrigger 负责，不在这儿重复注册。
        for (key, combo) in wanted where key != HotkeyKeys.summon {
            hotkeys.register(key: key, combo: combo)
        }
    }

    #if DEBUG
    private func debugLogHotkeys() {
        guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil else { return }
        let keys = hotkeys.registeredKeys.sorted().joined(separator: ",")
        let error = hotkeys.registrationError ?? "none"
        let monitor = doubleTap.isMonitoring ? 1 : 0
        let comboActive = hotkeys.registeredKeys.contains(HotkeyKeys.summon) ? 1 : 0
        let permission = PermissionCenter.shared.inputMonitoring.rawValue
        FileHandle.standardError.write("hotkeys registered=[\(keys)] error=\(error) mode=\(settings.summonMode.rawValue) comboActive=\(comboActive) doubleTap=\(monitor) inputMonitoring=\(permission)\n".data(using: .utf8)!)
    }
    #endif

    private func observeActionHotkeysChange() {
        withObservationTracking {
            _ = settings.hotkeys
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncActionHotkeys()
                self.observeActionHotkeysChange()
            }
        }
    }

    #if DEBUG
    /// 仅当 MISCKIT_DEBUG=1 时生效：`kill -USR1 <pid>` 等价于按一次唤起键。
    /// 用于在没有辅助功能权限的环境里做延迟测量与截图。
    private func installDebugTrigger() {
        guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_HOTKEY_PATH"] == "1" {
                // 只走真实动作键链路（回调 → 派发器 → 面板），不激活、不钉住：
                // 用来复现"自己开了又自己没了"，钉住会把失焦隐藏这条路堵死。
                self.handleHotkey(HotkeyKeys.summon)
                return
            }
            // 让无边框面板成为 key window，CUA/AX 才能枚举到内容；仅调试构建生效。
            NSApp.activate()
            self.controller.model.previewPinned = true
            self.controller.show()
        }
        source.resume()
        debugSignalSource = source

        // SIGUSR2 = 从 /tmp/misckit-debug-query.txt 读查询并展开面板，结果表打到 stderr
        signal(SIGUSR2, SIG_IGN)
        let inputSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        inputSource.setEventHandler { [weak self] in self?.runDebugQuery() }
        inputSource.resume()
        debugInputSource = inputSource

        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSettings() }
        }
        // 验收用：塞三个合成账户，既看 OTP 工作区的排版，也真走一次 Keychain 写入。
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OTP_SEED"] == "1" {
            OTPDebugSeed.installSyntheticAccounts()
        }
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OTP_UNSEED"] == "1" {
            OTPDebugSeed.removeSyntheticAccounts()
        }
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_CALC_SEED"] == "1" {
            CalcDebugSeed.installSyntheticSheets()
        }
        // 调试辅助：测试「计划已改」通知分发与排程时间展示。
        if let posts = Int(ProcessInfo.processInfo.environment["MISCKIT_DEBUG_RESCHEDULE_POST"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.debugPostReschedules(times: posts)
            }
        }
    }

    /// 每次广播后把菜单栏会显示的那句原文打出来，连同一个格式化后的排程时刻。
    private func debugPostReschedules(times: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        for index in 0...max(0, times) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index)) { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .misckitReminderSettingsChanged, object: nil)
                let scheduled = ReminderKind.allCases.compactMap { kind -> String? in
                    guard let date = self.reminders.nextFireDates[kind] else { return nil }
                    return "\(kind.rawValue)=\(formatter.string(from: date))"
                }.joined(separator: " ")
                let line = "[reschedule-sim] #\(index) title=\"\(self.reminders.countdownText ?? "nil")\" \(scheduled)\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
                guard index == max(0, times) else { return }
                // 跨天那两条只能等真实时段走完才看得见，这里用真实格式化器当场读一遍
                let calendar = Calendar.current
                let tomorrow = calendar.date(byAdding: .day, value: 1,
                                             to: calendar.startOfDay(for: Date()))!
                    .addingTimeInterval(9 * 3600 + 30 * 60)
                let weekday = calendar.date(byAdding: .day, value: 3, to: tomorrow)!
                let probe = "[reschedule-sim] probe 明日=\""
                    + ReminderDisplay.value(now: Date(), next: tomorrow, calendar: calendar)
                    + "\" 跨周末=\"" + ReminderDisplay.value(now: Date(), next: weekday, calendar: calendar)
                    + "\"\n"
                FileHandle.standardError.write(probe.data(using: .utf8)!)

            }
        }
    }

    /// 调试查询：无辅助功能权限也能驱动展开态、核对排序；`MISCKIT_DEBUG_AUTORUN=1` 时执行第一条。
    private func runDebugQuery() {
        controller.show()
        let raw = (try? String(contentsOfFile: "/tmp/misckit-debug-query.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `<empty>` 用来回到收起态截图；空文件仍按原来的 hosts 兜底。
        let query = raw == "<empty>" ? "" : (raw.isEmpty ? "hosts" : raw)
        controller.model.query = query

        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(5)
            while !AppIndex.shared.hasLoaded, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let started = Date()
            let rows = ToolRegistry.shared.rankedResults(for: MatchInput(text: query))
            let elapsed = Date().timeIntervalSince(started) * 1000
            var dump = String(format: "debug query=\"%@\" apps=%ld rows=%ld query=%.2fms\n",
                              query, AppIndex.shared.apps.count, rows.count, elapsed)
            for (index, row) in rows.enumerated() {
                let icon = row.iconURL == nil ? 0 : 1
                dump += "[\(index)] score=\(row.score) prio=\(row.sortPriority) icon=\(icon) "
                    + "src=\(row.source) key=\(row.key) title=\(row.title)\n"
            }
            FileHandle.standardError.write(dump.data(using: .utf8)!)

            if let path = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_CAPTURE_PANEL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.capturePanel(to: path)
                }
            }

            // MISCKIT_DEBUG_FILE_OPEN=1：路径查询直接走真实 .openFile 动作（验收用）
            if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_FILE_OPEN"] == "1",
               case .path(let path) = FileQueryParser(aliases: FileAliasStore.shared.aliases).parse(query) {
                do {
                    try await ActionDispatcher.perform(.openFile(path.url))
                    FileHandle.standardError.write("file open ok: \(path.url.path)\n".data(using: .utf8)!)
                    controller.hide()
                } catch {
                    FileHandle.standardError.write("file open failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                }
            }

            guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG_AUTORUN"] == "1",
                  let first = rows.first else { return }
            do {
                try await ActionDispatcher.perform(first.action)
                controller.hide()
                FileHandle.standardError.write("autorun ok: \(first.title)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("autorun failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }

    /// 验收用：把当前可见的最大窗口（启动器面板）用 cacheDisplay 画成位图。
    /// 玻璃由 Metal 合成，离屏可能没有像素；看布局/文案/行高足够。
    private func capturePanel(to path: String) {
        let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = visible.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }), let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[panel] capture 失败：找不到面板"); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("[panel] capture 失败：写不出 PNG"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            NSLog("[panel] captured %@ (%dx%d) %@", path, rep.pixelsWide, rep.pixelsHigh,
                  NSStringFromRect(window.frame))
        } catch {
            NSLog("[panel] capture 失败：%@", error.localizedDescription)
        }
    }

    private var debugSignalSource: DispatchSourceSignal?
    private var debugInputSource: DispatchSourceSignal?
    #endif

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Breadcrumbs.event("app.terminate")
    }

    /// 启动时预热主执行器环境，确保无窗口期类加载正常。
    private func prewarmMainExecutor() {
        MainActor.assumeIsolated {
            _ = NSApp.currentEvent
            _ = NSApp.mainMenu
        }
    }

    /// 组合键始终注册，双击只是额外加一条：输入监控被系统收走后，⌥Z 仍然能唤起。
    private func applySummonTrigger() {
        hotkeys.register(key: HotkeyKeys.summon, combo: settings.summonCombo)
        if settings.summonMode == .doubleTap,
           PermissionCenter.shared.inputMonitoring == .granted {
            doubleTap.start(modifier: settings.summonDoubleTapModifier)
        } else {
            doubleTap.stop()
        }
        #if DEBUG
        debugLogHotkeys()
        #endif
    }

    private func observeSummonChange() {
        withObservationTracking {
            _ = settings.summonMode
            _ = settings.summonCombo
            _ = settings.summonDoubleTapModifier
            _ = PermissionCenter.shared.inputMonitoring
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applySummonTrigger()
                self.observeSummonChange()
            }
        }
    }

    /// TCC 在登录初期可能还没就绪，授权也可能在 App 运行中才被勾上：
    /// 定时重读一次，权限到位后自动启用双击；组合键始终注册，不受这个状态影响。
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionsIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer

        // 登录后 TCC 就绪通常比进程启动晚一拍；2 秒时强制重放一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshPermissionsIfNeeded(forceReapply: true)
            self?.syncActionHotkeys()
        }
        // 睡眠唤醒后全局事件监视器可能失效，重新挂一次双击；动作键也重试注册。
        wakePermissionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionsIfNeeded(forceReapply: true)
                self?.syncActionHotkeys()
            }
        }
    }

    private func refreshPermissionsIfNeeded(forceReapply: Bool = false) {
        let before = PermissionCenter.shared.inputMonitoring
        PermissionCenter.shared.refresh()
        if forceReapply || PermissionCenter.shared.inputMonitoring != before {
            applySummonTrigger()
        }
    }

    /// 「显示菜单栏图标」改了要当场生效：装上或摘掉状态项，不能等重启。
    private func observeMenuBarItemChange() {
        withObservationTracking {
            _ = settings.showMenuBarItem
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyStatusItemVisibility()
                self.observeMenuBarItemChange()
            }
        }
    }

    /// 「菜单栏显示倒计时」改了要当场生效；分钟级标题不会每秒刷新，不能靠下一次 tick 兜底。
    private func observeCountdownSettingChange() {
        withObservationTracking {
            _ = settings.reminderCountdownInMenuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshCountdown()
                self.observeCountdownSettingChange()
            }
        }
    }

    private func applyStatusItemVisibility() {
        if settings.showMenuBarItem {
            guard statusItem == nil else { return }
            installStatusItem()
        } else if let item = statusItem {
            reminders.onDisplayChanged = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            statusButton = nil
        }
    }

    /// 「功能」页的开关改动不落任何现有键的观察路径，所以这里自己盯：
    /// 菜单栏的条目要跟着增减，不能等到下次重启才对齐。
    private func observeFeatureChange() {
        withObservationTracking {
            _ = settings.disabledTools
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rebuildStatusItem()
                self.observeFeatureChange()
            }
        }
    }

    private func observeLanguageChange() {
        withObservationTracking {
            _ = settings.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                SettingsPaneIndex.shared.syncLanguage(self.settings.language)
                self.rebuildStatusItem()
                self.settingsWindow?.title = L10n.Settings.windowTitle
                self.refreshCountdown()
                self.observeLanguageChange()
            }
        }
    }

    private func rebuildStatusItem() {
        guard let item = statusItem else { return }
        reminders.onDisplayChanged = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusButton = nil
        installStatusItem()
    }

    private func installStatusItem() {
        guard settings.showMenuBarItem else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = menuBarMark()
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L10n.Menu.togglePanel, action: #selector(togglePanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        switchRows = []
        // 「功能」页把提醒整件关掉时这两行一起消失：留着就是「关了还能开」。
        if settings.isEnabled(.reminder) {
            for (title, kind) in [(L10n.Menu.waterReminder, ReminderKind.water), (L10n.Menu.standReminder, .stand)] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let row = MenuSwitchRow(kind: kind,
                                        title: title,
                                        isOn: settings.plan(for: kind).enabled,
                                        target: self,
                                        action: #selector(menuSwitchToggled(_:)))
                row.menuItem = item
                item.view = row
                menu.addItem(item)
                switchRows.append(row)
            }
            menu.addItem(.separator())
        }
        let updateItem = menu.addItem(withTitle: L10n.Menu.checkUpdates, action: #selector(UpdateCenter.checkForUpdates), keyEquivalent: "")
        updateItem.target = UpdateCenter.shared
        let settingsItem = menu.addItem(withTitle: L10n.Menu.settings, action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        let quitItem = menu.addItem(withTitle: L10n.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApp
        if #available(macOS 27.0, *) {
            // 保持纯文字菜单风格，隐藏系统自动附加的标准图标。
            settingsItem.preferredImageVisibility = .hidden
            quitItem.preferredImageVisibility = .hidden
            updateItem.preferredImageVisibility = .hidden
        }
        item.menu = menu
        #if DEBUG
        if let base = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_MENU_CAPTURE"],
           let row = switchRows.first {
            row.debugCapture(to: base, highlighted: false)
            row.debugCapture(to: base.replacingOccurrences(of: ".png", with: "-highlight.png"), highlighted: true)
        }
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
            // 菜单栏看不见也测得了：把展开出来的条目与开关状态打出来
            NSLog("[menu] %@", menu.items.map {
                if $0.isSeparatorItem { return "—" }
                if let row = $0.view as? MenuSwitchRow {
                    return "\($0.title)[\(row.toggle.isOn ? "开" : "关")]"
                }
                return $0.title
            }.joined(separator: " / "))
        }
        #endif
        statusItem = item
        statusButton = item.button
        reminders.onDisplayChanged = { [weak self] in self?.refreshCountdown() }
        refreshCountdown()
    }

    /// logo 原图上不了菜单栏：Template 渲染会把整张图压成单色，白瓦片变成实心色块。
    /// 所以用 Resources/MenuBar/MiscKitMark.png —— 由 Scripts/make-icon-master.swift 同源矢量导出的剪影。
    private func menuBarMark() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MiscKitMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        // 按照系统托盘标准比例缩放，与原生状态栏图标视觉高度保持一致。
        image.size = NSSize(width: 20, height: 14)
        image.accessibilityDescription = "MiscKit"
        return image
    }

    /// 图标右侧挂下次触发倒计时；关掉开关或没有计划时只剩图标。
    private func refreshCountdown() {
        guard let statusButton else { return }
        let text = reminders.isCountdownVisible ? reminders.countdownText : nil
        statusButton.title = text.map { " \($0)" } ?? ""
    }

    @objc private func togglePanel() { controller.toggle() }

    /// 菜单栏直接开关两套提醒：与设置页走同一条路（改 plan → setPlan → 广播重排），
    /// 不然到点还会照弹，看起来就像开关是假的。
    @objc private func menuSwitchToggled(_ sender: MenuToggle) {
        guard let kind = switchRows.first(where: { $0.toggle === sender })?.kind else { return }
        toggleReminder(kind)
        // 点标题也能切（走的也是这条 action），所以状态以 plan 为准重新落一次
        sender.isOn = settings.plan(for: kind).enabled
    }

    private func toggleReminder(_ kind: ReminderKind) {
        var plan = settings.plan(for: kind)
        plan.enabled.toggle()
        settings.setPlan(plan)
        NotificationCenter.default.post(name: .misckitReminderSettingsChanged, object: nil)
    }

    // 开关状态每次展开菜单现读，别让它停留在打开菜单栏那一刻的值
    func menuNeedsUpdate(_ menu: NSMenu) {
        for row in switchRows {
            row.toggle.isOn = settings.plan(for: row.kind).enabled
        }
    }

    // 自定义 view 的行 AppKit 不画高亮，得自己跟着菜单的选中项走（鼠标和键盘都走这里）
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in switchRows {
            row.isHighlighted = row.menuItem === item
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        for row in switchRows { row.isHighlighted = false }
    }

    #if DEBUG
    /// 验收用：`MISCKIT_DEBUG_CAPTURE=/tmp/x.png` 把设置窗画成位图。
    /// 走 `cacheDisplay` 而不是 `screencapture` —— 前者是视图自己画，不需要屏幕录制权限。
    /// ⚠ 已知局限：Liquid Glass 由 Metal 合成，离屏可能没有像素，抓到的是"去掉玻璃"的那层。
    private func captureSettingsIfNeeded(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_CAPTURE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSLog("[settings] capture 失败：拿不到位图上下文"); return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                NSLog("[settings] capture 失败：写不出 PNG"); return
            }
            NSLog("[settings] captured %@ (%dx%d)", path, rep.pixelsWide, rep.pixelsHigh)
        }
    }
    #endif

    /// 红绿灯对齐标签：圆点左缘与图标左缘同一条线（`SettingsChrome.inset`），自身上=左。
    ///
    /// ⚠ 只能改 frame，**不能把按钮搬进自建容器**：标准窗口按钮一旦离开原标题栏视图，
    /// AppKit 就不再把命中转给它 —— 上一版正是这样把三个按钮点没了的。
    /// 偏移量按按钮实际尺寸自标定（bounds 14×14、圆点 12、内缩 1pt），不写死数字。
    private func alignTrafficLights(in window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let bar = close.superview else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3 else { return }
        let pitch = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.minX : 20
        let hInset = (buttons[0].frame.width - SettingsChrome.trafficLightDiameter) / 2
        let vInset = (buttons[0].frame.height - SettingsChrome.trafficLightDiameter) / 2
        let x = SettingsChrome.inset - hInset
        let y = bar.bounds.height - SettingsChrome.inset - SettingsChrome.trafficLightDiameter - vInset
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(x: x + CGFloat(index) * pitch, y: y))
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
            let hit = bar.hitTest(NSPoint(x: SettingsChrome.inset + 6,
                                          y: y + buttons[0].frame.height / 2))
            NSLog("[settings] lights 圆点左上=(%.1f, %.1f) 命中=%@", x + hInset,
                  bar.bounds.height - y - vInset - SettingsChrome.trafficLightDiameter,
                  hit is NSButton ? "按钮（点得到）" : "空（点不到！）")
        }
        #endif
    }

    @objc private func openSettings() {
        // accessory 应用没有主菜单，showSettingsWindow: 没有接收者；自建窗口才能稳定打开。
        if settingsWindow == nil {
            // 不能用 NSWindow(contentViewController:)：那条路会把 hosting view 钉到
            // contentLayoutRect（实测 900×488），标题栏那 32pt 永远留给透明背景，
            // 玻璃外框就少一条，红绿灯落在玻璃外面看着像"又加了一层透明的"。
            // 直接把铺满安全区的 hosting view 当 contentView，玻璃才吃满整窗。
            let hosting = FullBleedHostingView(rootView: SettingsRootView())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                      width: SettingsWindowSize.width,
                                                      height: SettingsWindowSize.height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                              .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = L10n.Settings.windowTitle
            // 外框那层 Liquid Glass 得有桌面可透：标题栏透明、窗口不许不透明、
            // 也不要那条分隔线（内容卡自己带描边）。红绿灯位置保持系统默认。
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.delegate = self
            window.contentMinSize = NSSize(width: SettingsChrome.minWidth, height: SettingsChrome.minHeight)
            window.center()
            alignTrafficLights(in: window)
            #if DEBUG
            if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
                // 验收探针：fullSizeContentView 没落地时，窗口会比内容高出一条标题栏，
                // 红绿灯就落在玻璃外面（看着像"上面又加了一层透明的"）。
                let f = window.frame, c = window.contentLayoutRect
                NSLog("[settings] frame=%.0fx%.0f layout=%.0fx%.0f mask=%d",
                      f.width, f.height, c.width, c.height, window.styleMask.rawValue)
            }
            captureSettingsIfNeeded(window)
            #endif
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 设置窗关掉时预览的钉住必须一起退：否则面板从此不再响应失焦隐藏，
    /// `stateIsStale` 也永远不算过期。（切页签那条路由由 GeneralPane.onDisappear 管）
    func windowWillClose(_ notification: Notification) {
        guard controller.model.previewPinned else { return }
        controller.model.previewPinned = false
        controller.hide()
    }
}
