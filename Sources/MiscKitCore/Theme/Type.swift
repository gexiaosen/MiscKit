import SwiftUI

/// 字号令牌。**视图层不许再写 `.font(.system(size:))`**，只准引用这里 ——
/// 和 `Theme` 管颜色是同一个思路：收口点只有一个，超出的靠单测拦。
///
/// 七档全部落回 macOS 的语义字阶（本机 `NSFont.preferredFont(forTextStyle:)` 实测：
/// title 22 / title2 17 / title3 15 / body 13 / callout 12 / subheadline 11 / caption 10），
/// 与 Apple HIG 公布的规格表逐项一致。**macOS 不支持 Dynamic Type**，所以这些磅值是固定的，
/// 想让用户放大文字只能自建倍率。
///
/// 现状普查：190 处 `.system(size:)` 字面量、15 个不同磅值，其中 55 处
/// （8 / 9 / 9.5 / 10.5 / 11.5 / 14 / 16 / 20）落在官方字阶之外 —— 8/9/9.5 还低于
/// macOS 官方最小值 10pt。收敛目标就是下面这七档。
@MainActor
public enum Type {
    public enum Step: String, CaseIterable, Sendable {
        case display, panel, row, body, label, meta, micro
    }

    /// 语义字阶能覆盖的就用语义，覆盖不到的（圆体、等宽）才回落到显式磅值。
    private static func semantic(_ step: Step) -> Font {
        switch step {
        case .display: return .title
        case .panel: return .title2
        case .row: return .title3
        case .body: return .body
        case .label: return .callout
        case .meta: return .subheadline
        case .micro: return .caption
        }
    }

    /// 只有圆体与等宽需要磅值：SwiftUI 没有 `Font.rounded(...)` 这种链式变体。
    /// 测试与需要拿到磅值的场合用；视图层请引用 `Type.*` 而不是这个数。
    public static func pointSizePublic(_ step: Step) -> CGFloat { pointSize(step) }

    private static func pointSize(_ step: Step) -> CGFloat {
        switch step {
        case .display: return 22
        case .panel: return 17
        case .row: return 15
        case .body: return 13
        case .label: return 12
        case .meta: return 11
        case .micro: return 10
        }
    }

    public static func font(_ step: Step) -> Font { semantic(step) }

    /// 圆体：数字与短标签用它，稿纸结果、⌘ 序号这类"要友好"的位置。
    public static func rounded(_ step: Step) -> Font {
        .system(size: pointSize(step), design: .rounded)
    }

    /// 等宽整段：只给代码/hosts 行这类全 ASCII 且要对齐的内容。
    /// 会跳动的数字**不要**用它，用 `.monospacedDigit()` 挂在任意档位上，
    /// 换字体会让中英基线与字宽错位。
    public static func mono(_ step: Step) -> Font {
        .system(size: pointSize(step), design: .monospaced)
    }

    public static var display: Font { semantic(.display) }
    public static var panel: Font { semantic(.panel) }
    public static var row: Font { semantic(.row) }
    public static var body: Font { semantic(.body) }
    public static var label: Font { semantic(.label) }
    public static var meta: Font { semantic(.meta) }
    public static var micro: Font { semantic(.micro) }

    /// 现状 15 个磅值 → 7 档的归一表。清扫时按这个映射改，别自己就近取整。
    public static func step(forSize size: CGFloat) -> Step {
        switch size {
        case 20...: return .display            // 22 保留；20 并到 display
        case 16..<20: return .panel            // 17 保留；16 并到 panel
        case 14..<16: return .row              // 15 保留；14 并到 row
        case 13..<14: return .body
        case 12..<13: return .label
        case 10.5..<12: return .meta           // 11 保留；10.5 / 11.5 并到 meta
        default: return .micro                 // 10 保留；9.5 / 9 / 8 提到 10（官方最小值）
        }
    }
}
