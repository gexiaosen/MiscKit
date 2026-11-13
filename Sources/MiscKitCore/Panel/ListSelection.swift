import Foundation

/// 列表里 ↑↓ 移动选标的唯一口径。
///
/// 为什么收在这里而不是三处各写一遍 `min(max(...))`：可视区只有 8 行而结果上限是 30 行，
/// 选标夹取和"滚不滚得进去"是同一件事的两半，规则分叉过一次就会又出现
/// "选中了看不见的那一行"。空表时旧写法会算出 -1，这里一次性挡掉。
public enum ListSelection {
    /// 移动之后的下标：夹在 `0 ... count-1`；空表原样返回，绝不给出负数。
    public static func move(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return current }
        return min(max(current + delta, 0), count - 1)
    }
}
