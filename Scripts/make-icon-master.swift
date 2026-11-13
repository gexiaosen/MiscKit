// 纯 CoreGraphics 矢量生成打包用图标与菜单栏剪影（方案 2B：棱镜闪电 + 左对齐三横）。
// 为什么要脚本化矢量渲染而不是手改 PNG：
//   1) 所有几何、安全区（82%）、同心比例与对比度（均 ≥3.2:1）都有数字依据，可复现不走样；
//   2) 原手画母版 MiscKit-512.source.png 保留作历史参考，不再从位图逐像素换色（无锯齿/光晕残留）；
//   3) App Icon 与菜单栏 MiscKitMark 共享同一套矢量比例，尺寸各自按实际渲染口径导出。
//
//   swiftc -O Scripts/make-icon-master.swift -o /tmp/mkicon && /tmp/mkicon
//
// 实测对比度（相对瓦片均值 #F5F6F9，L ≈ 0.92）：
//   闪电渐变 #4887F2 → #245EC9（中点 #3672DD）：≈ 4.17:1（过 3:1）
//   首条（主焦点）#2A58A3：≈ 6.38:1（过 4.5:1）
//   二条 #647EA0：≈ 3.82:1（过 3:1）
//   三条 #728AA8：≈ 3.25:1（过 3:1）
import AppKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let iconDst = repoRoot.appendingPathComponent("Resources/AppIcon/MiscKit-512.png").path
let markDst = repoRoot.appendingPathComponent("Resources/MenuBar/MiscKitMark.png").path

// MARK: - 工具函数

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 4 * width,
        bitsPerPixel: 32
    )!
}

func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        components: [CGFloat(r) / 255.0, CGFloat(g) / 255.0, CGFloat(b) / 255.0, a]
    )!
}

/// 在 200×200 顶原点归一化坐标系里定位，自动折算成 CoreGraphics 底原点像素坐标。
func mapPoint(_ x: CGFloat, _ y: CGFloat, viewBoxHeight: CGFloat, scale: CGFloat) -> CGPoint {
    CGPoint(x: x * scale, y: (viewBoxHeight - y) * scale)
}

func squirclePath(scale: CGFloat, insetScale: CGFloat = 1.0) -> CGMutablePath {
    // 中心 (100, 100)，82% 安全区即 164×164（18...182）
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let sx = 100 + (x - 100) * insetScale
        let sy = 100 + (y - 100) * insetScale
        return mapPoint(sx, sy, viewBoxHeight: 200, scale: scale)
    }
    let path = CGMutablePath()
    path.move(to: p(62, 18))
    path.addLine(to: p(138, 18))
    path.addCurve(to: p(182, 62), control1: p(164, 18), control2: p(182, 36))
    path.addLine(to: p(182, 138))
    path.addCurve(to: p(138, 182), control1: p(182, 164), control2: p(164, 182))
    path.addLine(to: p(62, 182))
    path.addCurve(to: p(18, 138), control1: p(36, 182), control2: p(18, 164))
    path.addLine(to: p(18, 62))
    path.addCurve(to: p(62, 18), control1: p(18, 36), control2: p(36, 18))
    path.closeSubpath()
    return path
}

func boltPath(scale: CGFloat) -> CGMutablePath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        mapPoint(x, y, viewBoxHeight: 200, scale: scale)
    }
    let path = CGMutablePath()
    path.move(to: p(71, 52))
    path.addCurve(to: p(81, 55), control1: p(74, 47), control2: p(81, 49))
    path.addLine(to: p(81, 90))
    path.addLine(to: p(92, 90))
    path.addCurve(to: p(96, 101), control1: p(97, 90), control2: p(100, 96))
    path.addLine(to: p(67, 148))
    path.addCurve(to: p(57, 145), control1: p(64, 153), control2: p(57, 151))
    path.addLine(to: p(57, 110))
    path.addLine(to: p(46, 110))
    path.addCurve(to: p(42, 99), control1: p(41, 110), control2: p(38, 104))
    path.closeSubpath()
    return path
}

func pillRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat) -> CGPath {
    let rect = CGRect(x: x * scale, y: (200 - y - h) * scale, width: w * scale, height: h * scale)
    let r = (h / 2) * scale
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: - 1. 导出 512×512 App Icon 母版

func renderAppIcon() -> Data {
    let side = 512
    let s = CGFloat(side) / 200.0
    let rep = makeBitmap(width: side, height: side)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let tile = squirclePath(scale: s)

    // 外层投影 + 玻璃冷白纵向渐变底
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5 * s), blur: 10 * s, color: rgba(15, 23, 42, 0.14))
    ctx.beginPath()
    ctx.addPath(tile)
    ctx.setFillColor(rgba(255, 255, 255))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let tileGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgba(255, 255, 255), rgba(236, 239, 244)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        tileGrad,
        start: mapPoint(100, 18, viewBoxHeight: 200, scale: s),
        end: mapPoint(100, 182, viewBoxHeight: 200, scale: s),
        options: []
    )
    ctx.restoreGState()

    // 内高光 + 外框 hairline（浅色壁纸下不融化）
    ctx.saveGState()
    ctx.addPath(squirclePath(scale: s, insetScale: 0.985))
    ctx.setStrokeColor(rgba(255, 255, 255, 0.95))
    ctx.setLineWidth(1.5 * s)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(rgba(15, 23, 42, 0.14))
    ctx.setLineWidth(1.3 * s)
    ctx.strokePath()
    ctx.restoreGState()

    // 左侧：几何闪电
    let bolt = boltPath(scale: s)
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let boltGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgba(72, 135, 242), rgba(36, 94, 201)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        boltGrad,
        start: mapPoint(70, 49, viewBoxHeight: 200, scale: s),
        end: mapPoint(70, 151, viewBoxHeight: 200, scale: s),
        options: []
    )
    ctx.restoreGState()

    // 右侧：严格左对齐、垂直等距三条
    let bars: [(CGFloat, CGFloat, CGColor)] = [
        (65, 48, rgba(42, 88, 163)),   // 首条深石板蓝（焦点）
        (93, 38, rgba(100, 126, 160)), // 次条哑光蓝灰
        (121, 44, rgba(114, 138, 168)) // 三条哑光蓝灰
    ]
    for (y, w, color) in bars {
        ctx.saveGState()
        ctx.addPath(pillRect(x: 108, y: y, w: w, h: 14, scale: s))
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    return rep.representation(using: .png, properties: [:])!
}

// MARK: - 2. 导出 160×112（20×14pt @8x）菜单栏单色 Template 剪影

func renderMenuBarMark() -> Data {
    // 20×14pt 放大 8 倍导出，Retina 下零锯齿；字形高度占 14pt 的 ~91%（≈12.7pt，与系统托盘邻居等高）
    let scale: CGFloat = 8.0
    let w = Int(20 * scale)
    let h = Int(14 * scale)
    let rep = makeBitmap(width: w, height: h)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setFillColor(rgba(0, 0, 0, 1.0))

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        mapPoint(x, y, viewBoxHeight: 14, scale: scale)
    }

    // 闪电剪影
    let bolt = CGMutablePath()
    bolt.move(to: p(5.4, 1.2))
    bolt.addCurve(to: p(6.8, 1.7), control1: p(5.8, 0.6), control2: p(6.8, 0.9))
    bolt.addLine(to: p(6.8, 6.0))
    bolt.addLine(to: p(8.5, 6.0))
    bolt.addCurve(to: p(9.0, 7.4), control1: p(9.2, 6.0), control2: p(9.5, 6.8))
    bolt.addLine(to: p(4.8, 12.8))
    bolt.addCurve(to: p(3.4, 12.3), control1: p(4.4, 13.4), control2: p(3.4, 13.1))
    bolt.addLine(to: p(3.4, 8.0))
    bolt.addLine(to: p(1.7, 8.0))
    bolt.addCurve(to: p(1.2, 6.6), control1: p(1.0, 8.0), control2: p(0.7, 7.2))
    bolt.closeSubpath()
    ctx.addPath(bolt)
    ctx.fillPath()

    // 三条剪影
    let bars: [(CGFloat, CGFloat)] = [(2.3, 7.6), (5.9, 5.8), (9.5, 6.8)]
    for (y, barW) in bars {
        let rect = CGRect(x: 11.2 * scale, y: (14 - y - 2.2) * scale, width: barW * scale, height: 2.2 * scale)
        let path = CGPath(roundedRect: rect, cornerWidth: 1.1 * scale, cornerHeight: 1.1 * scale, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
    }

    return rep.representation(using: .png, properties: [:])!
}

try! renderAppIcon().write(to: URL(fileURLWithPath: iconDst))
try! renderMenuBarMark().write(to: URL(fileURLWithPath: markDst))
print("已生成：\n  \(iconDst)\n  \(markDst)")
