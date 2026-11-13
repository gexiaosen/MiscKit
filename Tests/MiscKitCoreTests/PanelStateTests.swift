import Foundation
import Testing

@testable import MiscKitCore

/// 「失焦消失后再唤起，状态留不留」这条规则。它以前没人管：隐藏不清任何东西，
/// 于是三天前那次输入也算"上一个非初始状态"。现在定 2 分钟窗口。
@MainActor
@Suite("面板状态的时间窗")
struct PanelStateTests {
    /// 固定基准时刻：边界测试不能拿真实时钟去卡 120 秒，跑测本身就会漂几毫秒。
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private func model(hiddenFor seconds: TimeInterval?, preview: Bool = false) -> PanelModel {
        let m = PanelModel()
        m.query = "chrome"
        m.previewPinned = preview
        if let seconds { m.hiddenAt = anchor.addingTimeInterval(-seconds) }
        return m
    }

    @Test("从没隐藏过 → 没有旧状态可言")
    func neverHiddenIsNotStale() {
        #expect(!model(hiddenFor: nil).stateIsStale(now: anchor))
    }

    @Test("窗口内算接着用，超过才算新的一次")
    func insideTheWindowSurvives() {
        #expect(!model(hiddenFor: PanelModel.stateLifetime - 1).stateIsStale(now: anchor))
        #expect(model(hiddenFor: PanelModel.stateLifetime + 1).stateIsStale(now: anchor))
    }

    @Test("正好卡在边界上不清——规则是「超过」，别把边界做成抖动")
    func exactBoundaryIsNotStale() {
        #expect(!model(hiddenFor: PanelModel.stateLifetime).stateIsStale(now: anchor))
        // 再往后一毫秒就该清了
        #expect(model(hiddenFor: PanelModel.stateLifetime).stateIsStale(
            now: anchor.addingTimeInterval(0.001)))
    }

    @Test("时间窗是 2 分钟")
    func lifetimeIsTwoMinutes() {
        #expect(PanelModel.stateLifetime == 120)
    }

    @Test("设置页钉住预览时永不过期——那是同一次调参，不是离开又回来")
    func previewPinningNeverExpires() {
        #expect(!model(hiddenFor: 3600, preview: true).stateIsStale(now: anchor))
    }

    @Test("钉住解除后立刻按 hiddenAt 判过期：预览不能把时间窗一起改掉")
    func unpinningRestoresExpiry() {
        let m = model(hiddenFor: 3600, preview: true)
        #expect(!m.stateIsStale(now: anchor))
        m.previewPinned = false
        #expect(m.stateIsStale(now: anchor), "解钉后仍按原 hiddenAt 算，不能顺手刷新时间窗")
    }

    /// 他实测到的毛病：上次关闭时是展开形态，隔一会儿再唤起会演一遍"从展开塌下来"。
    /// 根因是清空输入后形状仍留着旧高度，等上屏再收就被视图当成一次收缩动画。
    @Test("过期回初始态时形状先收回到输入条，且不许顺手把面板置为可见")
    func staleResetSnapsTheShapeBeforeShowing() {
        let m = model(hiddenFor: PanelModel.stateLifetime + 1)
        m.revealHeight = 400
        #expect(m.resetStaleState(now: anchor))
        #expect(m.query.isEmpty)
        #expect(m.revealHeight == Layout.Metric.barHeight,
                "形状没先落定，上屏后那一收会被演成收缩动画")
        #expect(!m.isVisible, "落形状不是显示面板")

        // 窗口内回来是「接着用」：一个字、一像素都不该动
        let fresh = model(hiddenFor: 5)
        fresh.revealHeight = 400
        #expect(!fresh.resetStaleState(now: anchor))
        #expect(fresh.query == "chrome")
        #expect(fresh.revealHeight == 400)
    }
}
