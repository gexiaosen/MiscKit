import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import MiscKitCore

@MainActor
private final class StubTool: Tool {
    let id: ToolID
    let title: String
    let symbol = "app"
    let capabilities: Set<Capability>
    let triggers: [TriggerDescriptor]

    init(id: String, capabilities: Set<Capability> = [], triggers: [TriggerDescriptor]) {
        self.id = ToolID(id)
        self.title = id
        self.capabilities = capabilities
        self.triggers = triggers
    }

    func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        [ToolResult(toolID: id, title: title, subtitle: "", symbol: symbol, score: hit.score)]
    }
}

// MARK: 触发语义

@Test("关键词打分：完全相等 > 前缀 > 包含，不匹配返回 nil")
func keywordScoring() {
    let trigger = TriggerDescriptor(code: "apps", title: "应用", kind: .keyword(["safari", "浏览器"]))
    #expect(trigger.match(MatchInput(text: "safari"))?.score == 100)
    #expect(trigger.match(MatchInput(text: "saf"))?.score == 80)
    #expect(trigger.match(MatchInput(text: "lan")) == nil)
    #expect(trigger.match(MatchInput(text: "  ")) == nil)

    let contains = TriggerDescriptor(code: "chrome", title: "浏览器", kind: .keyword(["googlechrome"]))
    #expect(contains.match(MatchInput(text: "chrome"))?.score == 60)
    #expect(contains.match(MatchInput(text: "CHROME"))?.score == 60, "大小写不敏感")
}

@Test("关键词带参数命中：空格切分前缀精确命中，无关相似前缀不误伤")
func keywordWithArgumentScoring() {
    let trigger = TriggerDescriptor(code: "dict", title: "Dictionary", kind: .keyword(["dict", "查词"]))
    let hit = trigger.match(MatchInput(text: "dict apple"))
    #expect(hit?.score == 90)
    #expect(hit?.highlight == "dict")

    let cjkHit = trigger.match(MatchInput(text: "查词 apple"))
    #expect(cjkHit?.score == 90)
    #expect(cjkHit?.highlight == "查词")

    // 无空格的长词不是 "dict + 参数"，不应按 90 分参数分支误命中
    #expect(trigger.match(MatchInput(text: "dictionary")) == nil)
    #expect(trigger.match(MatchInput(text: "predict")) == nil)
}

@Test("正则命中返回匹配片段")
func regexHighlight() {
    let trigger = TriggerDescriptor(code: "meeting", title: "会议号",
                                    kind: .regex(pattern: #"\d{3}-\d{3}-\d{3}"#, label: "会议号"))
    let hit = trigger.match(MatchInput(text: "腾讯会议：123-456-789 请提前入会"))
    #expect(hit?.highlight == "123-456-789")
    #expect(trigger.match(MatchInput(text: "没有号码")) == nil)
}

@Test("文件触发受扩展名与类型约束")
func fileTrigger() {
    let trigger = TriggerDescriptor(code: "csv", title: "表格",
                                    kind: .files(label: "文件", fileType: .file, extensions: ["csv", "xlsx"]))
    #expect(trigger.match(MatchInput(fileURLs: [URL(fileURLWithPath: "/tmp/a.csv")])) != nil)
    #expect(trigger.match(MatchInput(fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])) == nil)
    let dirs = TriggerDescriptor(code: "d", title: "目录",
                                 kind: .files(label: "目录", fileType: .directory, extensions: []))
    #expect(dirs.match(MatchInput(fileURLs: [URL(fileURLWithPath: "/tmp", isDirectory: true)])) != nil)
    #expect(dirs.match(MatchInput(fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])) == nil)
}

@Test("同一输入取最高分触发器")
@MainActor
func bestTriggerWins() {
    let tool = StubTool(id: "multi", triggers: [
        TriggerDescriptor(code: "weak", title: "弱", kind: .text(label: "任意文本", minLength: 1)),
        TriggerDescriptor(code: "strong", title: "强", kind: .keyword(["otp"])),
    ])
    let hit = tool.triggers.compactMap { $0.match(MatchInput(text: "otp")) }.max { $0.score < $1.score }
    #expect(hit?.score == 100)
}

@Test("任意输入都产出「搜索文件」动作行")
@MainActor
func fileActionRowForAnyText() {
    let tool = FilesTool()
    let input = MatchInput(text: "示例报价")
    let hit = tool.triggers.compactMap { $0.match(input) }.max { $0.score < $1.score }
    #expect(hit != nil)

    let rows = tool.results(for: input, hit: hit ?? MatchHit(score: 0))
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.toolID == ToolID("files"))
    #expect(row.score == FilesTool.searchRowScore)
    // 副标题以前是「按「示例报价」搜索文件名与内容」——每个查询都重复一遍自己在干什么，
    // 属冗余文案，已删；这一行只留标题。
    #expect(row.subtitle.isEmpty)
    #expect(row.highlight == "")
    var opened: ToolID?
    if case .openTool(let id) = row.action { opened = id }
    #expect(opened == ToolID("files"))
}

@Test("提醒与 hosts 入口行不带说明句（文案已按「只留真信息」删净）")
@MainActor
func workspaceEntryRowsAreBare() {
    let pairs: [(any Tool, String)] = [(ReminderTool(), "提醒"), (HostsTool(), "hosts")]
    for (tool, text) in pairs {
        let input = MatchInput(text: text)
        let hit = tool.triggers.compactMap { $0.match(input) }.max { $0.score < $1.score }
        #expect(hit != nil, "\(tool.title) 应能被自己的关键词命中")
        let rows = tool.results(for: input, hit: hit ?? MatchHit(score: 0))
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.subtitle.isEmpty }, "\(tool.title) 的入口行不该带回解说文案")
    }
}

// MARK: 能力门控

@Test("未满足能力声明的工具不参评；撤销后恢复")
@MainActor
func capabilityGateBlocksTool() {
    let registry = ToolRegistry.shared
    let tool = StubTool(id: "gated-test", capabilities: [.keychain],
                        triggers: [TriggerDescriptor(code: "k", title: "k", kind: .keyword(["gatedtest"]))])
    registry.register(tool)
    defer { CapabilityGrant.shared.restore(tool.id) }

    #expect(registry.bestHit(for: tool, input: MatchInput(text: "gatedtest")) != nil)
    CapabilityGrant.shared.revoke([.keychain], for: tool.id)
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "gatedtest")) == nil)
    CapabilityGrant.shared.restore(tool.id)
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "gatedtest")) != nil)
}

@Test("聚合结果按分数降序")
@MainActor
func rankedResultsSortByScore() {
    let registry = ToolRegistry.shared
    registry.register(StubTool(id: "rank-low",
                               triggers: [TriggerDescriptor(code: "l", title: "l", kind: .keyword(["rankme"]))]))
    registry.register(StubTool(id: "rank-high",
                               triggers: [TriggerDescriptor(code: "h", title: "h",
                                                            kind: .keyword(["rankme", "rankme"]))]))
    let rows = registry.rankedResults(for: MatchInput(text: "rankme"))
    #expect(!rows.isEmpty)
    #expect(rows.first?.score == 100)
    for i in 1..<rows.count { #expect(rows[i - 1].score >= rows[i].score) }
}

@Test("聚合结果补齐来源标签与触发高亮")
@MainActor
func rankedResultsDecorate() {
    let registry = ToolRegistry.shared
    registry.register(StubTool(id: "deco-test",
                               triggers: [TriggerDescriptor(code: "d", title: "d",
                                                            kind: .keyword(["decorateme"]))]))
    let rows = registry.rankedResults(for: MatchInput(text: "decorateme"))
    let row = rows.first { $0.toolID.rawValue == "deco-test" }
    #expect(row?.source == "deco-test")
    #expect(row?.highlight == "decorateme")
}

// MARK: 快捷键

@Test("⌥Z 显示名与 keyCode 映射")
func hotkeyDisplay() {
    #expect(HotkeyCombo.defaultSummon.displayString == "⌥Z")
    #expect(HotkeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey))
                .displayString == "⇧⌘A")
}

@Test("无修饰键的组合无效，不能注册")
func hotkeyRequiresModifier() {
    #expect(!HotkeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0).isValid)
    #expect(HotkeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey)).isValid)
}

@Test("Codable 往返，保证设置持久化不丢键位")
func hotkeyCodable() throws {
    let data = try JSONEncoder().encode(HotkeyCombo.defaultSummon)
    let back = try JSONDecoder().decode(HotkeyCombo.self, from: data)
    #expect(back == HotkeyCombo.defaultSummon)
}

// MARK: 功能开关（设置「功能」页）

@Test("关掉的功能：关键词不参评、入口行消失，恢复后又回来")
@MainActor
func disabledToolLeavesMatching() {
    let registry = ToolRegistry.shared
    let tool = StubTool(id: "gate-off",
                        triggers: [TriggerDescriptor(code: "g", title: "g",
                                                     kind: .keyword(["gateoffme"]))])
    registry.register(tool)
    let production = registry.enabledCheck
    defer { registry.enabledCheck = production }

    // 正对照：没关时两处都真的出现，否则下面的"消失"可能压根不是开关造成的
    registry.enabledCheck = { _ in true }
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "gateoffme"))?.score == 100)
    #expect(registry.rankedResults(for: MatchInput(text: "gateoffme")).contains { $0.toolID == tool.id })
    #expect(registry.rankedResults(for: MatchInput(text: "")).contains { $0.toolID == tool.id })

    registry.enabledCheck = { $0 != tool.id }
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "gateoffme")) == nil)
    #expect(!registry.rankedResults(for: MatchInput(text: "gateoffme")).contains { $0.toolID == tool.id },
            "输入框还能撞出这条行，说明关掉只是藏起来了")
    #expect(!registry.rankedResults(for: MatchInput(text: "")).contains { $0.toolID == tool.id })

    registry.enabledCheck = production
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "gateoffme"))?.score == 100)
}

@Test("弱命中跟主开关走：关键词关了，任意文本那条也不参评")
@MainActor
func disabledToolAlsoDropsWeakMatch() {
    let registry = ToolRegistry.shared
    let tool = StubTool(id: "gate-weak", triggers: [
        TriggerDescriptor(code: "k", title: "k", kind: .keyword(["gateweak"])),
        TriggerDescriptor(code: "any", title: "any", kind: .text(label: "任意文本", minLength: 1)),
    ])
    registry.register(tool)
    let production = registry.enabledCheck
    defer { registry.enabledCheck = production }

    registry.enabledCheck = { _ in true }
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "随便什么"))?.score == 40)
    registry.enabledCheck = { $0 != tool.id }
    #expect(registry.bestHit(for: tool, input: MatchInput(text: "随便什么")) == nil)
}

@Test("触发类型 → 设置页那句话：关键词不产句，文本给长度")
func triggersMapToSettingsCopy() {
    #expect(TriggerDescriptor(code: "a", title: "a", kind: .keyword(["x", "y"])).keywordWords
            == ["x", "y"])
    #expect(TriggerDescriptor(code: "b", title: "b", kind: .keyword(["x"])).weakHint == nil)
    L10n.withLanguage(.zhHans) {
        #expect(TriggerDescriptor(code: "c", title: "c",
                                  kind: .text(label: "搜索文件", minLength: 1)).weakHint
                == "任意文本（搜索文件）")
        #expect(TriggerDescriptor(code: "d", title: "d",
                                  kind: .text(label: "会议号", minLength: 9)).weakHint
                == "≥9 字符（会议号）")
        #expect(TriggerDescriptor(code: "e", title: "e",
                                  kind: .files(label: "文件", fileType: .file,
                                               extensions: ["csv"])).weakHint == "文件")
    }
    L10n.withLanguage(.en) {
        #expect(TriggerDescriptor(code: "c", title: "c",
                                  kind: .text(label: "Search Files", minLength: 1)).weakHint
                == "Any text (Search Files)")
        #expect(TriggerDescriptor(code: "d", title: "d",
                                  kind: .text(label: "Meeting ID", minLength: 9)).weakHint
                == "≥9 chars (Meeting ID)")
        #expect(TriggerDescriptor(code: "e", title: "e",
                                  kind: .files(label: "Files", fileType: .file,
                                               extensions: ["csv"])).weakHint == "Files")
    }
}

@Test("内建功能全都能被设置页列出来：每行都有名字、图标和词或入口")
@MainActor
func everyBuiltinToolIsListable() {
    let tools = BuiltinTools.ordered
    #expect(tools.count == 11)
    for tool in tools {
        #expect(!tool.title.isEmpty, "「\(tool.id)」没有名字，设置页只能显示空白")
        #expect(!tool.symbol.isEmpty, "「\(tool.id)」没有图标")
        #expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil,
                "「\(tool.id)」的图标 \(tool.symbol) 不是有效 SF Symbol，界面上会是一片空白")
        let words = tool.triggers.flatMap(\.keywordWords)
        let hints = tool.triggers.compactMap(\.weakHint)
        #expect(!words.isEmpty || !hints.isEmpty || !tool.entries.isEmpty,
                "「\(tool.id)」既没有唤醒词也没有入口，列出来是一行空白")
    }
    // 会议是唯一没有关键词的一件：它靠 ≥9 字符参与识别
    let meeting = tools.first { $0.id == .meeting }
    #expect(meeting?.triggers.flatMap(\.keywordWords).isEmpty == true)
    #expect(meeting?.triggers.compactMap(\.weakHint).first?.contains("9") == true)
}

@Test("系统动作的图标都是有效 SF Symbol")
@MainActor
func everySystemActionSymbolExists() {
    for action in SystemActionCatalog.all {
        #expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil,
                "「\(action.title)」的图标 \(action.symbol) 不存在，行首会空一块")
    }
}
