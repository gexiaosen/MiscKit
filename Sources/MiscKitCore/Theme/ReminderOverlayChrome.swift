import CoreGraphics

/// 屏幕提醒浮层的定稿规格（2026-10-26 按 demo 验收）。改动这里等于改 demo 的尺寸与时长。
public enum ReminderOverlayChrome {
    public static let cardWidth: CGFloat = 360
    public static let cardRadius: CGFloat = 24
    public static let topPadding: CGFloat = 28
    public static let horizontalPadding: CGFloat = 26
    public static let bottomPadding: CGFloat = 22
    public static let artHeight: CGFloat = 128
    public static let artworkHalo: CGFloat = 160
    public static let buttonHeight: CGFloat = 38
    public static let buttonRadius: CGFloat = 12
    public static let progressWidth: CGFloat = 120
    public static let progressHeight: CGFloat = 2
    public static let scrimOpacity: Double = 0.28
    public static let autoDismissSeconds: Int = 45
}
