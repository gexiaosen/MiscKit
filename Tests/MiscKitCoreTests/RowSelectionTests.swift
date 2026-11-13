import SwiftUI
import Testing

@testable import MiscKitCore

/// 选中态这套映射能被钉住的部分。颜色本身好不好看得你眼睛判，
/// 但"选中不许再铺不透明灰底"这条是规则，规则就该有门禁。
@MainActor
@Suite("行选中态")
struct RowSelectionTests {
    @Test("行背景永远透明 —— 这是这套设计的核心")
    func rowFillIsAlwaysClear() {
        #expect(RowSelection.rowFill(selected: true) == .clear)
        #expect(RowSelection.rowFill(selected: false) == .clear)
        #expect(RowSelection.border(selected: false) == .clear, "未选中不该有描边")
        #expect(RowSelection.border(selected: true) != .clear)
    }

    @Test("方块：选中反白实心，未选中回到中性底")
    func tileSwapsFillAndText() {
        #expect(RowSelection.tileFill(selected: true) == Theme.accent)
        #expect(RowSelection.tileFill(selected: false) == Theme.tileFill)
        #expect(RowSelection.tileText(selected: true) == Theme.tileTextOnAccent)
        #expect(RowSelection.tileText(selected: false) == Theme.tileText)
    }

    @Test("标题只加粗一档，副标题不动（整行变宽会抖）")
    func titleWeightMovesOneStepOnly() {
        #expect(RowSelection.titleWeight(selected: true) == .semibold)
        #expect(RowSelection.titleWeight(selected: false) == .regular)
    }

    /// 棘轮：`Theme.rowSelection`（不透明语义色）在源码里的用处数**只准变短**。
    /// 账目：2026-10-22 定零铺底 + 玻璃 pill 时 5 处 → 命令列表先改 4 处 → 其余四处全铺完，收到 0。
    /// 0 意味着 `Theme.rowSelection` 只准作为定义存在，谁再拿它当行铺底就是回退到老问题。
    private let rowSelectionLedgerCeiling = 0

    @Test("Theme.rowSelection 的用处数不得超过登记的上限")
    func rowSelectionUsageRatchet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil) else {
            throw Gate("找不到 Sources，门禁失效就是门禁没跑")
        }
        var count = 0
        var files = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 只数代码：文档注释里当然可以写"为什么不用 Theme.rowSelection"
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.drop(while: { $0 == " " || $0 == "\t" })
                    .starts(with: "//") }
                .joined(separator: "\n")
            count += code.components(separatedBy: "Theme.rowSelection").count - 1
        }
        #expect(files > 40, "只扫到 \(files) 个文件，门禁范围不对")
        #expect(count <= rowSelectionLedgerCeiling,
                "Theme.rowSelection 从 \(rowSelectionLedgerCeiling) 涨到 \(count)：玻璃上的选中请用 RowSelection")
    }

    private struct Gate: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }
}
