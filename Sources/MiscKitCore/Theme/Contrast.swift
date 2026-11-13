import Foundation

/// 玻璃面板上的文字对比度模型。纯算术、无 UI，所以能在单测里当门禁（`ContrastAuditTests`）。
///
/// 面板历史上有三层：玻璃 → `NSVisualEffectView` 材质 → 用户可调的额外压暗。
/// 2026-10-22 定了**只剩玻璃一层**：材质与压暗整条删除（`.glassEffect(.regular)` 直接作底衬）。
/// 于是这一层负责"看得清"的能力从**可算**变成了**算不出来** —— Liquid Glass 是 Metal 合成的，
/// 离屏 `bitmapImageRepForCachingDisplay` 拿不到它的读数，只能真机肉眼判。
/// 所以这里的公式与门槛继续用于：① 系统「降低透明度」时那条不透明底；② 选档与选型时的下限推算；
/// ③ 墨色令牌本身够不够格承载正文。**不要**再拿它宣称"面板达标 4.5:1"，那是没验过的。
public enum Contrast {
    /// macOS 语义色的实际不透明度（本机 sRGB 解析得到的取样值）。
    public struct Ink: Sendable {
        public let lightAlpha: Double
        public let darkAlpha: Double
        public init(light: Double, dark: Double) {
            lightAlpha = light
            darkAlpha = dark
        }
    }

    public static let label = Ink(light: 0.85, dark: 0.85)
    public static let secondaryLabel = Ink(light: 0.50, dark: 0.55)
    public static let tertiaryLabel = Ink(light: 0.26, dark: 0.25)
    /// `Theme.textBody`：从 labelColor 派生再乘一层 0.85
    public static let textBody = Ink(light: label.lightAlpha * 0.85, dark: label.darkAlpha * 0.85)

    /// Apple 公布的唯一数值门槛（取自 WCAG AA，Accessibility Inspector 用的就是它）：
    /// ≤17pt 任意字重 4.5:1；18pt 与任意尺寸 Bold 3:1。
    public static let bodyThreshold = 4.5
    public static let largeThreshold = 3.0

    /// 底衬的**可读性下限**。模型是"最坏壁纸"：浅色外观遇纯黑壁纸、深色外观遇纯白壁纸，
    /// 文字色与底衬色这时互相抵消。按此解出 `textBody` 要达 4.5:1，浅色需 ≥0.55、深色需 ≥0.65；
    /// 取 0.72 留余量（同时给 label 留出 8:1 以上）。
    /// 放在这里而不是 `Theme`，是因为 `Theme` 带 `@MainActor`，而设置项的默认值要在 init 里用。
    public static let minimumScrim = 0.72

    /// 系统「降低透明度」时面板走的那条不透明底，等效底衬就是 1.0（与壁纸完全脱钩）。
    /// 这是当前**唯一还能算**的面板底衬，玻璃那条算不出来（见顶部注释）。
    public static let opaqueFallbackScrim = 1.0

    // 以下三件已经随「额外压暗」功能一起删除，别再往回加：
    // `materialEquivalentScrim`（.popover 离屏实测保守值 0.694，代码曾写死 0.72）、
    // `combinedScrim(extraDim:)`、`extraDimRange` / `defaultExtraDim` / `clampExtra`。
    // 有没有偷偷加回来由 `ContrastAuditTests.backingIsGlassOnly` 这条源扫描门禁盯着。

    /// 最坏情况下，某档文字压在给定底衬上的对比度。
    /// - Parameters:
    ///   - darkText: true = 浅色外观（黑字，底衬是白，最坏壁纸是纯黑）
    ///   - inkAlpha: 文字的不透明度
    ///   - scrim: 底衬的不透明度
    public static func worstCase(darkText: Bool, inkAlpha: Double, scrim: Double) -> Double {
        // 底衬压在最坏壁纸上得到的灰度（0...255）
        let background = darkText ? 255.0 * scrim : 255.0 * (1.0 - scrim)
        // 文字再压上去
        let foreground = darkText
            ? background * (1.0 - inkAlpha)
            : background + (255.0 - background) * inkAlpha
        return ratio(foreground, background)
    }

    public static func ratio(_ a: Double, _ b: Double) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// WCAG 相对亮度；灰度下 R=G=B。
    private static func relativeLuminance(_ gray: Double) -> Double {
        func channel(_ v: Double) -> Double {
            let s = v / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let c = channel(gray)
        return 0.2126 * c + 0.7152 * c + 0.0722 * c
    }

    /// 让某档文字达到 `threshold` 所需的最小底衬。返回 >1 表示**无论多厚都达不到**。
    /// 底衬越厚对比度越高（两种外观都一样：厚到底衬就是不透明，与壁纸脱钩），所以二分成立。
    public static func requiredScrim(darkText: Bool, inkAlpha: Double,
                                    threshold: Double = bodyThreshold) -> Double {
        guard worstCase(darkText: darkText, inkAlpha: inkAlpha, scrim: 1.0) >= threshold
        else { return .infinity }
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if worstCase(darkText: darkText, inkAlpha: inkAlpha, scrim: mid) < threshold { low = mid }
            else { high = mid }
        }
        return high
    }
}
