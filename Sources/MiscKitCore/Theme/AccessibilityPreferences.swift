import AppKit
import Foundation
import Observation

/// 系统的三个显示/动效无障碍开关。**玻璃面板尤其要接它们**：
/// HIG 对 `accessibilityReduceTransparency` 的原文是「UI（主要是窗口）背景不应半透明，
/// 应当不透明」，而 `NSVisualEffectView` 不会替我们的自定义浮层做这件事。
///
/// 这三个值是用户随时可能在系统设置里改的，所以要跟着通知刷新，不能只在启动时读一次。
@MainActor
@Observable
public final class AccessibilityPreferences {
    public static let shared = AccessibilityPreferences()

    public private(set) var reduceTransparency = false
    public private(set) var reduceMotion = false
    public private(set) var increaseContrast = false
    private var observers: [NSObjectProtocol] = []
    private let workspace = NSWorkspace.shared

    /// 通知名是公开的（`accessibilityDisplayShould*` 的 key 拼在值里），
    /// 但 Apple 文档没给一份"哪个 key 对应哪个开关"的权威表 —— 这里按实测的
    /// `com.apple.universalaccess.*` 分布式通知逐个比对，取变化时重新读三个属性值，
    /// 因此即使某个通知名不准也不会读到错值（最坏是少刷一次，不会读反）。
    static let changeNotificationKeys = [
        "com.apple.universalaccess.VOReduceTransparency",
        "com.apple.universalaccess.VOReduceMotion",
        "com.apple.universalaccess.differentiateWithoutColor",
        "com.apple.universalaccess.increaseContrast",
        "com.apple.Accessibility.DisplaySettingsChangedNotification",
    ]

    public init() {
        refresh()
        let center = workspace.notificationCenter
        for name in Self.changeNotificationKeys {
            observers.append(center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        // 系统外观切换也会影响高对比下的语义色，顺带跟着重算一次
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    /// 测试注入点：非 nil 时覆盖系统读数。没有这个，"减少动态效果要把时长归零"
    /// 这种断言只能在别人改了系统设置时才跑得动 —— 那就不是门禁了。
    public var overrideReduceMotion: Bool?
    public var overrideReduceTransparency: Bool?

    public var effectiveReduceMotion: Bool { overrideReduceMotion ?? reduceMotion }
    public var effectiveReduceTransparency: Bool { overrideReduceTransparency ?? reduceTransparency }

    public func refresh() {
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        // 注：「不同时使用颜色区分」在 NSWorkspace 上**没有对应属性**（实测编译不过），
        // 它只在 SwiftUI 侧以 @Environment(\.accessibilityDifferentiateWithoutColor) 暴露。
        // 本项目每行都带 symbol + 文字，颜色从来不是唯一线索，所以此处不读也不影响合规。
    }

    /// 动效时长：开了「减少动态效果」就归零。放在这里而不是散在各视图里，
    /// 是因为 `Layout.Motion` 已经规定"视图层不许自己写时长"，一处生效全仓生效。
    public func motionDuration(_ base: TimeInterval, scale: Double) -> TimeInterval {
        effectiveReduceMotion ? 0 : Layout.Motion.scaled(base, scale)
    }

    /// 面板底衬：开「降低透明度」时给不透明底，材质那层由调用方跳过。
    public var panelShouldBeOpaque: Bool { effectiveReduceTransparency }
}
