import MiscKitCore
import AppKit
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, tools, quicklinks, reminders, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.Settings.Tab.general
        case .shortcuts: return L10n.Settings.Tab.shortcuts
        case .tools: return L10n.Settings.Tab.tools
        case .quicklinks: return L10n.Settings.Tab.quicklinks
        case .reminders: return L10n.Settings.Tab.reminders
        case .permissions: return L10n.Settings.Tab.permissions
        case .about: return L10n.Settings.Tab.about
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        // 侧栏六个图标要在同一条左缘线上：`keyboard` / `square.grid.3x2` 的墨迹比别的宽，
        // 居中摆放时会向两侧各溢出一截，看着就是这两行没对齐。换成方形的窄符号。
        case .shortcuts: return "command"
        case .tools: return "square.grid.2x2"
        case .quicklinks: return "link"
        case .reminders: return "drop.halffull"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

/// 面板里点「打开设置…」时要落到哪个页签，由这里转一手：
/// 设置窗口是复用的，直接改路由比让 AppDelegate 认识每个调用方干净。
@MainActor
@Observable
final class SettingsRoute {
    static let shared = SettingsRoute()

    var tab: SettingsTab = .general

    func open(_ tab: SettingsTab) {
        #if DEBUG
        let debugTab = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_SETTINGS_TAB"]
            .flatMap(SettingsTab.init(rawValue:))
        self.tab = debugTab ?? tab
        #else
        self.tab = tab
        #endif
        NotificationCenter.default.post(name: .misckitOpenSettings, object: nil)
    }
}

extension Notification.Name {
    static let misckitOpenSettings = Notification.Name("app.misckit.openSettings")
}

/// 设置窗口尺寸：SwiftUI 的固定 frame 和 AppKit 的 setContentSize 必须同一个来源，
/// 否则一边改了另一边不跟。全部由 `SettingsChrome` 推导，不留第二处常量。
/// 验收长列表时用 `MISCKIT_DEBUG_SETTINGS_HEIGHT` 临时加高。
@MainActor
enum SettingsWindowSize {
    static let width: CGFloat = SettingsChrome.width
    static var height: CGFloat {
        #if DEBUG
        ProcessInfo.processInfo.environment["MISCKIT_DEBUG_SETTINGS_HEIGHT"]
            .flatMap(Double.init).map { CGFloat($0) } ?? SettingsChrome.height
        #else
        SettingsChrome.height
        #endif
    }
}

struct SettingsRootView: View {
    @State private var settings = AppSettings.shared
    @State private var route = SettingsRoute.shared
    @State private var hovered: SettingsTab?
    @State private var a11y = AccessibilityPreferences.shared
    /// 静默更新检查发现新版时，侧栏「关于」行点亮红点（见 UpdateCenter 的静默策略）
    @State private var updates = UpdateCenter.shared
    /// 选中描边跨行滑动用：整栏只有一个选中项，几何配对天然唯一
    @Namespace private var tabPill

    init() {
        #if DEBUG
        if let debugTab = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_SETTINGS_TAB"],
           let tab = SettingsTab(rawValue: debugTab) {
            SettingsRoute.shared.tab = tab
        }
        #endif
    }

    var body: some View {
        let _ = settings.language
        HStack(alignment: .top, spacing: SettingsChrome.contentGutter) {
            sidebar
            contentArea
        }
        // 顶部不留白：内容区自己用滚动边距管上下
        // 左侧用 tabLeading：pill 左缘 10 + 内缩 8 = 图标与红绿灯圆点同在 18 这条线
        .padding(EdgeInsets(top: 0, leading: SettingsChrome.tabLeading,
                            bottom: 0, trailing: SettingsChrome.inset))
        // 铺满窗口，而不是报一个固定尺寸让 AppKit 去撑窗口：
        // 固定 frame 会把窗口顶成"内容 + 标题栏"，玻璃就少了一条。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 标题栏那条顶部安全区会把整块内容往下顶 32pt：窗口高度对，玻璃却铺不满，
        // 顶上就剩一条透明的、红绿灯落在玻璃外面。外框要占满整窗，红绿灯才压在玻璃上。
        .chromeGlass()
        .preferredColorScheme(colorScheme)
        .environment(\.appLanguage, settings.language)
        .environment(\.locale, settings.language.locale)
        // 必须挂在整条链的最外层：挂在内层时标题栏那 32pt 安全区仍然把外框夹住
        .ignoresSafeArea(.container, edges: .top)
        .background(ChromeProbe())
    }

    // MARK: 左栏标签：默认 / 悬浮 / 选中三态

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.tabGap) {
            ForEach(SettingsTab.allCases) { tab in
                tabRow(tab)
            }
            Spacer(minLength: 0)
        }
        .frame(width: SettingsChrome.sidebarWidth, alignment: .leading)
        // 外层顶部不留白，所以这里自己让开红绿灯那一整行
        .padding(.top, SettingsChrome.sidebarTop)
        .padding(.bottom, SettingsChrome.inset)
    }

    private func tabRow(_ tab: SettingsTab) -> some View {
        let state = SettingsChrome.state(selected: route.tab == tab, hovered: hovered == tab)
        let shape = RoundedRectangle(cornerRadius: SettingsChrome.tabRadius, style: .continuous)
        return Button {
            // matchedGeometryEffect 的"飞行"只在 withAnimation 事务里触发；
            // 挂 .animation(value:) 只会让颜色渐变，描边不会跨行移动。
            withAnimation(tabAnimation) { route.tab = tab }
        } label: {
            HStack(spacing: Layout.Spacing.m) {
                Image(systemName: tab.symbol)
                    .font(Type.body)
                    .imageScale(.large)
                    // 左缘对齐，不是居中：图标左缘与红绿灯圆点同在距左 18 那条线（`tabIconLine`）。
                    // 居中会让窄图标往里缩、宽图标向两侧溢出，六个图标就排不成一条线。
                    .frame(width: 18, alignment: .leading)
                    .foregroundStyle(SettingsChrome.iconUsesAccent(state) ? Theme.accent : Theme.rowText)
                Text(tab.title)
                    .font(Type.body)
                    .fontWeight(SettingsChrome.labelWeight(state))
                    .foregroundStyle(Theme.rowText)
                Spacer(minLength: 0)
                // 静默渠道发现新版：只在「关于」行点红点，不弹窗不打扰；
                // 点进去后 AboutPane 有具体版本号与「检查更新…」按钮。
                if tab == .about, let newVersion = updates.availableVersion {
                    Circle()
                        .fill(Theme.errorText)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(L10n.About.newVersion(newVersion))
                }
            }
            .padding(.horizontal, SettingsChrome.tabContentInset)
            .frame(height: SettingsChrome.tabHeight)
            .frame(maxWidth: .infinity)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background(tabHoverFill(state), in: shape)
        // 选中 = 一整块会滑动的浅灰高亮（底 + 描边，无玻璃）：整栏同时只有一个，跟着选中项移动
        .background {
            if SettingsChrome.showsGlassPill(state) {
                SlidingRowHighlight(namespace: tabPill, cornerRadius: SettingsChrome.tabRadius)
            }
        }
        .onHover { inside in
            if inside { hovered = tab } else if hovered == tab { hovered = nil }
        }
        .accessibilityAddTraits(route.tab == tab ? .isSelected : [])
    }

    /// 侧栏行底色只负责悬浮档；选中档由滑动高亮层负责（底色要在同一层里跟着飞）。
    private func tabHoverFill(_ state: SettingsChrome.TabState) -> Color {
        state == .hover ? Theme.sidebarHoverFill : .clear
    }

    // MARK: 右栏：内容直接放在底衬上（没有白卡、没有表头标题）

    private var contentArea: some View {
        content
            // 换页签时新旧两页短暂共存，只做交叉淡入淡出——上浮位移放在设置页不好看
            .id(route.tab)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 上下同一个数：两端留白物理上不可能再不一致
            .contentMargins([.top, .bottom], SettingsChrome.contentEdge, for: .scrollContent)
            // 抵掉 grouped Form 自带的分组框内缩：分组框左边缘与内容区左边缘齐平
            .padding(.horizontal, -SettingsChrome.formInset)
            .animation(tabAnimation, value: route.tab)
    }

    /// 页签节拍：走减少动态效果出口，归零时新旧页直接替换。
    private var tabAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.tabSwitch, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }

    @ViewBuilder
    private var content: some View {
        switch route.tab {
        case .general:
            GeneralPane(settings: settings)
        case .shortcuts:
            ShortcutsPane(settings: settings)
        case .tools:
            FeaturesPane(settings: settings)
        case .quicklinks:
            QuicklinkPane()
        case .reminders:
            ReminderSettingsPane(settings: settings)
        case .permissions:
            PermissionsPane()
        case .about:
            AboutPane()
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct GeneralPane: View {
    @Bindable var settings: AppSettings
    @Environment(\.appLanguage) private var appLanguage
    @State private var previewOn = false

    private func labeled(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value, format: .number.precision(.fractionLength(2)))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
    }

    private func togglePreview() {
        guard let controller = PanelHost.controller else { return }
        if previewOn {
            controller.model.previewPinned = false
            controller.hide()
            previewOn = false
        } else {
            controller.model.previewPinned = true
            controller.show()
            previewOn = true
        }
    }

    /// 钉住是预览的临时状态，必须跟着本页的生命周期退：切页签销毁本页时不退，
    /// 面板会从此不再响应失焦隐藏，`stateIsStale` 也永远不算过期。
    private func releasePreview() {
        guard previewOn else { return }
        previewOn = false
        PanelHost.controller?.model.previewPinned = false
        PanelHost.controller?.hide()
    }

    var body: some View {
        let langKey = appLanguage.resolved.rawValue
        Form {
            // macOS grouped Form 的 Picker / TextField 由 AppKit NSPopUpButton / NSTextField 承载，
            // 只改环境语言不会重刷已有菜单项标题和输入框绑定，按当前解析语言刷新身份以即时重绘。
            Picker(L10n.Settings.languageLabel, selection: $settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .id("picker-language-\(langKey)")
            Picker(L10n.Settings.Appearance.label, selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .id("picker-appearance-\(langKey)")
            Picker(L10n.Settings.Position.label, selection: $settings.position) {
                ForEach(PanelPosition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .id("picker-position-\(langKey)")
            TextField(L10n.Settings.placeholderLabel, text: $settings.placeholderText)
                .id("field-placeholder-\(langKey)")
            Toggle(L10n.Settings.showMenuBar, isOn: $settings.showMenuBarItem)
            Toggle(L10n.Settings.hideOnBlur, isOn: $settings.hideOnBlur)
            Toggle(L10n.Settings.clipboardPrefill, isOn: $settings.prefillFromClipboard)
                .onChange(of: settings.prefillFromClipboard) { _, on in
                    // 关掉就真的停掉轮询：那条每秒唤醒是这个功能唯一的代价
                    if on { ClipboardWatch.shared.start() } else { ClipboardWatch.shared.stop() }
                }
            Toggle(L10n.Settings.launchAtLogin, isOn: $settings.launchAtLogin)

            Section(L10n.Settings.Motion.section) {
                Slider(value: $settings.motionScale, in: Layout.Motion.minScale...Layout.Motion.maxScale) {
                    labeled(L10n.Settings.Motion.scale, settings.motionScale)
                }
                // 按钮靠右：左半边留给说明性文字会显得整页往下坠
                HStack(spacing: Layout.Spacing.m) {
                    Spacer(minLength: 0)
                    Button(previewOn ? L10n.Settings.previewStop : L10n.Settings.previewStart) { togglePreview() }
                    Button(L10n.Common.restoreDefault) { settings.resetAppearanceDefaults() }
                }
            }
            if let error = settings.loginItemError {
                Text(error).font(.caption).foregroundStyle(Theme.errorText)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // 切到别的页签时本页被销毁，预览要跟着停
        .onDisappear { releasePreview() }
    }
}

struct AboutPane: View {
    @Environment(\.appLanguage) private var appLanguage
    @State private var updates = UpdateCenter.shared
    private let iconSide: CGFloat = 88

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    private var appIconImage: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }

    var body: some View {
        let _ = appLanguage
        VStack(spacing: Layout.Spacing.l) {
            Spacer()
            // 直接读取当前 bundle 的 AppIcon.icns，避免 ditto 覆盖安装后 IconServices 缓存返回旧图标；
            // 新矢量母版已内建 3.3px hairline 与投影，降到 88pt 依然清晰，不再手写 overlay 描边。
            Image(nsImage: appIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSide, height: iconSide)
            Text("MiscKit")
                .font(.system(size: 22, weight: .semibold))
            Text(L10n.About.version(version))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            Text(L10n.About.platform)
                .font(.caption)
                .foregroundStyle(Theme.textBody)
            Text(L10n.About.license)
                .font(.caption)
                .foregroundStyle(Theme.textBody)
            // 静默检查发现的新版：给出可见提示 + 手动入口；不自动弹窗（见 QuietUserDriver）
            if let newVersion = updates.availableVersion {
                Text(L10n.About.newVersion(newVersion))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.errorText)
            }
            Button(L10n.Menu.checkUpdates) {
                UpdateCenter.shared.checkForUpdates()
            }
            .controlSize(.regular)
            .buttonStyle(.borderless)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
