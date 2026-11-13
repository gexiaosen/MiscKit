import Foundation
import Testing

@testable import MiscKitCore

/// 面板可读性门禁。门槛取自 Apple 公布的唯一数值表（WCAG AA）：≤17pt 任意字重 4.5:1。
///
/// 2026-10-22 起面板底衬**只有玻璃一层**：`NSVisualEffectView` 材质与「额外压暗」都删了。
/// Liquid Glass 是 Metal 合成的，离屏采样拿不到读数，所以这里能算的只剩两件事：
/// ① 系统「降低透明度」那条不透明底是否达标（可算，已算）；
/// ② 墨色令牌本身够不够格承载正文（与底衬厚度无关的性质）。
/// 「玻璃上小字到底几点几」这一条**故意不在这里断言** —— 没验过的数字写进测试就等于造假。
@MainActor
@Suite("对比度门禁")
struct ContrastAuditTests {
    @Test("不透明底（系统开降低透明度时）两种外观都顶得住 4.5:1")
    func opaqueFallbackMeetsTheFloor() {
        let scrim = Contrast.opaqueFallbackScrim
        for darkText in [true, false] {
            let label = Contrast.worstCase(darkText: darkText, inkAlpha: Contrast.label.lightAlpha,
                                           scrim: scrim)
            let body = Contrast.worstCase(darkText: darkText, inkAlpha: Contrast.textBody.lightAlpha,
                                          scrim: scrim)
            #expect(label >= Contrast.bodyThreshold, "label 在不透明底上只有 \(label)")
            #expect(body >= Contrast.bodyThreshold, "textBody 在不透明底上只有 \(body)")
        }
    }

    /// 玻璃要顶得住小字，就得自己给到这个厚度。这两个数是选底衬档位的**门槛**，
    /// 不是"玻璃已经给到了"的结论 —— 后者只能真机肉眼判。
    @Test("记下玻璃必须达到的厚度：浅 ≥0.55 / 深 ≥0.65（玻璃本身给到多少，未核实）")
    func requiredThicknessIsPinned() {
        let light = Contrast.requiredScrim(darkText: true, inkAlpha: Contrast.textBody.lightAlpha)
        let dark = Contrast.requiredScrim(darkText: false, inkAlpha: Contrast.textBody.darkAlpha)
        #expect(0.54 < light && light < 0.57, "浅色这档漂到 \(light) 了")
        #expect(0.64 < dark && dark < 0.67, "深色这档漂到 \(dark) 了")
        // 深的那一极才是卡人的，所以下限按它写
        #expect(dark > light, "地板应该由深色那极决定")
        #expect(Contrast.minimumScrim >= dark, "写死的下限 \(Contrast.minimumScrim) 得盖住解出来的 \(dark)")
    }

    @Test("旧默认值 0.18 确实不达标——这条记录下限存在的理由")
    func oldDefaultWasUnreadable() {
        let lightLabel = Contrast.worstCase(darkText: true, inkAlpha: 0.85, scrim: 0.18)
        let darkLabel = Contrast.worstCase(darkText: false, inkAlpha: 0.85, scrim: 0.18)
        #expect(lightLabel < 2.0 && darkLabel < 2.0,
                "0.18 应当是不可读的量级，实测 \(lightLabel) / \(darkLabel)")
    }

    @Test("secondaryLabel 与 tertiaryLabel 在允许的最薄到不透明之间都不够格承载正文")
    func secondaryInksCannotCarryContent() {
        // 浅色外观的 secondaryLabel 是"无论多厚都到不了 4.5:1"（需要完全不透明）；
        // tertiary 连大字的 3:1 都够不到，只能当装饰。
        #expect(Contrast.requiredScrim(darkText: true, inkAlpha: Contrast.secondaryLabel.lightAlpha) > 0.99)
        #expect(Contrast.requiredScrim(darkText: true, inkAlpha: Contrast.tertiaryLabel.lightAlpha) == .infinity)
        #expect(Contrast.requiredScrim(darkText: false, inkAlpha: Contrast.tertiaryLabel.darkAlpha) == .infinity)
        for scrim in [Contrast.minimumScrim, Contrast.opaqueFallbackScrim] {
            #expect(Contrast.worstCase(darkText: true, inkAlpha: Contrast.secondaryLabel.lightAlpha,
                                       scrim: scrim) < Contrast.bodyThreshold)
            #expect(Contrast.worstCase(darkText: true, inkAlpha: Contrast.tertiaryLabel.lightAlpha,
                                       scrim: scrim) < Contrast.largeThreshold)
            #expect(Contrast.worstCase(darkText: false, inkAlpha: Contrast.tertiaryLabel.darkAlpha,
                                       scrim: scrim) < Contrast.largeThreshold)
            #expect(Contrast.worstCase(darkText: true, inkAlpha: Contrast.label.lightAlpha,
                                       scrim: scrim) >= Contrast.bodyThreshold)
            #expect(Contrast.worstCase(darkText: false, inkAlpha: Contrast.textBody.darkAlpha,
                                       scrim: scrim) >= Contrast.bodyThreshold)
        }
    }

    // MARK: 底衬形状门禁

    /// 「底衬只剩玻璃」这条决定要能被机器守住，不能只写在文档里。
    /// 谁把 `NSVisualEffectView` 或 `glassDim` 加回来，这里直接红；
    /// 玻璃层也只准出现在"底衬 + 选中 pill"这两处。
    @Test("玻璃只准两处：面板底衬与选中行，且一律不上色")
    func backingIsGlassOnly() throws {
        let ui = try sourceFiles(under: "Sources/MiscKit").mapValues(codeOnly)
        let banned = ["NSVisualEffectView", "glassDim", "PanelMaterial", "combinedScrim"]
        for (url, text) in ui {
            for needle in banned {
                #expect(!text.contains(needle),
                        "\(url.lastPathComponent) 里出现了 \(needle)：压暗层与材质已经删掉了")
            }
        }
        let glassHits = ui.filter { $0.value.contains(".glassEffect(") }
            .map(\.key.lastPathComponent).sorted()
        #expect(glassHits == ["Components.swift", "LauncherView.swift"],
                "玻璃层出现在 \(glassHits)：底衬与选中 pill 之外不许再加")
        // 设置窗那层"稍微有点透"的中性底衬只准有一个落点（ChromeGlass 里那一处）。
        // 它不是当年被删掉的压暗层：不许再往别处垫第二层。
        let backingHits = ui.filter { $0.value.contains("Theme.chromeBacking") }
            .map(\.key.lastPathComponent).sorted()
        #expect(backingHits == ["Components.swift"], "chromeBacking 出现在 \(backingHits)")

        // 玻璃不上色（实测否决过两次：tint 会把 11pt 副标题冲掉）。以前只是文档里的一句话。
        // 扫整个 Sources：`Theme.panelGlass` 与 `RowSelection.glass` 都在 Core，只扫 UI 会漏
        let all = try sourceFiles(under: "Sources").mapValues(codeOnly)
        let tinted = all.filter { $0.value.contains(".tint(") }.map(\.key.lastPathComponent).sorted()
        #expect(tinted.isEmpty, "这些文件给玻璃上了色：\(tinted)")
    }

    /// 门禁盯的是代码，不是散文 —— 注释里当然可以写"当年那个材质叫什么"。
    /// 整行注释与文档注释直接跳过，行尾注释从 ` //` 处切掉（`https://` 不会误伤）。
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            let line = String(raw).drop(while: { $0 == " " || $0 == "\t" })
            if line.hasPrefix("//") || line.hasPrefix("*") { return nil }
            if let slashes = line.range(of: " //") { return String(line[..<slashes.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    /// 系统开降低透明度时走不透明分支，这条不许被顺手删掉。
    @Test("降低透明度时必须换成不透明底")
    func reduceTransparencyStillGetsOpaqueBacking() throws {
        let launcher = try sourceText(of: "Sources/MiscKit/UI/LauncherView.swift")
        #expect(launcher.contains("a11y.panelShouldBeOpaque"))
        #expect(launcher.contains("Theme.dimColor(for: colorScheme).opacity(1)"))
    }

    /// 提示词必须自己画，不许再交回 TextField 内置的 placeholder：那一层是 AppKit 字段编辑器
    /// **随视口**绘制的，长串一路删空后视口还停在右边，提示词就被顶出左边界看不见（2026-11-09 他实测）。
    /// 而且"空"要以字段编辑器为准：输入法合成中的拼音不进绑定（实测 `editor.string="ge"` 而绑定仍空，
    /// `setMarkedText` 连文本变更通知都不发），只看绑定就会让提示词压在拼音上。
    @Test("输入框提示词由我们自己画，不吃字段编辑器的滚动，也不漏拼音")
    func searchHintIsDrawnByUs() throws {
        let launcher = try sourceText(of: "Sources/MiscKit/UI/LauncherView.swift")
        #expect(launcher.contains("TextField(\"\", text: binding)"),
                "输入框又拿 placeholderText 当内置 placeholder 了：那条会被滚出左边界")
        #expect(launcher.contains("Text(settings.placeholderText)"), "提示词那一层不见了")
        #expect(launcher.contains("Theme.searchHint"), "提示词得走颜色令牌")
        #expect(launcher.contains("fieldEditor?.string.isEmpty"),
                "提示词只看绑定就收：合成中的拼音不进绑定，会和提示词叠在一起")
    }

    /// 棘轮：装饰色承载正文的历史欠账**只准变短**。
    /// 迁移目标是 `Theme.textBody`（正文）或 `Theme.decorationOnly`（确实是装饰时）。
    /// 账目：2026-10-21 登记 70 → 材质批次扫掉启动器一处后收到 69 → 2026-10-27 全部迁完归零。
    /// 现在这条是零容忍门禁：再出现一处 `Theme.tertiaryText` 直接红。
    private let tertiaryLedgerCeiling = 0

    @Test("Theme.tertiaryText 的用处数不得超过登记的上限")
    func tertiaryUsageRatchet() throws {
        let ui = try sourceFiles(under: "Sources")
        let count = ui.values.reduce(0) { $0 + $1.components(separatedBy: "Theme.tertiaryText").count - 1 }
        #expect(count <= tertiaryLedgerCeiling,
                "tertiaryText 从 \(tertiaryLedgerCeiling) 涨到 \(count) 了：玻璃上的正文请用 Theme.textBody")
    }

    /// 语义状态色必须走 Theme 令牌（高对比度适配），不得裸写系统 `.red` / `.orange`。
    @Test("Sources 中不允许裸用系统 .red / .orange 语义色")
    func rawRedAndOrangeAreBanned() throws {
        let all = try sourceFiles(under: "Sources").mapValues(codeOnly)
        let banned = [".foregroundStyle(.red)", ".foregroundStyle(.orange)", "Color.red", "Color.orange"]
        var offenders: [String] = []
        for (url, text) in all {
            for needle in banned where text.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        #expect(offenders.isEmpty, "请改用 Theme.errorText / Theme.warningText：\(offenders)")
    }

    // MARK: 读源码的小工具

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/MiscKitCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private func sourceText(of relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func sourceFiles(under relative: String) throws -> [URL: String] {
        let root = repoRoot.appendingPathComponent(relative, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil) else {
            throw GateError("找不到 \(relative)，门禁失效就是门禁没跑")
        }
        var out: [URL: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out[url] = text
        }
        // 一条都读不到通常意味着路径写错了，而不是代码真的干净
        guard out.isEmpty == false else { throw GateError("\(relative) 下没扫到任何 swift 文件") }
        return out
    }

    private struct GateError: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }
}
