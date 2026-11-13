import SwiftUI

/// 玻璃上"这一行被选中"的唯一画法（2026-10-22 定：零铺底方案）。
///
/// 为什么不用灰底：`Theme.rowSelection`（`unemphasizedSelectedContentBackgroundColor`）是
/// **不透明**语义色，八行列表里选中那条就是一块水泥——"输入文字后面板没那么通透"
/// 有一部分就是它。而玻璃上任何色块都会和玻璃打架（上色方案已被两次否决）。
///
/// 所以选中靠三条不依赖单一颜色的线索：方块反白实心、标题加粗、0.5pt 内描边。
/// 放 Core 而不是 UI 层，是为了让这套映射能被单测钉住，也让六处列表共用一份定义。
@MainActor
public enum RowSelection {
    /// 序号/符号方块：选中时实心强调色，未选中时中性半透明底
    public static func tileFill(selected: Bool) -> Color {
        selected ? Theme.accent : Theme.tileFill
    }

    /// 方块上的数字/符号：选中时反白（压在强调色上，中性灰读不出来）
    public static func tileText(selected: Bool) -> Color {
        selected ? Theme.tileTextOnAccent : Theme.tileText
    }

    /// 标题字重：选中加粗一档。11pt 副标题不动，避免整行变宽抖动
    public static func titleWeight(selected: Bool) -> Font.Weight {
        selected ? .semibold : .regular
    }

    /// 内描边：只在选中时可见。0.5pt 与 `hairline` 同源，不额外发明一种线宽
    public static func border(selected: Bool) -> Color {
        selected ? Theme.hairline : .clear
    }

    /// 行背景：永远透明 —— 选中靠下面那层玻璃，不靠铺色
    public static func rowFill(selected: Bool) -> Color { .clear }

    /// 选中行自己那层玻璃。**用 `.clear` 而不是 `.regular`**：面板底衬已经是 `.regular`，
    /// 同种玻璃叠上去几乎看不出差别（2026-10-22 你先判"灰底太水泥"，换成零铺底后又判"太淡"）。
    /// `.clear` 更透、边缘折射更强，才有"这块浮起来一点"的分层感。
    /// ⚠ 一律不上 tint：给玻璃加色会把 11pt 副标题冲掉，这条实测过两次。
    /// 这个数不满意就改这一处：`.regular` 更含蓄，`.clear` 更分明。
    public static let glass: Glass = .clear
}
