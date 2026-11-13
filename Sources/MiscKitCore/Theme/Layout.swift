import CoreGraphics
import Foundation

/// 与 SwiftUI 无关的纯常量，供 AppKit 层直接引用（不依赖主 Actor）。
public enum Layout {
    public enum SpacingValue {
        /// 行的水平内缩：行圆角 = 列表圆角 − 这个值，二者同心
        public static let rowPadding: CGFloat = 10
    }

    public enum Metric {
        /// 期望宽度（点）。2x 屏上 750pt = 1500px
        public static let panelWidth: CGFloat = 750
        public static let panelWidthRatioOnSmallScreen: CGFloat = 0.92
        public static let panelMinWidth: CGFloat = 360
        public static let collapsedHeight: CGFloat = 60
        public static let maxContentHeight: CGFloat = 620
        public static let barHeight: CGFloat = 60
        /// 面板四角统一半径。收起与展开同形，展开只是向下拉伸，角部不跳变。
        /// 2026-10-22 定 20：先按 `barHeight / 2 = 30` 做成完整胶囊，你判"太圆、和其他项目不一致"
        /// （Selected 8/4/6、MoonPal 14/10/12、DentCore 24）。20 是"比系统卡片松一档、但不是胶囊"。
        /// ⚠ 这是观感取值，不是官方数值 —— Apple 没公布过面板/popover 的圆角。
        /// 派生量都跟着它走：文字内缩 = 半径 + 12 = 32，行圆角 = 同心(半径, 8) = 12。
        public static let panelRadius: CGFloat = 20
        public static let panelGap: CGFloat = 10
        /// 让开圆角的文字内缩距离（= 半径 + 一点余量）
        public static let barTextInset: CGFloat = panelRadius + 12
        /// 结果列表在容器内的水平内缩，用于算同心圆
        public static let listInset: CGFloat = 8
        /// 列表底部留白必须与左右内缩一致，选中行才能和面板四角同心
        public static let listBottomInset: CGFloat = listInset
        /// 行间距：算列表视口高度时必须计入，否则最后一行会被 ScrollView 裁掉
        public static let rowSpacing: CGFloat = 2
        /// 行的圆角与容器同心：外层半径 − 内缩距离
        public static let rowCornerRadius: CGFloat = Layout.concentric(panelRadius, inset: listInset)
        /// 序号方块不嵌在行的角上，同心规则不适用：按自身尺寸取四分之一
        public static let tileCornerRadius: CGFloat = tile / 4
        public static let maxVisibleRows: Int = 8
        public static let maxVisibleFileRows: Int = 7
        public static let fileChipsHeight: CGFloat = 36
        public static let fileFooterHeight: CGFloat = 30
        public static let filePaneGap: CGFloat = 8
        public static let fileNoticeHeight: CGFloat = 22
        public static let previewWidth: CGFloat = 286
        /// 分栏预览的最小高度：保证 7 个属性字段不被裁切，行数少时不塌陷
        public static let filePreviewMinHeight: CGFloat = 220
        public static let innerCornerRadius: CGFloat = 10
        public static let topInsetRatio: CGFloat = 0.15
        public static let rowHeight: CGFloat = 52
        public static let rowHeightCompact: CGFloat = 40
        public static let previewBreakpoint: CGFloat = 620
        public static let avatarDiameter: CGFloat = 34
        public static let tile: CGFloat = 32
    }

    /// macOS 同心圆规则：内层半径 = 外层半径 − 内缩距离。
    public static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }

    /// 列表高度只留一个算法：行数、行间距、留白一次算清，视图不得再手工相加。
    public static func listHeight(rows: Int, verticalPadding: CGFloat = Metric.listBottomInset) -> CGFloat {
        let count = max(rows, 0)
        guard count > 0 else { return verticalPadding }
        return CGFloat(count) * Metric.rowHeight
            + CGFloat(count - 1) * Metric.rowSpacing
            + verticalPadding
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    public enum Motion {
        public static let summon: TimeInterval = 0.14
        public static let dismiss: TimeInterval = 0.10
        public static let resize: TimeInterval = 0.18
        public static let reorder: TimeInterval = 0.18
        public static let minScale: Double = 0.5
        public static let maxScale: Double = 2.0

        /// 结果行首次展开的浮入时长；配合 `staggerStep` 递延出级联
        public static let rowReveal: TimeInterval = 0.12
        /// 级联的逐行间隔（只前 8 行参与，长列表不拖延）
        public static let staggerStep: TimeInterval = 0.012
        /// 级联窗口：列表出现后这段时间内新到的行才带延迟，之后的输入直接出现
        public static let staggerWindow: TimeInterval = 0.45
        /// 数字滚动（稿纸结果、OTP 验证码轮换、校准值）
        public static let numericRoll: TimeInterval = 0.22
        /// 设置页签切换
        public static let tabSwitch: TimeInterval = 0.12
        /// 错误抖动的一个节拍（总时长约 4 拍）
        public static let errorShake: TimeInterval = 0.05
        /// ⌘ 数字提示弹出
        public static let shortcutHint: TimeInterval = 0.10
        /// 命令列表 ↔ 工作区切换
        public static let workspaceSwitch: TimeInterval = 0.12
        /// 屏幕提醒卡的入场
        public static let reminderEntrance: TimeInterval = 0.24
        public static let reminderBounce: Double = 0.15
        /// 拖拽落点让位时的回弹
        public static let dropBounce: Double = 0.25
        /// 拖拽时其他行让位的回弹
        public static let shiftBounce: Double = 0.12

        /// 动效节奏：设置页的倍率在这里统一生效，视图层不许自己写时长字面量。
        public static func scaled(_ base: TimeInterval, _ factor: Double) -> TimeInterval {
            base * min(max(factor, minScale), maxScale)
        }
    }
}
