import SwiftUI

/// 颜色与玻璃参数的唯一来源。视图层禁止出现字面量色值（`ContrastAuditTests` 拦）。
/// 尺寸/间距/时长见 `Layout`。
@MainActor
public enum Theme {
    public static var accent: Color { Color(nsColor: .controlAccentColor) }

    /// 全项目的玻璃**一律不上色**（2026-10-21 定案）：给玻璃加 tint 会把文字冲掉，
    /// 实测薄荷色选中胶囊让副标题与序号都读不出来。Apple 没给 Glass 的 opacity，
    /// 所以连"轻一点"这个选项都没有 —— 要么纯色要么不加。
    public static let panelGlass: Glass = .regular

    /// 设置窗玻璃底下的那层**中性底衬**：他要"稍微有点透就行"，而 `Glass` 没有 opacity，
    /// 想少透只能垫东西。它不是当年那个"压暗层"（那是把内容往下压），也不许换成材质 ——
    /// 只准出现在 `Components.swift` 的 `ChromeGlass` 里一处，由 `ContrastAuditTests` 钉住。
    public static func chromeBacking(for scheme: ColorScheme) -> Color {
        Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.80 : 0.74)
    }
    /// 系统「降低透明度」时面板的**不透明底**（此时不许用玻璃）。
    /// 它以前也是那层可拧的着色层，那个功能 2026-10-22 删了，这里只剩全不透明这一种用法。
    public static func dimColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .black) : Color(nsColor: .white)
    }

    public static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    /// 玻璃上承载信息的小字（副标题、说明、计数）用的次级色。
    ///
    /// 为什么不用 `secondaryLabelColor`：它是 α0.50/0.55，而 `ContrastAudit` 算下来
    /// 玻璃上任何底衬档位都到不了小字 4.5:1 的门槛（浅色外观需要底衬 α≥1.00，即完全不透明）。
    /// 这里从 `labelColor` 派生，仍然是语义色，不引入任何字面量。
    public static var textBody: Color { Color(nsColor: .labelColor).opacity(0.85) }
    /// 压在玻璃上的**行标签**用满强度 labelColor。
    /// 为什么不用 `textBody`（0.85）：`.glassEffect` 会给包在里面的文字上 vibrancy，
    /// 白色桌面上 0.85 被冲淡到"看着发灰"（他连着两轮说"还是有点底"）。
    /// 玻璃仍然一层、仍然不上色，这里只是不再自己先打八五折。
    public static var rowText: Color { Color(nsColor: .labelColor) }
    /// 只用于装饰与占位（水印、禁用态点缀）。承载信息的文字一律用 `textBody` 以上。
    public static var decorationOnly: Color { Color(nsColor: .tertiaryLabelColor) }
    /// 应用图标角上那个「正在运行」的点。绿色是要一眼看见"它开着"，跟命中高亮无关。
    public static var runningDot: Color { Color(nsColor: .systemGreen) }
    /// 输入框提示词。用系统给 placeholder 的那一档，和 AppKit 自绘时一字不差。
    public static var searchHint: Color { Color(nsColor: .placeholderTextColor) }
    public static var hairline: Color { Color(nsColor: .separatorColor) }
    public static var rowSelection: Color { Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
    public static var tileFill: Color { Color(nsColor: .quaternaryLabelColor) }
    public static var tileText: Color { Color(nsColor: .labelColor) }
    /// 压在强调色上的字：用系统给的"选中态文字色"，不手写白色
    public static var tileTextOnAccent: Color { Color(nsColor: .alternateSelectedControlTextColor) }
    public static var keycapFill: Color { Color(nsColor: .quaternaryLabelColor) }
    public static var keycapText: Color { Color(nsColor: .secondaryLabelColor) }
    public static var chipFill: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.55) }
    public static var chipSelectedText: Color { .white }
    public static var warningText: Color { Color(nsColor: .systemOrange) }
    public static var errorText: Color { Color(nsColor: .systemRed) }
    public static var successText: Color { Color(nsColor: .systemGreen) }
    public static var previewFill: Color { Color(nsColor: .underPageBackgroundColor).opacity(0.35) }
    /// 多选行与批量操作按钮的强调色铺底。
    public static var multiSelectionFill: Color { accent.opacity(0.14) }
    public static var errorFill: Color { Color(nsColor: .systemRed).opacity(0.09) }
    /// 警告态曾经没有自己的铺底色，`OTPPane` 只能写 `warning ? errorFill : errorFill`。
    public static var warningFill: Color { Color(nsColor: .systemOrange).opacity(0.10) }
    public static var successFill: Color { Color(nsColor: .systemGreen).opacity(0.10) }
    /// 侧栏标签**悬浮**那一层灰：比选中浅一档，且永远不上色。
    /// 曾经用 `quaternaryLabelColor.opacity(0.7)`（≈α0.07）—— 白色桌面上完全看不见，
    /// 悬浮态等于没有。tertiary 是这一层能到的下限，仍然只是装饰，不承载文字。
    public static var rowHover: Color { Color(nsColor: .tertiaryLabelColor) }
    /// 设置左栏的两档底色：同一块浅灰（tertiaryLabel 自适应深浅外观），悬浮轻、选中重。
    /// 不与 `rowHover` 合并：那一档叠在提醒浮层的深色卡上，语义不同。
    public static var sidebarHoverFill: Color {
        Color(nsColor: .tertiaryLabelColor).opacity(0.30)
    }
    public static var sidebarSelectedFill: Color {
        Color(nsColor: .tertiaryLabelColor).opacity(0.55)
    }

    /// 玻璃外框与内容卡的投影色：浅色桌面上玻璃边几乎不存在，
    /// 只有描边 + 投影才能把"这是一块面、卡片浮在它上面"读出来。
    public static var chromeShadow: Color { Color(nsColor: .black).opacity(0.18) }
    public static var avatarTop: Color { accent }
    public static var avatarBottom: Color { Color(nsColor: .controlAccentColor).opacity(0.55) }

    // MARK: 屏幕提醒（2026-10-26 取自验收 demo）

    /// 浮层背后的压暗层；厚度由 `ReminderOverlayChrome.scrimOpacity` 钉住。
    public static var reminderScrim: Color {
        Color(nsColor: .black).opacity(ReminderOverlayChrome.scrimOpacity)
    }

    /// 水滴 / 伸展小人的上下两道渐变色。浅色与深色各一组，取自 demo 的 sRGB。
    public static func reminderHue(for kind: ReminderKind,
                                   scheme: ColorScheme) -> (top: Color, bottom: Color) {
        switch (kind, scheme) {
        case (.water, .dark):
            return (Color(red: 0.525, green: 0.639, blue: 0.718),
                    Color(red: 0.310, green: 0.439, blue: 0.529))
        case (.water, _):
            return (Color(red: 0.612, green: 0.722, blue: 0.796),
                    Color(red: 0.373, green: 0.514, blue: 0.608))
        case (.stand, .dark):
            return (Color(red: 0.698, green: 0.576, blue: 0.451),
                    Color(red: 0.490, green: 0.373, blue: 0.263))
        case (.stand, _):
            return (Color(red: 0.765, green: 0.647, blue: 0.525),
                    Color(red: 0.561, green: 0.435, blue: 0.314))
        }
    }

    /// 提醒卡的主按钮：墨色底 + 反色字，和 demo 一致（不用系统强调色）。
    public static func reminderPrimaryFill(for scheme: ColorScheme) -> Color {
        Color(nsColor: .labelColor).opacity(scheme == .dark ? 0.92 : 0.88)
    }

    public static func reminderPrimaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .black) : Color(nsColor: .white)
    }
}

