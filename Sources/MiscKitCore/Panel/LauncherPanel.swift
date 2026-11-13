import AppKit

/// 唤起面板：不抢 Dock、不参与 App 切换、置顶、跨 Space、可在全屏 App 之上出现。
public final class LauncherPanel: NSPanel {
    public init(width: CGFloat, height: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            // borderless：frame 与内容完全等大，不留 32pt 标题栏偏差；
            // 键盘输入靠下面的 canBecomeKey 覆写拿回来。红绿灯也自然不存在。
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isMovable = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        // 不要系统那一下"工具窗淡入"：它会在首次唤出时先闪一个缩小的框，
        // 和 SwiftUI 自己的淡入+缩放叠在一起。出现/消失只走视图层动画。
        animationBehavior = .none
        // 用户手动缩放由 PanelController 把 min/max 钉成同一尺寸来禁止。
        minSize = NSSize(width: Layout.Metric.panelMinWidth, height: Layout.Metric.collapsedHeight)
    }

    /// 关掉红绿灯：位置由控制器算出，不需要用户拖动或缩放面板。
    public func hideWindowControls() {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            standardWindowButton($0)?.isHidden = true
        }
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
