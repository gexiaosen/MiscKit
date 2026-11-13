import AppKit
import Foundation

/// 唤起面板时"把刚复制的东西带进来"的判定规则。纯函数，不碰剪贴板，所以能测。
///
/// 语义来自 uTools：复制完很快唤起 ⇒ 预填搜索框。**5 秒**是这条体验的核心，
/// 因为超过这个窗口，用户手上的东西早就不是他要找的了。
public enum ClipboardPrefill {
    /// 复制之后多久之内唤起才算"刚复制的"
    public static let window: TimeInterval = 5
    /// 超过这个长度就不是"一个要搜的东西"，而是一篇文档；22pt 的输入条塞不下也不该塞
    public static let maxCharacters = 200

    public struct Input: Equatable, Sendable {
        /// 剪贴板里的文本
        public let text: String?
        /// 距今几秒；nil 表示**不知道**（这个计数值第一次被观测，无从判断它何时变的）
        public let age: TimeInterval?
        /// 这份是本 App 自己写的（验证码/会议号/路径/整张稿纸）
        public let isOurOwnCopy: Bool
        /// 输入框是否处于初始态：没有旧文字，也没钉住在某个工作区
        public let barIsInitial: Bool

        public init(text: String?, age: TimeInterval?, isOurOwnCopy: Bool, barIsInitial: Bool) {
            self.text = text
            self.age = age
            self.isOurOwnCopy = isOurOwnCopy
            self.barIsInitial = barIsInitial
        }
    }

    /// 三条"不读内容就能定"的前置条件，唯一一份。
    /// `prefillText` 用它决定要不要付跨进程读的代价，`textToUse` 也用它 —— 两处不会分叉。
    public static func worthReading(age: TimeInterval?, isOurOwnCopy: Bool,
                                    barIsInitial: Bool) -> Bool {
        guard barIsInitial, !isOurOwnCopy, let age else { return false }
        return age >= 0 && age <= window
    }

    /// 返回要带入的文本；nil 表示这次不带（原因不必回传：不带是常态，不该弹任何东西）。
    public static func textToUse(_ input: Input) -> String? {
        guard worthReading(age: input.age, isOurOwnCopy: input.isOurOwnCopy,
                           barIsInitial: input.barIsInitial), let raw = input.text else { return nil }
        // 尾部的换行/空白是复制习惯带来的，不算"多行"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCharacters else { return nil }
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        return trimmed
    }
}

/// 常驻盯 `NSPasteboard.changeCount`，好回答"这份内容是几秒前复制的"。
///
/// 为什么必须轮询（2026-10-22 查证）：macOS **没有**剪贴板最后写入时间的公开 API；
/// `addChangeObserver` / `performChangeNotification` 是协作式的，只有参与者主动调用才通知，
/// 别的 App 复制不会发事件。所以"复制后 5 秒内唤起"这个语义，只有持续对比计数才做得到。
/// 代价说白：多一个每秒唤醒，空闲 CPU 基线要重测。
@MainActor
public final class ClipboardWatch {
    public static let shared = ClipboardWatch()

    /// 轮询间隔。1 秒能把"5 秒窗口"的误差控制在 ±1 秒内，再快就是白烧唤醒。
    public var pollingInterval: TimeInterval = 1

    /// 最近一次观测到剪贴板**内容变化**的时刻。nil = 从没观测到（含启动时的第一次）。
    public private(set) var changedAt: Date?

    /// 上一次看到的计数值
    private var lastCount: Int?
    private var timer: Timer?
    private let pasteboard = NSPasteboard.general

    public init() {}

    /// 挂到 common 运行循环模式：面板拖拽、菜单打开时也应该继续看到变化。
    public func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll(now: Date = Date()) {
        _ = observe(count: pasteboard.changeCount, now: now)
    }

    /// 一次观测。返回 true 表示这次和上一次不同（= 内容刚变了）。
    /// 首次只建立基线、不给时间戳：我们不知道它是何时变的，编一个就等于撒谎。
    @discardableResult
    public func observe(count: Int, now: Date) -> Bool {
        defer { lastCount = count }
        guard let previous = lastCount else { return false }
        guard previous != count else { return false }
        changedAt = now
        return true
    }

    /// 返回要带入的文本；nil 表示这次不带。
    ///
    /// 三个条件（时间窗、归属、是否初始态）**只在这里判一次**，交给 `ClipboardPrefill`：
    /// 调用方不许自己 `guard` 掉——那样"恢复旧输入优先于带入"这条规则就散在两处，
    /// 改一处就会和另一处分叉（2026-10-22 你报的那个冲突正是这么冒出来的）。
    /// 便宜判断在前、读内容在后：跨进程读字符串要等源 App 序列化，
    /// 多数唤起（没刚复制东西）不该为它付时间——唤起预算 ≤100ms，实测基线 36–42ms。
    public func prefillText(barIsInitial: Bool, now: Date = Date()) -> String? {
        let age = changedAt.map { now.timeIntervalSince($0) }
        let isOurOwnCopy = pasteboard.changeCount == ClipboardGuard.shared.lastOwnChangeCount
        guard ClipboardPrefill.worthReading(age: age, isOurOwnCopy: isOurOwnCopy,
                                           barIsInitial: barIsInitial) else { return nil }
        return ClipboardPrefill.textToUse(ClipboardPrefill.Input(
            text: pasteboard.string(forType: .string),
            age: age,
            isOurOwnCopy: isOurOwnCopy,
            barIsInitial: barIsInitial))
    }
}
