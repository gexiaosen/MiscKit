import SwiftUI
import Testing

@testable import MiscKitCore

/// 设置窗外壳的数字与标签三态。三态映射错了不会崩，只会"看不出哪一项被选中"，
/// 而这种东西在肉眼验收之前必须有一道闸。
@MainActor
@Suite("设置窗外壳：尺寸与标签三态")
struct SettingsChromeTests {
    @Test("外框是 780×500 的长方形，内容卡尺寸由外框推导而不是再写一个常量")
    func geometry() {
        #expect(SettingsChrome.width == 780)
        #expect(SettingsChrome.height == 500)
        #expect(SettingsChrome.width / SettingsChrome.height > 1.5, "长方形，别又长成方的")
        #expect(SettingsChrome.cardWidth
                == SettingsChrome.width - 2 * SettingsChrome.inset - SettingsChrome.sidebarWidth)
        #expect(SettingsChrome.cardHeight == SettingsChrome.height - 2 * SettingsChrome.inset)
        // 侧栏只装图标 + 三个汉字；宽度全部让给内容卡
        #expect(SettingsChrome.sidebarWidth == 144)
        #expect(SettingsChrome.cardWidth > SettingsChrome.sidebarWidth * 3)
        #expect(SettingsChrome.minWidth < SettingsChrome.width)
        #expect(SettingsChrome.minHeight < SettingsChrome.height)
    }

    @Test("红绿灯与标签在同一条竖线上，且自身上边距=左边距")
    func lightsAlignWithTheTabs() {
        // 圆点钉在 (inset, inset)，标签 pill 的左边缘也在 inset —— 两条线共用一个常量
        #expect(SettingsChrome.inset == 18)
        #expect(SettingsChrome.trafficLightDiameter == 12)
        // 第一行标签要让开红绿灯那一行（圆点底 30 + 呼吸 18 = 48，外层已给 18）
        #expect(SettingsChrome.inset + SettingsChrome.trafficLightClear == 48)
    }

    @Test("圆角与内缩只有一把尺：半径来自面板，pill 来自同心推导")
    func radiiComeFromTheSameRuler() {
        #expect(SettingsChrome.inset == 18)
        #expect(SettingsChrome.radius == Layout.Metric.panelRadius)
        #expect(SettingsChrome.tabRadius == Layout.Metric.rowCornerRadius)
        #expect(SettingsChrome.tabRadius
                == Layout.concentric(SettingsChrome.radius, inset: Layout.Metric.listInset))
        #expect(SettingsChrome.tabRadius < SettingsChrome.radius)
        // 内容卡与外框同心：半径 = 外框 − 留白。同半径会在角上挤出月牙（他判过难看）
        #expect(SettingsChrome.cardRadius
                == Layout.concentric(SettingsChrome.radius, inset: SettingsChrome.inset))
        #expect(SettingsChrome.cardRadius < SettingsChrome.tabRadius)
    }

    @Test("三态互斥：选中压过悬浮，只有选中那一行上玻璃")
    func statesAreExclusive() {
        #expect(SettingsChrome.state(selected: true, hovered: true) == .selected)
        #expect(SettingsChrome.state(selected: false, hovered: true) == .hover)
        #expect(SettingsChrome.state(selected: false, hovered: false) == .normal)

        #expect(SettingsChrome.showsGlassPill(.selected))
        for state in [SettingsChrome.TabState.normal, .hover] {
            #expect(!SettingsChrome.showsGlassPill(state), "\(state) 不许上玻璃")
        }
        #expect(SettingsChrome.showsHoverFill(.hover))
        #expect(!SettingsChrome.showsHoverFill(.selected), "选中已经有玻璃，不该再叠一层灰")
        #expect(!SettingsChrome.showsHoverFill(.normal))
    }

    @Test("强调色与字重只跟选中走")
    func emphasis() {
        #expect(SettingsChrome.labelWeight(.selected) == .semibold)
        #expect(SettingsChrome.labelWeight(.normal) == .regular)
        #expect(SettingsChrome.labelWeight(.hover) == .regular)
        #expect(SettingsChrome.iconUsesAccent(.selected))
        #expect(!SettingsChrome.iconUsesAccent(.hover), "悬浮不该抢选中的视觉")
        #expect(!SettingsChrome.iconUsesAccent(.normal))
    }
}
