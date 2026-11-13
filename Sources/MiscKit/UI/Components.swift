import AppKit
import MiscKitCore
import SwiftUI

/// 移除安全区边距，确保内容贴合窗口边框。
final class FullBleedHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// 关于页使用的圆形应用标识。
struct AvatarBadge: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Theme.avatarTop, Theme.avatarBottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: Layout.Metric.avatarDiameter, height: Layout.Metric.avatarDiameter)
            .overlay(
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// 行左侧方块：始终显示功能自己的 SF Symbol。
/// 快捷键序号不再占用方块（`digit` 仍供 ⌘N 提示与无障碍文案使用）。
struct ResultTile: View {
    let symbol: String
    let index: Int
    /// 选中态由 `RowSelection` 统一决定：方块反白实心，不靠整行铺灰底
    var selected = false

    var body: some View {
        RoundedRectangle(cornerRadius: Layout.Metric.tileCornerRadius, style: .continuous)
            .fill(RowSelection.tileFill(selected: selected))
            .frame(width: Layout.Metric.tile, height: Layout.Metric.tile)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? RowSelection.tileText(selected: true)
                                               : Theme.secondaryText)
                    .symbolRenderingMode(.monochrome)
            }
    }

    static func digit(for index: Int) -> String? {
        switch index {
        case 0..<9: return "\(index + 1)"
        case 9: return "0"
        default: return nil
        }
    }
}

struct ResultRow: View {
    let result: ToolResult
    let isSelected: Bool
    let index: Int
    @Environment(\.showsShortcutHints) private var showsShortcutHints
    @Environment(\.appLanguage) private var appLanguage
    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared
    let action: () -> Void

    var body: some View {
        let _ = appLanguage
        Button(action: action) {
            HStack(spacing: Layout.Spacing.m) {
                if let iconURL = result.iconURL {
                    AppIconView(url: iconURL)
                        .overlay(alignment: .bottomTrailing) {
                            if result.isRunning {
                                Circle()
                                    .fill(Theme.runningDot)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                                    .accessibilityHidden(true)
                            }
                        }
                } else {
                    ResultTile(symbol: result.symbol, index: index, selected: isSelected)
                }
                VStack(alignment: .leading, spacing: 2) {
                    highlightedTitle
                        .font(.system(size: 15, weight: RowSelection.titleWeight(selected: isSelected)))
                        .lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let detail = result.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: Layout.Spacing.s)
                trailingAccessory
                    .animation(keycapAnimation, value: showsShortcutHints)
            }
            .padding(.horizontal, Layout.SpacingValue.rowPadding)
            .padding(.vertical, result.detail == nil ? 0 : Layout.Spacing.s)
            .frame(minHeight: Layout.Metric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RowSelection.rowFill(selected: isSelected),
                    in: RoundedRectangle(cornerRadius: Layout.Metric.rowCornerRadius, style: .continuous))
        // 选中态：使用半透明玻璃高亮与方块反白，保持整体通透度。
        .modifier(SelectedRowGlass(selected: isSelected))
        .modifier(RowShortcutModifier(index: index))
        // VoiceOver：整行一条元素。默认合并会把序号方块、来源标签、⌘N 胶囊
        // 全念一遍，用户要在噪声里找真正的信息；这里显式给一条干净的。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(L10n.Launcher.A11y.hint)
        .accessibilityAddTraits(.isButton)
    }

    /// ⌘ 数字提示的出现动画：按住 ⌘ 弹出来，松开瞬收。
    private var keycapAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.shortcutHint, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }

    /// 标题 + 副标题 + 命中的快捷键，顺序与视觉一致。
    private var accessibilityText: String {
        var parts: [String] = [result.title]
        if !result.subtitle.isEmpty { parts.append(result.subtitle) }
        if result.isRunning { parts.append(L10n.Launcher.A11y.running) }
        if let detail = result.detail, !detail.isEmpty { parts.append(detail) }
        if case .copyOTP = result.action {
            parts.append(L10n.Launcher.A11y.copyOTP)
        } else if !result.source.isEmpty {
            parts.append(L10n.Launcher.A11y.source(result.source))
        }
        if let digit = ResultTile.digit(for: index) { parts.append(L10n.Launcher.A11y.shortcut(digit)) }
        if isSelected { parts.append(L10n.Launcher.A11y.selected) }
        return parts.joined(separator: L10n.Launcher.A11y.separator)
    }

    /// 有应用图标时，左侧让位给图标；快捷键提示移到右侧，平时不显示数字，
    /// 按住 ⌘ 才亮起（由启动器注入环境值）。OTP 账户行优先显示实时验证码。
    @ViewBuilder
    private var trailingAccessory: some View {
        if case .copyOTP(let accountID) = result.action,
           let account = OTPStore.shared.accounts.first(where: { $0.id == accountID }) {
            OTPCodeBadge(account: account)
        } else if result.iconURL != nil {
            if showsShortcutHints {
                keycap.transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        } else if !result.source.isEmpty {
            Text(result.source)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var keycap: some View {
        if let digit = ResultTile.digit(for: index) {
            Text("⌘\(digit)")
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.keycapText.opacity(0.8))
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Theme.keycapFill.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    /// 命中片段用强调色，其余保持正文色（参考图里的橙色高亮）。
    private var highlightedTitle: Text {
        let title = result.title
        guard let fragment = result.highlight, !fragment.isEmpty,
              let range = title.range(of: fragment, options: .caseInsensitive) else {
            return Text(title)
        }
        let head = Text(String(title[..<range.lowerBound]))
        let hit = Text(String(title[range])).foregroundStyle(Theme.accent)
        let tail = Text(String(title[range.upperBound...]))
        return Text("\(head)\(hit)\(tail)")
    }
}

/// 启动器结果里的实时 OTP 码；执行时才真正出码，这里只负责显示。
private struct OTPCodeBadge: View {
    let account: OTPAccount
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        let _ = appLanguage
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let code = OTPStore.shared.code(for: account, date: timeline.date)
            HStack(spacing: 5) {
                Text(code ?? "—")
                    .font(Type.row.weight(.semibold).monospacedDigit())
                    .foregroundStyle(code == nil ? Theme.decorationOnly : Theme.rowText)
                if let remaining = OTPStore.shared.secondsRemaining(for: account, date: timeline.date) {
                    Text("\(remaining)s")
                        .font(Type.micro.monospacedDigit())
                        .foregroundStyle(Theme.decorationOnly)
                }
            }
            .accessibilityLabel(L10n.Launcher.A11y.currentOTP)
        }
    }
}

private struct ShowsShortcutHintsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 平时藏起 ⌘1…⌘9 数字，按住 ⌘ 才显示；快捷键本身始终有效。
    var showsShortcutHints: Bool {
        get { self[ShowsShortcutHintsKey.self] }
        set { self[ShowsShortcutHintsKey.self] = newValue }
    }
}

/// ⌘1…⌘9、第 10 行 ⌘0。
struct RowShortcutModifier: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if let digit = ResultTile.digit(for: index) {
            content.keyboardShortcut(KeyEquivalent(Character(digit)), modifiers: .command)
        } else {
            content
        }
    }
}

/// 只有选中那一行才有玻璃层。⚠ 视图树会因此多/少一层，选中项移动时是"跳"而不是形变；
/// 要形变得把整列包进 `GlassEffectContainer` 并给每行 `glassEffectID`，那是另一件事。
struct SelectedRowGlass: ViewModifier {
    let selected: Bool
    /// 各列表的行圆角不一样（稿纸 8、hosts 段 10、hosts 行 6），玻璃层要跟自己那张卡同心
    var cornerRadius: CGFloat = Layout.Metric.rowCornerRadius

    func body(content: Content) -> some View {
        if selected {
            content.glassEffect(RowSelection.glass,
                                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

/// 结果行级联浮入。`delay` 在行出现的那一刻才求值：列表首次展开的一小段时间内
/// 逐行递延，之后的输入与滚动回收都直接出现，不会每敲一个字重演一遍。
/// 时长由调用方按 `motionScale` 与"减少动态效果"算好，这里不碰任何时间字面量。
struct RowReveal: ViewModifier {
    let delay: () -> TimeInterval?
    let duration: TimeInterval
    let offset: CGFloat

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : offset)
            .onAppear {
                guard duration > 0, let delay = delay() else { shown = true; return }
                withAnimation(.easeOut(duration: duration).delay(delay)) { shown = true }
            }
    }
}

/// 跨行滑动的选中高亮：浅灰底 + 0.5pt 描边整块跟着选中项走。
/// 底色放进滑动层里，才不会出现"描边在飞、色块瞬移"的割裂；玻璃只准面板底衬与列表选中行两处，
/// 这里刻意不用玻璃。
struct SlidingRowHighlight: View {
    let namespace: Namespace.ID
    var cornerRadius: CGFloat = Layout.Metric.rowCornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.sidebarSelectedFill)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RowSelection.border(selected: true), lineWidth: 0.5)
            }
            .matchedGeometryEffect(id: "sliding-row-highlight", in: namespace)
    }
}

/// 验收探针：把玻璃外框**实际被排版到的尺寸**打出来。
/// 窗口 frame 对不等于玻璃铺满了——标题栏的顶部安全区会把 SwiftUI 内容整块往下顶，
/// 于是顶上多出一条透明带，红绿灯落在玻璃外面。这条日志就是用来分辨这两件事的。
struct ChromeProbe: View {
    var body: some View {
        GeometryReader { geo in
            // onAppear 量到的是排版前的建议尺寸，会骗人；onGeometryChange 在每次排版后回报
            Color.clear.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                #if DEBUG
                if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
                    NSLog("[settings] chrome=%.0fx%.0f", size.width, size.height)
                }
                #endif
            }
        }
    }
}

/// 设置窗的底衬：一整块**单层** Liquid Glass，不上色。
///
/// 刻意写在这个文件里 —— `ContrastAuditTests` 只允许 `Components.swift` 与
/// `LauncherView.swift` 出现 `.glassEffect(`，所以玻璃不可能在第三个文件里悄悄长出来。
/// 窗口本身必须是非不透明的（见 `AppDelegate.openSettings`），否则玻璃没有桌面可透。
struct ChromeGlass: ViewModifier {
    var cornerRadius: CGFloat = SettingsChrome.radius

    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content.background {
            // 底衬在下、玻璃在上，两层都只做背景：内容不被玻璃包住，
            // 文字与控件就不走玻璃合成通道（vibrancy 会把标签冲成灰）。
            ZStack {
                shape.fill(Theme.chromeBacking(for: scheme))
                Color.clear.glassEffect(Theme.panelGlass, in: shape)
            }
        }
        // 玻璃自己给的边在浅色桌面上会消失，所以补一条 hairline 与一层投影
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: Theme.chromeShadow, radius: 26, y: 10)
    }
}

extension View {
    func chromeGlass(cornerRadius: CGFloat = SettingsChrome.radius) -> some View {
        modifier(ChromeGlass(cornerRadius: cornerRadius))
    }
}
