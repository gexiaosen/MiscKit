import AppKit
import MiscKitCore
import SwiftUI

/// 屏幕提醒的窗口层：全屏透明面板，不激活 App、不抢键盘。
///
/// 面板自己给出 45 秒兜底计时；按钮、点空白、自动收起都走同一条 `close`，
/// 保证"完成/稍后"只结算一次。两条计划撞在一起时排队，前一张关掉再出下一张。
@MainActor
final class ReminderOverlayController {
    static let shared = ReminderOverlayController()

    private struct Request {
        let kind: ReminderKind
        let snoozeMinutes: Int
        let onComplete: @MainActor () -> Void
        let onSnooze: @MainActor () -> Void
    }

    private enum CloseReason {
        case complete
        case snooze
        case dismiss
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var current: Request?
    private var pending: [Request] = []

    private init() {}

    func show(kind: ReminderKind,
              snoozeMinutes: Int,
              onComplete: @escaping @MainActor () -> Void,
              onSnooze: @escaping @MainActor () -> Void) {
        let request = Request(kind: kind,
                              snoozeMinutes: snoozeMinutes,
                              onComplete: onComplete,
                              onSnooze: onSnooze)
        guard panel == nil else {
            pending.append(request)
            return
        }
        present(request)
    }

    private func present(_ request: Request) {
        guard let screen = targetScreen else { return }
        current = request

        let view = ReminderOverlayView(
            kind: request.kind,
            snoozeMinutes: request.snoozeMinutes,
            onComplete: { [weak self] in self?.close(.complete) },
            onSnooze: { [weak self] in self?.close(.snooze) },
            onDismiss: { [weak self] in self?.close(.dismiss) }
        )
        let hosting = OverlayHostingView(rootView: view)

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        let timer = Timer(timeInterval: TimeInterval(ReminderOverlayChrome.autoDismissSeconds),
                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close(.dismiss) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_CAPTURE_OVERLAY"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.capture(to: path)
            }
        }
        #endif
    }

    private func close(_ reason: CloseReason) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil

        let request = current
        current = nil
        if let request {
            switch reason {
            case .complete: request.onComplete()
            case .snooze: request.onSnooze()
            case .dismiss: break
            }
        }

        if !pending.isEmpty {
            present(pending.removeFirst())
        }
    }

    /// 鼠标所在的那块屏幕；没有屏幕（显示器全睡）时 `ReminderCenter` 已经先跳过。
    private var targetScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// 验收用：`MISCKIT_DEBUG_CAPTURE_OVERLAY=/tmp/x.png` 把整个浮层画成位图。
    /// 和设置窗的捕获一样走 `cacheDisplay`，不需要屏幕录制权限；玻璃由 Metal 合成，离屏可能没有像素。
    private func capture(to path: String) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[overlay] capture 失败：拿不到位图上下文"); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("[overlay] capture 失败：写不出 PNG"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            NSLog("[overlay] captured %@ (%dx%d)", path, rep.pixelsWide, rep.pixelsHigh)
        } catch {
            NSLog("[overlay] capture 失败：%@", error.localizedDescription)
        }
    }
}

/// 非 key 窗口的第一下点击也要落到底下的视图/手势上，否则"点空白关闭"和按钮都得点两次。
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
