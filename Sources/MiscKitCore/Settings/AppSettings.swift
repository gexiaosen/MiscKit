import Foundation
import Observation
import ServiceManagement

public enum PanelPosition: String, CaseIterable, Codable, Sendable {
    case cursorScreen  // 光标所在屏，顶部居中（默认）
    case screenCenter
    case remembered

    public var label: String {
        switch self {
        case .cursorScreen: return L10n.Settings.Position.cursorScreen
        case .screenCenter: return L10n.Settings.Position.screenCenter
        case .remembered: return L10n.Settings.Position.remembered
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return L10n.Settings.Appearance.system
        case .light: return L10n.Settings.Appearance.light
        case .dark: return L10n.Settings.Appearance.dark
        }
    }
}

public enum SummonMode: String, CaseIterable, Codable, Sendable {
    case combo
    case doubleTap

    public var label: String {
        switch self {
        case .combo: return L10n.Settings.Summon.combo
        case .doubleTap: return L10n.Settings.Summon.doubleTap
        }
    }
}

@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults: UserDefaults
    @ObservationIgnored private let syncsGlobalLanguage: Bool
    @ObservationIgnored private var isRevertingLaunchAtLogin = false
    private var storedPlaceholder: String?

    public var language: AppLanguage {
        didSet {
            persist(language, key: .language)
            if syncsGlobalLanguage {
                L10n.currentLanguage = language
            }
        }
    }

    public var summonCombo: HotkeyCombo {
        didSet { persist(summonCombo, key: .summonCombo) }
    }
    public var summonMode: SummonMode {
        didSet { persist(summonMode, key: .summonMode) }
    }
    public var summonDoubleTapModifier: ModifierKey {
        didSet { persist(summonDoubleTapModifier, key: .summonDoubleTapModifier) }
    }
    /// 动作键 → 全局快捷键。键名一律走 `HotkeyKeys`（`app.` / `hosts.` / `otp.` / summon），
    /// 所以这一张表能容纳任何功能报上来的可绑目标，不需要为新功能加字段。
    public var hotkeys: [String: HotkeyCombo] {
        didSet { persist(hotkeys, key: .hotkeys) }
    }
    public var placeholderText: String {
        get { storedPlaceholder ?? L10n.Defaults.placeholder(for: language) }
        set {
            // 任何内置默认文案都不落盘冻结（包括从旧版迁移遗留或 TextField 切换语言失焦回写的默认串），
            // 确保未自定义时始终跟随当前界面语言。
            if Self.isBuiltInDefaultPlaceholder(newValue) {
                storedPlaceholder = nil
                defaults.removeObject(forKey: .placeholder)
                return
            }
            storedPlaceholder = newValue
            defaults.set(newValue, forKey: .placeholder)
        }
    }
    public var position: PanelPosition {
        didSet { persist(position, key: .position) }
    }
    public var appearance: AppearanceMode {
        didSet { persist(appearance, key: .appearance) }
    }
    public var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: .showMenuBar) }
    }
    public var hideOnBlur: Bool {
        didSet { defaults.set(hideOnBlur, forKey: .hideOnBlur) }
    }
    /// 唤起面板时带入"5 秒内刚复制的内容"。关掉就不必再盯剪贴板计数。
    public var prefillFromClipboard: Bool {
        didSet { defaults.set(prefillFromClipboard, forKey: .prefillFromClipboard) }
    }
    /// 「额外压暗」已整条删除（2026-10-22）：面板底衬只剩玻璃一层，
    /// 没有任何"拧一下就更实"的中间层。旧键在 init 里顺手清掉，不让它留在域里。
    /// 动效时长倍率：0.6 干脆 / 1.0 标准 / 1.6 柔和。
    public var motionScale: Double {
        didSet { defaults.set(motionScale, forKey: .motionScale) }
    }
    /// 设置「功能」页关掉的那些工具，存 `ToolID.rawValue`。
    /// 关掉的含义见 `ToolRegistry.isEnabled`：唤醒词、入口行、工作区、动作键一起撤。
    public var disabledTools: [String] {
        didSet { persist(disabledTools, key: .disabledTools) }
    }
    /// 喝水 / 站立两套独立计划，key 是 `ReminderKind.rawValue`。
    public var reminderPlans: [String: ReminderPlan] {
        didSet { persist(reminderPlans, key: .reminderPlans) }
    }
    /// 菜单栏图标右侧的下次触发倒计时
    public var reminderCountdownInMenuBar: Bool {
        didSet { defaults.set(reminderCountdownInMenuBar, forKey: .reminderCountdown) }
    }
    /// 这些 App 在前台时不弹提醒（腾讯会议默认在内）
    public var reminderSuppressionBlacklist: [String] {
        didSet { persist(reminderSuppressionBlacklist, key: .reminderBlacklist) }
    }
    /// 用户自设的免打扰时段
    public var reminderFocusWindows: [MinuteWindow] {
        didSet { persist(reminderFocusWindows, key: .reminderFocusWindows) }
    }
    public private(set) var loginItemError: String?

    public var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin else { return }
            setLaunchAtLogin(launchAtLogin)
        }
    }

    public init(store: UserDefaults = .standard) {
        self.defaults = store
        self.syncsGlobalLanguage = (store === UserDefaults.standard)
        let loadedLanguage = store.decode(AppLanguage.self, key: .language) ?? .system
        self.language = loadedLanguage
        if store === UserDefaults.standard {
            L10n.currentLanguage = loadedLanguage
        }
        self.summonCombo = store.decode(HotkeyCombo.self, key: .summonCombo) ?? .defaultSummon
        self.summonMode = store.decode(SummonMode.self, key: .summonMode) ?? .combo
        self.summonDoubleTapModifier = store.decode(ModifierKey.self, key: .summonDoubleTapModifier) ?? .option
        // 旧键里存的是裸 bundleID，迁移成带前缀的键名。
        // 迁移结果必须当场落盘再删旧键：只改内存的话下次启动又回到旧键名，
        // 而"全部解绑"后新键是空的，会被旧键复活。
        var loaded = store.decode([String: HotkeyCombo].self, key: .hotkeys) ?? [:]
        if loaded.isEmpty, let legacy = store.decode([String: HotkeyCombo].self, key: .appHotkeys) {
            for (key, combo) in legacy { loaded[HotkeyKeys.normalized(key: key)] = combo }
            if let data = try? JSONEncoder().encode(loaded) { store.set(data, forKey: .hotkeys) }
            store.removeObject(forKey: .appHotkeys)
        }
        self.hotkeys = loaded
        let savedPlaceholder = store.string(forKey: .placeholder)
        if let savedPlaceholder, !Self.isBuiltInDefaultPlaceholder(savedPlaceholder) {
            self.storedPlaceholder = savedPlaceholder
        } else {
            self.storedPlaceholder = nil
            if savedPlaceholder != nil {
                store.removeObject(forKey: .placeholder)
            }
        }
        self.position = store.decode(PanelPosition.self, key: .position) ?? .cursorScreen
        self.appearance = store.decode(AppearanceMode.self, key: .appearance) ?? .system
        self.showMenuBarItem = store.object(forKey: .showMenuBar) as? Bool ?? true
        self.hideOnBlur = store.object(forKey: .hideOnBlur) as? Bool ?? true
        self.prefillFromClipboard = store.object(forKey: .prefillFromClipboard) as? Bool ?? true
        store.removeObject(forKey: .glassDim)   // 功能已删，旧值留在域里只会等着被复活
        self.motionScale = store.object(forKey: .motionScale) as? Double ?? Defaults.motionScale
        self.disabledTools = store.decode([String].self, key: .disabledTools) ?? []
        self.reminderPlans = store.decode([String: ReminderPlan].self, key: .reminderPlans) ?? [:]
        self.reminderCountdownInMenuBar = store.object(forKey: .reminderCountdown) as? Bool ?? true
        self.reminderSuppressionBlacklist = store.decode([String].self, key: .reminderBlacklist)
            ?? Defaults.suppressionBlacklist
        self.reminderFocusWindows = store.decode([MinuteWindow].self, key: .reminderFocusWindows) ?? []
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 功能开关的唯一存处。读取点一律走 `ToolRegistry.isEnabled`，视图不许自己查这个数组。
    public func isEnabled(_ tool: ToolID) -> Bool {
        !disabledTools.contains(tool.rawValue)
    }

    public func setEnabled(_ tool: ToolID, _ enabled: Bool) {
        let raw = tool.rawValue
        if enabled {
            disabledTools.removeAll { $0 == raw }
        } else if !disabledTools.contains(raw) {
            disabledTools.append(raw)
        }
    }

    /// 计划没存过就用该种类的默认值；这里做一次归一，调用方不必记得两种默认间隔。
    public func plan(for kind: ReminderKind) -> ReminderPlan {
        reminderPlans[kind.rawValue] ?? ReminderPlan(kind: kind)
    }

    public func setPlan(_ plan: ReminderPlan) {
        reminderPlans[plan.kind.rawValue] = plan
    }

    /// 观感相关的默认值，设置页的"恢复默认"用这一组。
    public enum Defaults {
        public static let motionScale: Double = 1.0
        public static var placeholder: String { L10n.Defaults.placeholder() }
        /// 开会时不该弹提醒，所以腾讯会议默认在黑名单里
        public static let suppressionBlacklist: [String] = ["com.tencent.meeting"]
    }

    public func resetPlaceholder() {
        storedPlaceholder = nil
        defaults.removeObject(forKey: .placeholder)
    }

    private static func isBuiltInDefaultPlaceholder(_ value: String) -> Bool {
        ResolvedLanguage.allCases.contains {
            value == L10n.tr("defaults.placeholder", language: $0)
        }
    }

    public func resetAppearanceDefaults() {
        motionScale = Defaults.motionScale
    }

    public func resetSummonHotkey() {
        summonCombo = .defaultSummon
        summonDoubleTapModifier = .option
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            isRevertingLaunchAtLogin = true
            launchAtLogin = !enabled
            isRevertingLaunchAtLogin = false
        }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}

private extension String {
    static let language = "settings.language.v1"
    static let summonCombo = "settings.summonCombo"
    static let summonMode = "settings.summonMode"
    static let summonDoubleTapModifier = "settings.summonDoubleTapModifier"
    static let appHotkeys = "settings.appHotkeys"
    static let hotkeys = "settings.hotkeys.v1"
    static let placeholder = "settings.placeholderText"
    static let position = "settings.panelPosition"
    static let appearance = "settings.appearance"
    static let showMenuBar = "settings.showMenuBarItem"
    static let hideOnBlur = "settings.hideOnBlur"
    static let prefillFromClipboard = "settings.prefillFromClipboard"
    /// 「额外压暗」已删，只留着这一条是为了 init 里把旧值清干净
    static let glassDim = "settings.glassDim"
    static let motionScale = "settings.motionScale"
    static let disabledTools = "settings.tools.disabled.v1"
    static let reminderPlans = "settings.reminderPlans"
    static let reminderCountdown = "settings.reminderCountdown"
    static let reminderBlacklist = "settings.reminderBlacklist"
    static let reminderFocusWindows = "settings.reminderFocusWindows"
}

private extension UserDefaults {
    func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
