import MiscKitCore
import SwiftUI

/// 屏幕中央的提醒卡。
///
/// 整块屏幕只负责压暗与接住"点空白处关闭"；卡片本身不抢键盘焦点，
/// 所以底部不写 Esc —— 不接管键盘就收不到按键。按钮用点击手势而不是
/// SwiftUI `Button`，避免非 key 窗口第一下只用来聚焦、不触发动作。
struct ReminderOverlayView: View {
    let kind: ReminderKind
    let snoozeMinutes: Int
    let onComplete: () -> Void
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.appLanguage) private var appLanguage
    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared
    @State private var appeared = false
    @State private var progress: CGFloat = 1
    @State private var startedAt = Date()

    var body: some View {
        let _ = appLanguage
        ZStack {
            Theme.reminderScrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            card
                .scaleEffect(appeared ? 1 : 0.975)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startedAt = Date()
            withAnimation(entranceAnimation) { appeared = true }
            withAnimation(.linear(duration: TimeInterval(ReminderOverlayChrome.autoDismissSeconds))) {
                progress = 0
            }
        }
    }

    /// 入场：短弹簧，卡片落定时有一点"落座"感；减少动态效果时瞬现。
    private var entranceAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.reminderEntrance, scale: settings.motionScale)
        return duration > 0 ? .spring(duration: duration, bounce: Layout.Motion.reminderBounce) : nil
    }

    private var card: some View {
        VStack(spacing: 0) {
            artwork
                .frame(height: ReminderOverlayChrome.artHeight)

            Text(kind.reminderTitle)
                .font(Type.display.weight(.semibold))
                .foregroundStyle(Theme.rowText)
                .padding(.top, 10)

            Text(kind.reminderBody)
                .font(Type.body)
                .foregroundStyle(Theme.textBody)
                .padding(.top, 7)

            HStack(spacing: 10) {
                OverlayActionButton(title: L10n.Reminder.Overlay.snoozeMinutes(snoozeMinutes),
                                    emphasis: .secondary,
                                    action: onSnooze)
                OverlayActionButton(title: L10n.Reminder.Overlay.complete,
                                    emphasis: .primary,
                                    action: onComplete)
            }
            .padding(.top, 24)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, ReminderOverlayChrome.autoDismissSeconds
                    - Int(context.date.timeIntervalSince(startedAt)))
                Text(L10n.Reminder.Overlay.autoDismiss(remaining))
                    .font(Type.meta)
                    .foregroundStyle(Theme.decorationOnly)
                    .monospacedDigit()
            }
            .padding(.top, 18)

            progressBar
                .padding(.top, 14)
        }
        .padding(.top, ReminderOverlayChrome.topPadding)
        .padding(.horizontal, ReminderOverlayChrome.horizontalPadding)
        .padding(.bottom, ReminderOverlayChrome.bottomPadding)
        .frame(width: ReminderOverlayChrome.cardWidth)
        .chromeGlass(cornerRadius: ReminderOverlayChrome.cardRadius)
    }

    @ViewBuilder
    private var artwork: some View {
        let hue = Theme.reminderHue(for: kind, scheme: scheme)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [hue.top.opacity(0.18), hue.top.opacity(0)],
                                     center: .center,
                                     startRadius: 0,
                                     endRadius: ReminderOverlayChrome.artworkHalo / 2))
                .frame(width: ReminderOverlayChrome.artworkHalo,
                       height: ReminderOverlayChrome.artworkHalo)

            switch kind {
            case .water:
                WaterDropShape()
                    .fill(LinearGradient(colors: [hue.top, hue.bottom],
                                         startPoint: .top,
                                         endPoint: .bottom))
                    .frame(width: 120, height: ReminderOverlayChrome.artHeight)
                    .overlay {
                        Ellipse()
                            .fill(.white.opacity(0.17))
                            .frame(width: 12, height: 24)
                            .rotationEffect(.degrees(14))
                            .offset(x: -14, y: 12)
                    }
            case .stand:
                Image(systemName: "figure.arms.open")
                    .resizable()
                    .scaledToFit()
                    .frame(height: ReminderOverlayChrome.artHeight)
                    .foregroundStyle(LinearGradient(colors: [hue.top, hue.bottom],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing))
            }
        }
    }

    private var progressBar: some View {
        RoundedRectangle(cornerRadius: ReminderOverlayChrome.progressHeight / 2, style: .continuous)
            .fill(Theme.decorationOnly.opacity(0.15))
            .frame(width: ReminderOverlayChrome.progressWidth,
                   height: ReminderOverlayChrome.progressHeight)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: ReminderOverlayChrome.progressHeight / 2,
                                 style: .continuous)
                    .fill(Theme.decorationOnly.opacity(0.45))
                    .frame(width: ReminderOverlayChrome.progressWidth * progress,
                           height: ReminderOverlayChrome.progressHeight)
            }
    }
}

/// 卡片里的两个按钮。不用 `Button`：浮层不是 key window，普通按钮第一下可能只用来聚焦。
private struct OverlayActionButton: View {
    enum Emphasis { case primary, secondary }

    let title: String
    let emphasis: Emphasis
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ReminderOverlayChrome.buttonRadius, style: .continuous)
    }

    var body: some View {
        Text(title)
            .font(Type.body.weight(.medium))
            .foregroundStyle(emphasis == .primary
                             ? Theme.reminderPrimaryText(for: scheme)
                             : Theme.textBody)
            .frame(maxWidth: .infinity)
            .frame(height: ReminderOverlayChrome.buttonHeight)
            .background {
                shape.fill(background)
            }
            .overlay {
                if emphasis == .secondary {
                    shape.strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityAction { action() }
    }

    private var background: Color {
        switch emphasis {
        case .primary:
            return Theme.reminderPrimaryFill(for: scheme)
        case .secondary:
            return hovering ? Theme.rowHover.opacity(0.20) : .clear
        }
    }
}

/// 水滴轮廓：按 120×128 的坐标缩放到实际尺寸。
private struct WaterDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 120 * rect.width,
                    y: rect.minY + y / 128 * rect.height)
        }

        var path = Path()
        path.move(to: point(60, 12))
        path.addCurve(to: point(94, 82),
                      control1: point(60, 12),
                      control2: point(94, 57))
        path.addCurve(to: point(60, 116),
                      control1: point(94, 100.8),
                      control2: point(78.8, 116))
        path.addCurve(to: point(26, 82),
                      control1: point(41.2, 116),
                      control2: point(26, 100.8))
        path.addCurve(to: point(60, 12),
                      control1: point(26, 57),
                      control2: point(60, 12))
        path.closeSubpath()
        return path
    }
}
