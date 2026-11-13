import SwiftUI

/// 设置窗的"外壳"尺寸与标签三态。**决策放 Core**：这些数字一旦散进视图就再也收不回来，
/// 而三态映射错了只会表现为"看不出哪一项被选中"，肉眼验收前必须由单测钉住。
///
/// 观感口径与启动器面板同源：圆角用 `Layout.Metric.panelRadius`，标签 pill 的圆角
/// 用 `Layout.Metric.rowCornerRadius`（= 同心推导），玻璃一律不上色（`ContrastAuditTests` 拦）。
@MainActor
public enum SettingsChrome {
    /// 长方形外框：780×500（≈1.56:1，与系统设置窗同量级；900×520 实测偏大）
    public static let width: CGFloat = 780
    public static let height: CGFloat = 500
    /// 可以缩到的下限：再小内容卡就放不下行高了
    public static let minWidth: CGFloat = 700
    public static let minHeight: CGFloat = 440
    /// 标签与内容卡统一离边距离（示意图第 3 条：18pt）
    public static let inset: CGFloat = 18
    /// 侧栏只装"图标 + 三个汉字"，176 是空转，收到 144
    public static let sidebarWidth: CGFloat = 144
    public static let tabHeight: CGFloat = 36
    public static let tabGap: CGFloat = 6
    /// pill 内图标/文字再内缩：pill 的左边缘才是 18pt 那条线
    public static let tabContentInset: CGFloat = 8
    /// 让开红绿灯：圆点顶在 18pt、直径 12pt，再留 18pt 呼吸 = 48 − 18（外层已给 18）
    public static let trafficLightClear: CGFloat = 30
    /// 系统圆点直径：红绿灯自标定时用，标签左边缘与它对齐
    public static let trafficLightDiameter: CGFloat = 12

    public static var radius: CGFloat { Layout.Metric.panelRadius }
    /// 标签 pill 与外框同心：外层半径 − 内缩
    public static var tabRadius: CGFloat { Layout.Metric.rowCornerRadius }
    /// 内容区**上下共用**的滚动边距：只给一个数，物理上不可能再出现"上面比下面空得多"。
    /// 不能再小：标题栏那条拖拽区占顶部约 28pt，压到它上面第一行就点不动了。
    public static let contentEdge: CGFloat = 24
    /// 侧栏与内容区之间的槽宽。原来是 18，加上 Form 自己的内缩后左空档实测 53pt 太宽
    public static let contentGutter: CGFloat = 10
    /// 标签 pill 的左缘。系统把红绿灯圆点放在距左 10pt（实测），pill 再往里缩 8pt
    /// 正好让**图标与圆点同一条竖线** —— 标签左移、红绿灯右移，两边各走 8pt 相遇。
    public static let tabLeading: CGFloat = 10
    /// 那条共用的对齐线：图标左缘 = pill 左缘 + 内缩 = 圆点左缘 = 18
    public static var tabIconLine: CGFloat { tabLeading + tabContentInset }
    /// grouped Form 自己的分组框内缩（抓图实测 ≈25pt）。用它反向抵掉，
    /// 分组框才与内容区左边缘齐平 —— 抵完不留第二处手工数字。
    public static let formInset: CGFloat = 25
    /// 行右侧那列控件的宽度：数字框、时间框都钉在这一个宽度上，
    /// 否则「间隔」带独立步进器、「时段」自带步进器，两列的输入框就错开了。
    public static let fieldColumnWidth: CGFloat = 96
    /// 内容卡半径 = 外框半径 − 留白（同心推导，与行圆角同一条规则）。
    /// ⚠ 不许与外框同半径：两条一样弯的圆角套在 18pt 的缝里，缝在角上被挤成月牙，
    /// 就是右上/右下那对"同心圆"（他判过难看）。同心之后内层近乎直角，缝看着才均匀。
    public static var cardRadius: CGFloat { Layout.concentric(radius, inset: inset) }
    /// 内容卡宽度由外框、侧栏、两侧内缩推出来，不留第二个常量
    public static var cardWidth: CGFloat { width - inset - sidebarWidth - inset }
    public static var cardHeight: CGFloat { height - inset * 2 }
    public static var sidebarTop: CGFloat { inset + trafficLightClear }

    public enum TabState: Sendable, Equatable {
        case normal, hover, selected
    }

    /// 同一行只可能是一种状态：选中压过悬浮（否则鼠标停在当前项上会看到两种底）。
    public static func state(selected: Bool, hovered: Bool) -> TabState {
        if selected { return .selected }
        return hovered ? .hover : .normal
    }

    /// 只有选中那一行自己垫一层玻璃；悬浮只垫淡灰，默认什么都不垫。
    public static func showsGlassPill(_ state: TabState) -> Bool { state == .selected }
    public static func showsHoverFill(_ state: TabState) -> Bool { state == .hover }
    public static func iconUsesAccent(_ state: TabState) -> Bool { state == .selected }
    public static func labelWeight(_ state: TabState) -> Font.Weight {
        state == .selected ? .semibold : .regular
    }
}
