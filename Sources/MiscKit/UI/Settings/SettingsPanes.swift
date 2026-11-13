import AppKit
import Carbon.HIToolbox
import MiscKitCore
import SwiftUI

/// 统一动作键列表：面板 / 应用 / Hosts 段 / 验证码四组都由 `HotkeyTargets` 报上来，
/// 这里不硬编码"哪个功能能绑键"——新功能只要往 HotkeyTargets 里加一组就自动出现。
struct ShortcutsPane: View {
    @Bindable var settings: AppSettings
    @Environment(\.appLanguage) private var appLanguage
    @State private var hotkeys = HotkeyCenter.shared
    @State private var appIndex = AppIndex.shared
    @State private var permissions = PermissionCenter.shared
    @State private var dispatcher = HotkeyDispatcher.shared
    @State private var recordingKey: String?
    @State private var localError: String?
    @State private var monitor: Any?
    @State private var pickedAppID = ""

    private var groups: [HotkeyTargetGroup] { HotkeyTargets.groups() }

    var body: some View {
        let _ = appLanguage
        Form {
            summonSection

            ForEach(groups.filter { $0.kind != .panel }) { group in
                Section(group.title) {
                    let rows = visibleRows(in: group)
                    ForEach(rows) { target in
                        targetRow(target)
                    }
                    if rows.isEmpty {
                        Text(emptyHint(for: group.kind))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if group.kind.canAddTarget { addAppRow }
                }
            }

            orphanSection
            lastActionSection

            if let localError {
                Text(localError).font(.caption).foregroundStyle(Theme.errorText)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            HostsStore.shared.ensureLoaded()
            if pickedAppID.isEmpty { pickedAppID = appIndex.apps.first?.id ?? "" }
        }
        .onChange(of: appIndex.apps.count) { _, _ in
            if !appIndex.apps.contains(where: { $0.id == pickedAppID }) {
                pickedAppID = appIndex.apps.first?.id ?? ""
            }
        }
        .task(id: settings.summonMode) {
            stopRecording()
            guard settings.summonMode == .doubleTap else { return }
            permissions.refresh()
            // 即使状态显示 denied 也请求一次：IOHIDRequestAccess 会把 MiscKit 加入
            // 系统设置的「输入监控」列表，否则用户在那里找不到它。
            if permissions.inputMonitoring != .granted {
                permissions.promptInputMonitoring()
            }
        }
        .onDisappear { stopRecording() }
    }

    // MARK: 唤起面板

    @ViewBuilder
    private var summonSection: some View {
        Section(L10n.Shortcuts.Section.summon) {
            Picker(L10n.Shortcuts.summonMode, selection: $settings.summonMode) {
                ForEach(SummonMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .id("picker-summon-mode-\(appLanguage.resolved.rawValue)")

            switch settings.summonMode {
            case .combo:
                targetRow(HotkeyTargets.panelTarget)
                // 组合键本身就在上一行显示，标题里不再重复一遍；按钮靠右
                HStack(spacing: Layout.Spacing.m) {
                    Spacer(minLength: 0)
                    Button(L10n.Common.restoreDefault) { settings.summonCombo = .defaultSummon }
                }
            case .doubleTap:
                LabeledContent(L10n.Shortcuts.doubleTap) {
                    HStack(spacing: Layout.Spacing.m) {
                        Picker(L10n.Shortcuts.modifier, selection: $settings.summonDoubleTapModifier) {
                            ForEach(ModifierKey.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .id("picker-modifier-\(appLanguage.resolved.rawValue)")
                        Button(L10n.Common.restoreDefault) { settings.summonDoubleTapModifier = .option }
                    }
                }
                LabeledContent(L10n.Shortcuts.fallbackCombo) {
                    Text(L10n.Shortcuts.fallbackAvailable(settings.summonCombo.displayString))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                inputMonitoringRow
            }
        }
    }

    // MARK: 行

    @ViewBuilder
    private func targetRow(_ target: HotkeyTarget) -> some View {
        LabeledContent {
            HStack(spacing: Layout.Spacing.m) {
                Text(comboText(for: target.key))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 96, alignment: .trailing)
                Button(buttonTitle(for: target.key)) { toggleRecording(target.key) }
                // 唤起键不能清空（面板就唤不起来了），它只有下面那个"恢复默认"。
                if target.key != HotkeyKeys.summon, isBound(target.key) {
                    Button(L10n.Common.clear) { clear(target.key) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                if !target.detail.isEmpty {
                    Text(target.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                // 注册失败的原因就写在行上：用户能立刻知道是"这个键别人占了"。
                if let error = hotkeys.errors[target.key] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.errorText)
                }
            }
        }
    }

    @ViewBuilder
    private var addAppRow: some View {
        LabeledContent(L10n.Shortcuts.add) {
            if appIndex.apps.isEmpty {
                Text(L10n.Shortcuts.loadingApps)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                HStack(spacing: Layout.Spacing.s) {
                    Picker(L10n.Shortcuts.app, selection: $pickedAppID) {
                        ForEach(appIndex.apps) { app in
                            Text(app.name).tag(app.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Button(buttonTitle(for: HotkeyKeys.app(pickedAppID))) {
                        toggleRecording(HotkeyKeys.app(pickedAppID))
                    }
                    .disabled(pickedAppID.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var orphanSection: some View {
        let orphans = HotkeyTargets.orphans(settings: settings)
        if !orphans.isEmpty {
            Section(L10n.Shortcuts.Section.orphans) {
                ForEach(orphans, id: \.key) { orphan in
                    LabeledContent(HotkeyTargets.title(of: orphan.key)) {
                        HStack(spacing: Layout.Spacing.m) {
                            Text(orphan.combo.displayString)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .frame(minWidth: 96, alignment: .trailing)
                            Button(L10n.Common.clear) { settings.hotkeys[orphan.key] = nil }
                        }
                    }
                }
                Text(L10n.Shortcuts.orphansHint)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var lastActionSection: some View {
        if let outcome = dispatcher.lastOutcome, let message = outcome.message {
            Section(L10n.Shortcuts.Section.lastAction) {
                LabeledContent(HotkeyTargets.title(of: outcome.key)) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(outcome.isFailure ? Theme.errorText : Theme.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var inputMonitoringRow: some View {
        if permissions.inputMonitoring == .granted {
            LabeledContent(L10n.Shortcuts.status) {
                Text(L10n.Shortcuts.inputMonitoringGranted(settings.summonDoubleTapModifier.symbol))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: Layout.Spacing.s) {
                Text(L10n.Shortcuts.inputMonitoringMissing(settings.summonCombo.displayString))
                    .font(.caption)
                    .foregroundStyle(Theme.warningText)
                HStack(spacing: Layout.Spacing.m) {
                    Button(L10n.Permissions.request) { permissions.promptInputMonitoring() }
                    Button(L10n.Common.openSystemSettings) { permissions.openSettings(.inputMonitoring) }
                    Button(L10n.Permissions.refresh) { permissions.refresh() }
                }
                Text(L10n.Shortcuts.inputMonitoringHint)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: 状态

    private func visibleRows(in group: HotkeyTargetGroup) -> [HotkeyTarget] {
        if group.kind.listsEveryTarget { return group.targets }
        return group.targets.filter { settings.hotkeys[$0.key] != nil }
    }

    private func emptyHint(for kind: HotkeyGroupKind) -> String {
        switch kind {
        case .panel: return ""
        case .app: return L10n.Shortcuts.Empty.app
        case .hosts: return L10n.Shortcuts.Empty.hosts
        case .otp: return L10n.Shortcuts.Empty.otp
        }
    }

    private func isBound(_ key: String) -> Bool {
        key == HotkeyKeys.summon ? true : settings.hotkeys[key] != nil
    }

    private func comboText(for key: String) -> String {
        if recordingKey == key { return L10n.Shortcuts.pressKeys }
        if key == HotkeyKeys.summon { return settings.summonCombo.displayString }
        return settings.hotkeys[key]?.displayString ?? L10n.Shortcuts.unset
    }

    private func buttonTitle(for key: String) -> String {
        if recordingKey == key { return L10n.Common.cancel }
        return isBound(key) ? L10n.Shortcuts.rerecord : L10n.Shortcuts.record
    }

    // MARK: 录制

    private func toggleRecording(_ key: String) {
        if recordingKey == key {
            stopRecording()
            return
        }
        stopRecording()
        recordingKey = key
        localError = nil
        // 录制期间先放开这个键：否则按回原组合会直接触发动作，录不到按键。
        hotkeys.unregister(key: key)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        guard let key = recordingKey else { return }
        recordingKey = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil

        if key == HotkeyKeys.summon {
            hotkeys.register(key: key, combo: settings.summonCombo)
        } else if let combo = settings.hotkeys[key] {
            hotkeys.register(key: key, combo: combo)
        }
    }

    private func clear(_ key: String) {
        settings.hotkeys[key] = nil
        localError = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }
        guard let key = recordingKey, event.type == .keyDown,
              let combo = HotkeyCombo(event: event)
        else { return }

        if assign(combo, to: key) {
            stopRecording()
        }
    }

    /// 先查内部冲突，再落盘，最后才注册：注册失败要把绑定撤掉，
    /// 否则设置里挂着一个永远按不出来的键。
    private func assign(_ combo: HotkeyCombo, to key: String) -> Bool {
        if let other = HotkeyTargets.conflict(settings: settings, combo: combo, excluding: key) {
            localError = L10n.Shortcuts.conflict(combo.displayString, other)
            return false
        }
        if key == HotkeyKeys.summon {
            settings.summonCombo = combo
            if settings.summonMode == .combo, !hotkeys.register(key: key, combo: combo) {
                localError = hotkeys.errors[key] ?? L10n.Shortcuts.registerFailed(combo.displayString)
                settings.summonCombo = .defaultSummon
                return false
            }
        } else {
            settings.hotkeys[key] = combo
            if !hotkeys.register(key: key, combo: combo) {
                localError = hotkeys.errors[key] ?? L10n.Shortcuts.registerFailed(combo.displayString)
                settings.hotkeys[key] = nil
                return false
            }
        }
        localError = nil
        return true
    }
}

struct PermissionsPane: View {
    @Environment(\.appLanguage) private var appLanguage
    @State private var permissions = PermissionCenter.shared

    var body: some View {
        let _ = appLanguage
        Form {
            row(title: L10n.Permissions.InputMonitoring.title,
                state: permissions.inputMonitoring,
                pane: .inputMonitoring,
                detail: L10n.Permissions.InputMonitoring.detail,
                prompt: permissions.promptInputMonitoring)
            // 文件索引要读桌面/文稿/下载，系统会在首次访问时自己弹授权，这里只给一个回入口。
            // 它的授权状态没有公开 API 可查，所以不显示状态，别假装知道。
            LabeledContent(L10n.Permissions.Files.title) {
                HStack(spacing: Layout.Spacing.m) {
                    Text(L10n.Permissions.Files.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Button(L10n.Common.openSettings) { permissions.openSettings(.filesAndFolders) }
                }
            }
            .help(L10n.Permissions.Files.help)
            Section {
                Button(L10n.Permissions.refresh) { permissions.refresh() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private func row(title: String, state: PermissionState, pane: PermissionPane,
                     detail: String, prompt: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: Layout.Spacing.m) {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(state.isGranted ? Theme.accent : Theme.secondaryText)
                Button(L10n.Permissions.request) { prompt() }
                Button(L10n.Common.openSettings) { permissions.openSettings(pane) }
            }
        }
        .help(detail)
    }
}

/// 喝水 / 站立两套计划的完整设置。改完立刻广播重排，不用等下一次对齐。
struct ReminderSettingsPane: View {
    @Bindable var settings: AppSettings
    @Environment(\.appLanguage) private var appLanguage
    /// 分钟框与时间框共用同一个宽度；两行才会左右都齐。
    private static let inputBoxWidth: CGFloat = 64
    @State private var newBlacklistEntry = ""
    @State private var blacklistError: String?
    /// 新增专注时段的两端时间：初值仍给 09:00–10:00，但可以改
    @State private var focusStart = ReminderSettingsPane.date(hour: 9, minute: 0)
    @State private var focusEnd = ReminderSettingsPane.date(hour: 10, minute: 0)
    @State private var focusError: String?

    private static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
    }

    private func addFocusWindow() {
        let parts = { (d: Date) -> MinuteOfDay in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return MinuteOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
        }
        let start = parts(focusStart), end = parts(focusEnd)
        guard start < end else {
            focusError = L10n.Reminder.Settings.focusInvalid
            return
        }
        let window = MinuteWindow(start: start, end: end)
        guard !settings.reminderFocusWindows.contains(window) else {
            focusError = L10n.Reminder.Settings.focusDuplicate(window.display)
            return
        }
        settings.reminderFocusWindows.append(window)
        focusError = nil
    }

    var body: some View {
        let _ = appLanguage
        Form {
            Section(L10n.Reminder.Settings.screenSection) {
                Text(L10n.Reminder.Settings.screenDesc)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Toggle(L10n.Reminder.Settings.menuCountdown, isOn: $settings.reminderCountdownInMenuBar)
                Button(L10n.Reminder.Settings.preview) { preview() }
            }
            ForEach(ReminderKind.allCases) { kind in
                planSection(kind)
            }
            Section(L10n.Reminder.Settings.dndSection) {
                ForEach(settings.reminderSuppressionBlacklist, id: \.self) { bundleID in
                    LabeledContent(bundleID) {
                        Button(L10n.Common.remove, role: .destructive) {
                            settings.reminderSuppressionBlacklist.removeAll { $0 == bundleID }
                        }
                    }
                }
                HStack {
                    TextField(L10n.Reminder.Settings.blacklistPlaceholder, text: $newBlacklistEntry)
                    Button(L10n.Common.add) {
                        let trimmed = newBlacklistEntry.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else {
                            blacklistError = L10n.Reminder.Settings.emptyBlacklist
                            return
                        }
                        guard !settings.reminderSuppressionBlacklist.contains(trimmed) else {
                            blacklistError = L10n.Reminder.Settings.duplicateBlacklist(trimmed)
                            return
                        }
                        settings.reminderSuppressionBlacklist.append(trimmed)
                        newBlacklistEntry = ""
                        blacklistError = nil
                    }
                }
                .onChange(of: newBlacklistEntry) { _, _ in blacklistError = nil }
                if let error = blacklistError {
                    Text(error).font(.caption).foregroundStyle(Theme.errorText)
                }
                ForEach(Array(settings.reminderFocusWindows.enumerated()), id: \.offset) { index, window in
                    LabeledContent(L10n.Reminder.Settings.focusRow(window.display)) {
                        Button(L10n.Common.remove, role: .destructive) {
                            settings.reminderFocusWindows.remove(at: index)
                        }
                    }
                }
                // 时间不再写死：两个选择器 + 添加，整组靠右
                LabeledContent(L10n.Reminder.Settings.addFocus) {
                    HStack(spacing: Layout.Spacing.s) {
                        DatePicker("", selection: $focusStart, displayedComponents: [.hourAndMinute])
                            .labelsHidden().datePickerStyle(.compact)
                        Text("–").foregroundStyle(Theme.secondaryText)
                        DatePicker("", selection: $focusEnd, displayedComponents: [.hourAndMinute])
                            .labelsHidden().datePickerStyle(.compact)
                        Button(L10n.Common.add) { addFocusWindow() }
                    }
                }
                if let error = focusError {
                    Text(error).font(.caption).foregroundStyle(Theme.errorText)
                }
                Text(L10n.Reminder.Settings.dndFooter)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func planSection(_ kind: ReminderKind) -> some View {
        let plan = settings.plan(for: kind)
        Section(kind.label) {
            Toggle(L10n.Common.enable, isOn: boolBinding(kind, \.enabled))
            minuteField(L10n.Reminder.Settings.interval, kind: kind, \.intervalMinutes, range: 5...240, step: 5)
            timeField(L10n.Reminder.Settings.windowStart, kind: kind, \.windowStart)
            timeField(L10n.Reminder.Settings.windowEnd, kind: kind, \.windowEnd)
            Toggle(L10n.Reminder.Settings.skipWeekends, isOn: boolBinding(kind, \.skipWeekends))
            minuteField(L10n.Reminder.Settings.snooze, kind: kind, \.snoozeMinutes, range: 1...60, step: 1)
            if !plan.windowIsValid {
                Text(L10n.Reminder.Settings.invalidWindow).font(.caption)
                    .foregroundStyle(Theme.errorText)
            }
        }
    }

    private func boolBinding(_ kind: ReminderKind,
                             _ keyPath: WritableKeyPath<ReminderPlan, Bool>) -> Binding<Bool> {
        Binding(get: { settings.plan(for: kind)[keyPath: keyPath] },
                set: { value in set(kind) { plan in plan[keyPath: keyPath] = value } })
    }

    /// 时段两端：和分钟框同一形态——同一个 64pt 圆角输入框 + 右侧独立步进器。
    /// 用带 Date 格式的 TextField 而不是 DatePicker：后者的框宽/内边距由 AppKit 决定，
    /// 和间隔那两行的框怎么调都对不齐。
    private func timeField(_ title: String, kind: ReminderKind,
                           _ keyPath: WritableKeyPath<ReminderPlan, MinuteOfDay>) -> some View {
        LabeledContent(title) {
            HStack(spacing: Layout.Spacing.xs) {
                TextField("", value: binding(kind, keyPath),
                          format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.inputBoxWidth)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: minuteOfDayBinding(kind, keyPath), in: 0...(24 * 60 - 1), step: 1)
                    .labelsHidden()
            }
            .frame(width: SettingsChrome.fieldColumnWidth, alignment: .trailing)
        }
    }

    private func minuteOfDayBinding(_ kind: ReminderKind,
                                    _ keyPath: WritableKeyPath<ReminderPlan, MinuteOfDay>) -> Binding<Int> {
        Binding(get: { settings.plan(for: kind)[keyPath: keyPath].minutes },
                set: { value in
                    set(kind) { plan in plan[keyPath: keyPath] = MinuteOfDay(minutes: value) }
                })
    }

    /// 「可输入 + 可点按」的分钟框：改 240 分钟不该点 47 下。范围沿用原 Stepper 的。
    private func minuteField(_ title: String, kind: ReminderKind,
                             _ keyPath: WritableKeyPath<ReminderPlan, Int>,
                             range: ClosedRange<Int>, step: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: Layout.Spacing.xs) {
                TextField("", value: intBinding(kind, keyPath, in: range, step: step),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.inputBoxWidth)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: intBinding(kind, keyPath, in: range, step: step),
                        in: range, step: step)
                    .labelsHidden()
            }
            .frame(width: SettingsChrome.fieldColumnWidth, alignment: .trailing)
        }
    }

    private func intBinding(_ kind: ReminderKind, _ keyPath: WritableKeyPath<ReminderPlan, Int>,
                            in range: ClosedRange<Int>, step: Int = 1) -> Binding<Int> {
        Binding(get: { settings.plan(for: kind)[keyPath: keyPath] },
                set: { value in
                    set(kind) { plan in plan[keyPath: keyPath] = min(max(value, range.lowerBound),
                                                                    range.upperBound) }
                })
    }

    /// 预览不写统计也不改下一次触发：两个回调都留空，只验形状与点击。
    private func preview() {
        ReminderOverlayController.shared.show(
            kind: .water,
            snoozeMinutes: settings.plan(for: .water).snoozeMinutes,
            onComplete: {},
            onSnooze: {}
        )
    }

    private func set(_ kind: ReminderKind, _ mutate: (inout ReminderPlan) -> Void) {
        var plan = settings.plan(for: kind)
        mutate(&plan)
        settings.setPlan(plan)
        NotificationCenter.default.post(name: .misckitReminderSettingsChanged, object: nil)
    }

    /// MinuteOfDay ↔ DatePicker 用的 Date（只取时分）。
    private func binding(_ kind: ReminderKind,
                         _ keyPath: WritableKeyPath<ReminderPlan, MinuteOfDay>) -> Binding<Date> {
        Binding(get: {
            let minute = settings.plan(for: kind)[keyPath: keyPath]
            return Calendar.current.date(from: DateComponents(hour: minute.hour,
                                                              minute: minute.minute)) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = MinuteOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            set(kind) { $0[keyPath: keyPath] = minute }
        })
    }
}
