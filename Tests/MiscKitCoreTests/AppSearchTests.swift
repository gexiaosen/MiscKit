import Foundation
import Testing

@testable import MiscKitCore

private func makeApp(id: String = "com.example.demo", name: String,
                     searchNames: [String] = [],
                     path: String = "/Applications/Demo.app") -> InstalledApp {
    InstalledApp(id: id, bundleID: id, url: URL(fileURLWithPath: path),
                 name: name, searchNames: searchNames)
}

// MARK: 拼音与名称形态

@Test("拼音与首字母由系统音译生成")
func pinyinAndInitials() {
    let app = makeApp(name: "腾讯会议", searchNames: ["TencentMeeting"])
    #expect(app.compactName == "腾讯会议")
    #expect(app.pinyin == "tengxunhuiyi")
    #expect(app.initials == "txhy")
}

@Test("多音字按词组转换：重庆银行")
func polyphonePinyin() {
    let app = makeApp(name: "重庆银行")
    #expect(app.pinyin == "chongqingyinxing")
    #expect(app.initials == "cqyx")
}

@Test("compact 抹平大小写、空格与连字符")
func compactNormalization() {
    #expect(AppTextNormalizer.compact("Tencent Meeting") == "tencentmeeting")
    #expect(AppTextNormalizer.compact("tencent-meeting") == "tencentmeeting")
    #expect(AppTextNormalizer.compact(" 腾讯 会议 ") == "腾讯会议")
}

// MARK: 四种输入形态

@Test("中文名、英文名、全拼、首字母都能命中")
func fourQueryForms() {
    let app = makeApp(name: "腾讯会议", searchNames: ["TencentMeeting"])
    let cases: [(query: String, basis: AppMatch.Basis, score: Int)] = [
        ("腾讯会议", .name, 98),
        ("Tencent Meeting", .keyword, 96),
        ("tengxunhuiyi", .pinyin, 92),
        ("txhy", .initials, 90),
    ]
    for item in cases {
        let match = AppMatcher.match(query: item.query, app: app, aliases: [])
        #expect(match?.basis == item.basis, "\(item.query)")
        #expect(match?.score == item.score, "\(item.query)")
    }
    #expect(AppMatcher.match(query: "tencentme", app: app, aliases: [])?.score == 90)
    #expect(AppMatcher.match(query: "会议", app: app, aliases: [])?.score == 86)
    #expect(AppMatcher.match(query: "nope", app: app, aliases: []) == nil)
    #expect(AppMatcher.match(query: " txhy ", app: app, aliases: [])?.score == 90)
    #expect(AppMatcher.match(query: "   ", app: app, aliases: []) == nil)
}

@Test("单字母不靠首字母兜底，只走拼音/名称前缀")
func singleLetterSkipsInitials() {
    let app = makeApp(name: "微信")
    // 首字母分支要求 ≥2 字符；单字母仍会命中拼音前缀
    #expect(AppMatcher.match(query: "w", app: app, aliases: [])?.basis == .pinyin)
    #expect(AppMatcher.match(query: "wx", app: app, aliases: [])?.basis == .initials)
}

// MARK: 别名与常用度

@Test("别名精确命中优先级最高")
func aliasExactWins() {
    let app = makeApp(name: "腾讯会议", searchNames: ["TencentMeeting"])
    let match = AppMatcher.match(query: "开会", app: app, aliases: ["开会"])
    #expect(match?.score == 100)
    #expect(match?.basis == .alias)
    // 别名前缀（88）不该压过名称精确（98）
    let nameWins = AppMatcher.match(query: "腾讯会议", app: app, aliases: ["腾讯会议啊"])
    #expect(nameWins?.basis == .name)
    #expect(nameWins?.score == 98)
}

@Test("常用度加成封顶 6 分，总分不超过 100")
func usageBoostCaps() {
    let app = makeApp(name: "腾讯会议")
    #expect(AppMatcher.match(query: "腾讯会", app: app, aliases: [], usageBoost: 0)?.score == 94)
    #expect(AppMatcher.match(query: "腾讯会", app: app, aliases: [], usageBoost: 3)?.score == 97)
    #expect(AppMatcher.match(query: "腾讯会", app: app, aliases: [], usageBoost: 99)?.score == 100)
    #expect(AppMatcher.match(query: "腾讯会议", app: app, aliases: [], usageBoost: 99)?.score == 100)
    #expect(AppMatcher.match(query: "腾讯会", app: app, aliases: [], usageBoost: -5)?.score == 94)
}

@Test("高亮只取名称里的原文片段，拼音命中不高亮")
func matchHighlight() {
    let app = makeApp(name: "腾讯会议")
    #expect(AppMatcher.match(query: "会议", app: app, aliases: [])?.highlight == "会议")
    #expect(AppMatcher.match(query: "腾讯会议", app: app, aliases: [])?.highlight == "腾讯会议")
    #expect(AppMatcher.match(query: "txhy", app: app, aliases: [])?.highlight == nil)
}

// MARK: 扫描与去重

@Test("路径位次：/Applications < ~/Applications < /System < /Volumes < 其它")
func pathRankOrder() {
    let home = "/Users/tester"
    #expect(AppScanner.pathRank("/Applications/A.app", home: home) == 0)
    #expect(AppScanner.pathRank("/Users/tester/Applications/A.app", home: home) == 1)
    #expect(AppScanner.pathRank("/System/Applications/A.app", home: home) == 2)
    #expect(AppScanner.pathRank("/Volumes/Disk/Applications/A.app", home: home) == 3)
    #expect(AppScanner.pathRank("/opt/A.app", home: home) == 4)
}

@Test("同 bundleID 只留一份，/Applications 优先")
func dedupePrefersPrimaryApplications() {
    let home = "/Users/tester"
    let apps = [
        makeApp(id: "com.example.app", name: "Demo",
                path: "/Volumes/Backup/Applications/Demo.app"),
        makeApp(id: "com.example.app", name: "Demo",
                path: "/Users/tester/Applications/Demo.app"),
        makeApp(id: "com.example.app", name: "Demo", path: "/Applications/Demo.app"),
    ]
    let deduped = AppScanner.dedupe(apps, home: home)
    #expect(deduped.count == 1)
    #expect(deduped.first?.url.path == "/Applications/Demo.app")
}

@Test("没有 bundleID 时按路径区分，不误合并")
func dedupeKeepsDistinctPathsWithoutBundleID() {
    let home = "/Users/tester"
    let apps = [
        InstalledApp(id: "/Applications/A.app", bundleID: nil,
                     url: URL(fileURLWithPath: "/Applications/A.app"),
                     name: "A", searchNames: []),
        InstalledApp(id: "/Applications/B.app", bundleID: nil,
                     url: URL(fileURLWithPath: "/Applications/B.app"),
                     name: "B", searchNames: []),
    ]
    #expect(AppScanner.dedupe(apps, home: home).count == 2)
}

// MARK: 注册表排序

@MainActor
private final class PriorityTool: Tool {
    let id: ToolID
    let title: String
    let symbol = "app"
    let capabilities: Set<Capability> = []
    let triggers: [TriggerDescriptor]
    private let priority: Int

    init(id: String, priority: Int) {
        self.id = ToolID(id)
        self.title = id
        self.priority = priority
        self.triggers = [TriggerDescriptor(code: "k", title: "k", kind: .keyword(["priotie"]))]
    }

    func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        [ToolResult(toolID: id, title: title, score: hit.score, sortPriority: priority,
                    key: "prio:\(id.rawValue)")]
    }
}

@Test("同分时 sortPriority 高的排前")
@MainActor
func sortPriorityBreaksTies() {
    let registry = ToolRegistry.shared
    registry.register(PriorityTool(id: "prio-app", priority: 10))
    registry.register(PriorityTool(id: "prio-tool", priority: 0))
    let rows = registry.rankedResults(for: MatchInput(text: "priotie"))
    #expect(rows.map(\.toolID.rawValue).prefix(2) == ["prio-app", "prio-tool"])
}

@Test("结果行保留稳定 key 与应用图标 URL")
@MainActor
func resultIdentityAndIcon() {
    let registry = ToolRegistry.shared
    let url = URL(fileURLWithPath: "/Applications/Demo.app")
    let tool = StubIconTool(iconURL: url)
    registry.register(tool)
    let rows = registry.rankedResults(for: MatchInput(text: "icontie"))
    #expect(rows.first?.key == "icon:com.example.demo")
    #expect(rows.first?.iconURL == url)
}

@MainActor
private final class StubIconTool: Tool {
    let id = ToolID("icon-test")
    let title = "图标"
    let symbol = "app"
    let capabilities: Set<Capability> = []
    let triggers = [TriggerDescriptor(code: "k", title: "k", kind: .keyword(["icontie"]))]
    private let iconURL: URL

    init(iconURL: URL) { self.iconURL = iconURL }

    func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        [ToolResult(toolID: id, title: "Demo", score: hit.score, iconURL: iconURL,
                    key: "icon:com.example.demo")]
    }
}

// MARK: 拉起后的判活匹配

@Test("没有 bundleID 的应用按包路径匹配，不被误判成「起不来」")
func matchesPathBasedAppID() {
    let url = URL(fileURLWithPath: "/Applications/Utilities/Something.app")
    #expect(ActionDispatcher.matchesAppID(bundleID: nil, bundleURL: url, appID: url.path))
    #expect(ActionDispatcher.matchesAppID(bundleID: "com.example.something",
                                          bundleURL: url, appID: "com.example.something"))
    #expect(!ActionDispatcher.matchesAppID(bundleID: nil, bundleURL: url,
                                           appID: "/Applications/Other.app"))
    #expect(!ActionDispatcher.matchesAppID(bundleID: nil, bundleURL: nil, appID: "/x.app"))
    #expect(!ActionDispatcher.matchesAppID(bundleID: "com.example.a", bundleURL: url,
                                           appID: "com.example.b"))
}

@Test("在终端打开：目录用自己，文件用上一层")
@MainActor
func directoryTargetForTerminal() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("misckit-dir-target-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)

    #expect(ActionDispatcher.directoryTarget(for: file).path == dir.path)
    #expect(ActionDispatcher.directoryTarget(for: dir).path == dir.path)
    #expect(ActionDispatcher.directoryTarget(for: dir.appendingPathComponent("ghost.txt")).path == dir.path,
            "路径已不存在时退回上一层，仍给一个能打开的目录")
}

@Test("系统应用的名字跟随 Finder 显示名，英文名仍留在别名里")
func systemAppUsesFinderDisplayName() {
    let apps = AppScanner().scan()
    guard let notes = apps.first(where: { $0.bundleID == "com.apple.Notes" }) else { return }
    // 名字的真相源是 Spotlight 显示名；索引没开或系统语言是英文时无从比较，跳过
    guard let expected = NSMetadataItem(url: notes.url)?
        .value(forAttribute: "kMDItemDisplayName") as? String,
          expected != "Notes" else { return }
    #expect(notes.name == expected, "系统应用的中文名不在 InfoPlist.strings 里，只能从 Spotlight 元数据取")
    #expect(notes.searchNames.contains("Notes"), "换成中文主名后，英文名必须还能搜到")
}

@Test("符号链接形式的系统应用也能进索引（Safari 指向 Cryptexes）")
func symlinkedSystemAppIsIndexed() {
    guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else { return }
    let apps = AppScanner().scan()
    let safari = apps.first { $0.bundleID == "com.apple.Safari" }
    #expect(safari != nil, "枚举器不交符号链接，根目录这一层必须单独扫")
    #expect(safari?.name.contains("Safari") == true)
}
