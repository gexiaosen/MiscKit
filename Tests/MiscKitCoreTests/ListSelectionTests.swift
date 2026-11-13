import Foundation
import Testing

@testable import MiscKitCore

/// ↑↓ 选标的唯一口径。它管"选到第几条"，可视区只管"画得下几条"——
/// 两边各写一遍夹取规则时，就会出现"选中了看不见的那一行"（2026-10-22 用户实测到的 bug）。
@Suite("列表选标移动")
struct ListSelectionTests {
    @Test("空表不给负下标")
    func emptyListKeepsIndex() {
        let forward = ListSelection.move(current: 0, delta: 1, count: 0)
        let backward = ListSelection.move(current: 5, delta: -1, count: 0)
        #expect(forward == 0, "空表按 ↓ 不该给出 -1 之外的任何值")
        #expect(backward == 5)
    }

    @Test("夹在首尾，越界不逃出")
    func clampsAtBothEnds() {
        #expect(ListSelection.move(current: 0, delta: -1, count: 8) == 0)
        #expect(ListSelection.move(current: 7, delta: 1, count: 8) == 7)
        #expect(ListSelection.move(current: 0, delta: -99, count: 8) == 0)
        #expect(ListSelection.move(current: 0, delta: 99, count: 8) == 7)
    }

    @Test("结果条数缩水后 delta 0 能把旧下标收回区间内")
    func shrinkPullsIndexBack() {
        // 选中第 12 条时继续打字，结果只剩 3 条：旧写法会留下越界下标
        #expect(ListSelection.move(current: 12, delta: 0, count: 3) == 2)
        #expect(ListSelection.move(current: 12, delta: 1, count: 3) == 2)
    }

    @Test("可视 8 行之外的每一条都到得了（这就是必须配滚动跟随的那批下标）")
    func rowsBeyondTheViewportAreReachable() {
        let visible = Layout.Metric.maxVisibleRows      // 8
        let total = 30                                  // rankedResults 的默认上限
        var index = 0
        var visited: Set<Int> = [0]
        for _ in 0..<total {
            index = ListSelection.move(current: index, delta: 1, count: total)
            visited.insert(index)
        }
        #expect(index == total - 1, "一路按到底应停在最后一条，实得 \(index)")
        #expect(visited.count == total, "有 \((total - visited.count)) 条按不到")
        #expect(total > visible, "这条测试的前提是结果能超出可视区")
        // 超出可视区的那些，正是没有滚动跟随就会"选中看不见内容"的范围
        #expect(visited.contains(visible + 1))
    }
}
