import Testing
import CoreGraphics

@testable import MiscKitCore

/// 面板形状的推导关系。圆角具体取几是观感判断（归你），但**推导链不能断**：
/// 以前 `panelRadius` 写死 26 而 `barHeight = 60`，两端就不是半圆，
/// 而文字内缩与行圆角各自又抄了一个数，改一个忘一个就分叉。
@Suite("面板形状推导")
struct PanelShapeTests {
    @Test("圆角不许超过输入条半高 —— 超过就会被压扁成椭圆角")
    func radiusCannotExceedHalfBar() {
        #expect(Layout.Metric.panelRadius <= Layout.Metric.barHeight / 2,
                "半径 \(Layout.Metric.panelRadius) 超过半高 \(Layout.Metric.barHeight / 2)")
    }

    @Test("行圆角是外半径的同心推导值，不是另一个手写的数")
    func rowRadiusIsConcentric() {
        #expect(Layout.Metric.rowCornerRadius ==
                Layout.concentric(Layout.Metric.panelRadius, inset: Layout.Metric.listInset))
        #expect(Layout.Metric.rowCornerRadius < Layout.Metric.panelRadius, "内层必须比外层小才同心")
    }

    @Test("文字内缩跟着圆角走（让开半圆端头）")
    func textInsetFollowsRadius() {
        #expect(Layout.Metric.barTextInset == Layout.Metric.panelRadius + 12)
    }
}
