import AppKit
import Observation
import os
import SwiftUI

@MainActor
@Observable
public final class PanelModel {
    public var isVisible = false
    /// 文件拖拽进行中：此时失焦不隐藏
    public var dragGuard = false
    /// 设置页调参时钉住面板：失焦不消失，才能边拧滑块边看
    public var previewPinned = false
    /// 实际面板宽度：期望 750 pt（2x 屏 1500 px），小屏按可用宽度收窄，由控制器统一裁决
    public var panelWidth: CGFloat = Layout.Metric.panelWidth
    /// 可见形状的目标高度。窗口可以先一步长到位，由 SwiftUI 把这个形状缓动到新高度。
    public var revealHeight: CGFloat = Layout.Metric.barHeight
    public var query = ""
    public var selectedToolID: ToolID?
    /// 上一次隐藏的时刻。超时要不要把"上一次的输入"恢复回来，见 `stateIsStale`。
    public var hiddenAt: Date?

    /// 「失焦消失后接着用」的时间窗（2026-10-22 定：2 分钟）。
    public static let stateLifetime: TimeInterval = 120

    /// 隐藏超过 `Self.stateLifetime` 就当作新的一次使用：把旧的 query 清空回到初始态。
    /// 设置页在钉住预览时永远不算过期——那是同一次调参，不是离开又回来。
    public func stateIsStale(now: Date) -> Bool {
        guard !previewPinned, let hiddenAt else { return false }
        return now.timeIntervalSince(hiddenAt) > Self.stateLifetime
    }

    /// 过期回到初始态：清输入、清选中工具，**并把可见形状先收回到输入条**，返回是否清过。
    /// 形状必须赶在 `isVisible` 置真之前落定：视图那条动画是
    /// `.animation(model.isVisible ? revealAnimation : nil, value: revealHeight)`，
    /// 先上屏再收，等于当着人面把旧形态塌下来（2026-11-09 他实测到的"展开收起"动画）。
    @discardableResult
    public func resetStaleState(now: Date) -> Bool {
        guard stateIsStale(now: now) else { return false }
        query = ""
        selectedToolID = nil
        revealHeight = Layout.Metric.barHeight
        return true
    }
}

@MainActor
public protocol PanelControlling: AnyObject {
    var model: PanelModel { get }
    /// 面板是否是 key window：失焦时 AppKit 会补一个 cancel 命令，
    /// 视图靠这个区分"用户按了 Esc"和"焦点被别人抢走"。
    var isKeyWindow: Bool { get }
    /// 面板窗口此刻真正所在的层。系统选择器要盖在它上面才点得到。
    var windowLevel: NSWindow.Level { get }
    func setContentHeight(_ height: CGFloat)
    func show()
    func hide()
}

/// 全局唯一的面板句柄。设置页要能"钉住面板 + 预览"，
/// 而泛型 PanelController 没法直接塞进 SwiftUI 环境，所以在这里做一次类型擦除。
@MainActor
public enum PanelHost {
    public static weak var controller: (any PanelControlling)?

    /// 从面板里叫起的系统选择器统一抬到这一层。
    /// 原因：面板浮在 `.floating`(3)——`LauncherPanel` 里 `isFloatingPanel = true`
    /// 会把先前写的 `.statusBar` 改回去；而 `NSOpenPanel` 默认是 normal(0)，
    /// 结果选择器整个被面板盖住，点「添加文件夹…」看着像没反应。
    /// 取实时层而不是写死数字，面板哪天真的升到 statusBar 也不会失效。
    public static var pickerLevel: NSWindow.Level {
        NSWindow.Level(rawValue: (controller?.windowLevel ?? .floating).rawValue + 1)
    }
}

@MainActor
public final class PanelController<Content: View>: NSObject, NSWindowDelegate, PanelControlling {
    public let model = PanelModel()

    private let buildContent: (PanelController<Content>) -> Content
    private let settings: AppSettings
    private var panel: LauncherPanel?
    private var visibilityGeneration = 0
    private var lastFrameOrigin: NSPoint?
    private let log = Logger(subsystem: "app.misckit.launcher", category: "panel")

    public init(settings: AppSettings = .shared,
                content buildContent: @escaping (PanelController<Content>) -> Content) {
        self.settings = settings
        self.buildContent = buildContent
        super.init()
        // 不挂这一句，设置页的「预览面板」与 hosts 的生效预览都会静默失效：
        // 读的一方（PanelHost.controller?）拿到的一直是 nil，guard-else 直接 return。
        PanelHost.controller = self
    }

    // MARK: 对外动作

    /// 启动时预热：提前建好窗口并跑一次排版。
    /// 否则第一次唤出才做第一次 SwiftUI 布局，冷启动那一下会闪出半成品尺寸的小框。
    public func prewarm() {
        let panel = ensurePanel()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    public func toggle() {
        if model.isVisible { hide() } else { show() }
    }

    public var isKeyWindow: Bool { panel?.isKeyWindow ?? false }

    /// 还没建过窗口时按面板实际会出现的 `.floating` 报，别报 0。
    public var windowLevel: NSWindow.Level { panel?.level ?? .floating }

    public func show() {
        let panel = ensurePanel()
        // 隔了 2 分钟才回来，上一次的输入早就是另一件事了：清掉，从初始态开始。
        // 清空后 LauncherView 那条 task(id: model.query) 会顺带退掉钉住的工作区与选中行，
        // 这里不重复写一遍退模式的逻辑。形状也在这一刻收回到输入条——见 `resetStaleState`。
        model.resetStaleState(now: Date())
        model.hiddenAt = nil
        visibilityGeneration += 1
        model.isVisible = true
        // 空输入就只可能是输入条：上一次的展开形状不许带进来。
        // 少了这一句，偶尔会先按旧会话的高度上屏一帧再收回输入条（他会看到"闪一下"）。
        if model.query.isEmpty, abs(model.revealHeight - Layout.Metric.barHeight) > 0.5 {
            model.revealHeight = Layout.Metric.barHeight
        }
        // 隐藏期间形状可能已经收回去，窗口若还留着旧高度会挡住下方点击，先贴合。
        if abs(panel.frame.height - model.revealHeight) > 0.5 {
            applyHeight(model.revealHeight, to: panel)
        }
        position(panel)
        // 上屏前把 SwiftUI 的布局按当前形状落定：窗口一出现就画上一次的尺寸，看着就是闪。
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        fadeWindow(to: 1, duration: summonDuration)
        Breadcrumbs.event("panel.show", [
            "w": String(format: "%.0f", panel.frame.width),
            "h": String(format: "%.0f", panel.frame.height),
            "pinned": model.previewPinned ? "1" : "0",
        ])
        // AppKit 在窗口重新成为 key 时会把聚焦输入框的内容整段选中，唤回面板接着打字
        // 就变成"替换全部"。把光标收到末尾，行为回到"接着输入"。等一拍再做：
        // 字段编辑器是 makeKey 之后才装上的。
        DispatchQueue.main.async {
            guard let editor = panel.firstResponder as? NSTextView else { return }
            let end = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
        log.info("panel shown")
    }

    private var summonDuration: TimeInterval {
        AccessibilityPreferences.shared.motionDuration(Layout.Motion.summon,
                                                       scale: settings.motionScale)
    }

    /// 整窗透明度的唯一出口：文字与玻璃作为一张画面淡出/淡入。
    /// 时长归零（减少动态效果）时直接设值，不做动画。
    private func fadeWindow(to alpha: CGFloat, duration: TimeInterval) {
        guard let panel else { return }
        guard duration > 0 else {
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }
    }

    public func hide() {
        guard let panel, model.isVisible else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
            FileHandle.standardError.write("panel hide requested\n".data(using: .utf8)!)
        }
        #endif
        model.isVisible = false
        model.hiddenAt = Date()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let wait = AccessibilityPreferences.shared.motionDuration(Layout.Motion.dismiss,
                                                       scale: settings.motionScale)
        fadeWindow(to: 0, duration: wait)
        Breadcrumbs.event("panel.hide", [
            "h": String(format: "%.0f", panel.frame.height),
            "pinned": model.previewPinned ? "1" : "0",
            "drag": model.dragGuard ? "1" : "0",
        ])
        // 淡出交给 SwiftUI；这里只在动画结束后把窗口摘掉。
        // 世代计数防止"上一次隐藏的收尾"把之后刚显示的面板一起藏掉。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard generation == self.visibilityGeneration, !self.model.isVisible else { return }
            panel.orderOut(nil)
        }
    }

    /// 由视图上报**内容**高度。iOS 式做法：窗口顶边固定，长高时窗口先一次到位，
    /// 可见的玻璃形状在窗口内由 SwiftUI 缓动展开；收缩时等形状收完再贴合窗口。
    /// 逐帧改窗口会让 NSHostingView 的布局落后于 frame，输入框会跟着上下跳。
    public func setContentHeight(_ height: CGFloat) {
        guard let panel else { return }
        let clamped = min(max(height, Layout.Metric.barHeight), Layout.Metric.maxContentHeight)
        #if DEBUG
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
            FileHandle.standardError.write("setContentHeight in=\(height) clamped=\(clamped)\n".data(using: .utf8)!)
        }
        #endif

        let oldFrame = panel.frame
        guard abs(clamped - oldFrame.height) > 0.5 else {
            if abs(model.revealHeight - clamped) > 0.5 { model.revealHeight = clamped }
            return
        }

        if !model.isVisible {
            shrinkTask?.cancel()
            model.revealHeight = clamped
            applyHeight(clamped, to: panel)
            return
        }

        if clamped >= oldFrame.height {
            shrinkTask?.cancel()
            applyHeight(clamped, to: panel)
            model.revealHeight = clamped
        } else {
            model.revealHeight = clamped
            scheduleWindowShrink(of: panel, to: clamped)
        }
    }

    private var shrinkTask: Task<Void, Never>?
    private var shrinkGeneration = 0

    /// 顶边固定：只改高度时窗口上沿在屏幕上的位置不动。
    private func applyHeight(_ height: CGFloat, to panel: LauncherPanel) {
        let old = panel.frame
        let frame = NSRect(x: old.minX, y: old.maxY - height,
                           width: model.panelWidth, height: height)
        panel.setFrame(frame, display: true)
    }

    private func scheduleWindowShrink(of panel: LauncherPanel, to height: CGFloat) {
        shrinkTask?.cancel()
        shrinkGeneration += 1
        let generation = shrinkGeneration
        // 等 SwiftUI 的展开曲线走完再收窗口；期间多出来的区域是透明的。
        let delay = AccessibilityPreferences.shared.motionDuration(Layout.Motion.resize,
                                                       scale: settings.motionScale) + 0.04
        shrinkTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard generation == self.shrinkGeneration,
                  self.model.isVisible,
                  abs(self.model.revealHeight - height) < 0.5 else { return }
            self.applyHeight(height, to: panel)
        }
    }

    // MARK: 内部

    private func ensurePanel() -> LauncherPanel {
        if let panel { return panel }
        let panel = LauncherPanel(width: Layout.Metric.panelWidth,
                                  height: Layout.Metric.barHeight)
        panel.delegate = self
        panel.hideWindowControls()
        // 从全透明开始：出现时由 `fadeWindow(to: 1)` 淡入。整窗 alpha 是窗口服务器
        // 统一合成的一层，文字与玻璃一起淡，不会出现"文字先闪一下"。
        panel.alphaValue = 0
        let hosting = NSHostingView(rootView: buildContent(self))
        // 高度归控制器管：NSHostingView 参与 Auto Layout 时会把窗口压到 fittingSize，
        // setContentHeight 的动画会被它覆盖。用无 intrinsic size 的容器隔离。
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: panel.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        return panel
    }

    private func position(_ panel: LauncherPanel) {
        let screen = targetScreen(center: settings.position == .remembered ? lastFrameOrigin : nil)
        // 750 pt 在小屏上放不下：按可用宽度收窄，视图与窗口用同一个值
        model.panelWidth = min(Layout.Metric.panelWidth,
                               screen.visibleFrame.width * Layout.Metric.panelWidthRatioOnSmallScreen)
        let size = NSSize(width: model.panelWidth, height: panel.frame.height)
        panel.setContentSize(size)
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y: CGFloat
        if settings.position == .screenCenter {
            y = visible.midY - size.height / 2
        } else {
            y = visible.maxY - visible.height * Layout.Metric.topInsetRatio - size.height
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        lastFrameOrigin = panel.frame.origin
    }

    private func targetScreen(center: NSPoint?) -> NSScreen {
        let point = center ?? NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil {
            let line = "resignKey hideOnBlur=\(settings.hideOnBlur) drag=\(model.dragGuard) pinned=\(model.previewPinned) ownModal=\(showsOwnModal) visible=\(model.isVisible)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        #endif
        Breadcrumbs.event("panel.resignKey", [
            "hideOnBlur": settings.hideOnBlur ? "1" : "0",
            "drag": model.dragGuard ? "1" : "0",
            "pinned": model.previewPinned ? "1" : "0",
            "ownModal": showsOwnModal ? "1" : "0",
            "visible": model.isVisible ? "1" : "0",
        ])
        if settings.hideOnBlur && !model.dragGuard && !model.previewPinned && !showsOwnModal { hide() }
    }

    /// 面板自己叫起来的 sheet / 子窗口（导入面板、确认弹窗、文件选择器）拿到焦点，
    /// 不算"用户走开了"。少了这一条，点「导入…」的瞬间面板就会因为失焦自我隐藏，
    /// 挂在它上面的弹窗跟着一起消失。
    private var showsOwnModal: Bool {
        guard let panel else { return false }
        if panel.attachedSheet != nil { return true }
        if (panel.childWindows ?? []).contains(where: { $0.isVisible }) { return true }
        if let key = NSApp.keyWindow, key !== panel, key.sheetParent === panel { return true }
        return false
    }

    public func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        lastFrameOrigin = panel.frame.origin
    }
}
