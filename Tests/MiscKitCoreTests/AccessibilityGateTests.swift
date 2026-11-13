import Foundation
import Testing

@testable import MiscKitCore

/// 无障碍开关的行为门禁。系统开关本身没法在测试里改，所以 `AccessibilityPreferences`
/// 留了注入点 —— 否则"减少动态效果要归零"这条断言永远只是文档。
@MainActor
@Suite("无障碍开关")
struct AccessibilityGateTests {
    @Test("减少动态效果打开时，所有动效时长归零；关闭时按倍率走")
    func reduceMotionZeroesDurations() {
        let prefs = AccessibilityPreferences()
        prefs.overrideReduceMotion = true
        #expect(prefs.motionDuration(Layout.Motion.summon, scale: 1) == 0)
        #expect(prefs.motionDuration(Layout.Motion.resize, scale: 2) == 0)

        prefs.overrideReduceMotion = false
        #expect(prefs.motionDuration(Layout.Motion.summon, scale: 1) == Layout.Motion.summon)
        #expect(prefs.motionDuration(Layout.Motion.summon, scale: 2) == Layout.Motion.summon * 2)
        // 倍率越界要夹住，不能让一个坏设置把动画拉长到不可用
        #expect(prefs.motionDuration(Layout.Motion.summon, scale: 99)
                == Layout.Motion.summon * Layout.Motion.maxScale)
    }

    @Test("降低透明度打开时，面板要求不透明底")
    func reduceTransparencyAsksForOpaquePanel() {
        let prefs = AccessibilityPreferences()
        prefs.overrideReduceTransparency = true
        #expect(prefs.panelShouldBeOpaque)
        prefs.overrideReduceTransparency = false
        // 关掉注入点后跟随系统；这里只断言"不再强制"
        #expect(prefs.panelShouldBeOpaque == prefs.reduceTransparency)
    }

    @Test("动效时长单点：视图层拿到的都是同一个算法")
    func motionScalingIsCentralised() {
        for base in [Layout.Motion.summon, Layout.Motion.dismiss, Layout.Motion.resize] {
            #expect(Layout.Motion.scaled(base, 1.0) == base)
            #expect(Layout.Motion.scaled(base, 0.1) == base * Layout.Motion.minScale)
        }
    }
}
