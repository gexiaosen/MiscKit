import Foundation
import Testing

@testable import MiscKitCore

/// 结果行上的动作只有一张表：右键菜单与输入框「对象 动作词」都从 `RowActionCatalog` 取。
/// 这里既测匹配语义，也钉住「不许在视图里再手写一遍动作清单」。
@MainActor
@Suite("结果行动作")
struct RowActionTests {
    private let app = InstalledApp(id: "com.test.foo", bundleID: "com.test.foo",
                                   url: URL(fileURLWithPath: "/Applications/Foo.app"),
                                   name: "Foo")

    // MARK: 切分

    @Test("只切最后一刀：对象名自己带空格也认")
    func splitTakesLastToken() {
        let simple = RowActionCatalog.split("chrome 拷")
        #expect(simple?.object == "chrome")
        #expect(simple?.action == "拷")

        let spaced = RowActionCatalog.split("Adobe Photoshop 拷")
        #expect(spaced?.object == "Adobe Photoshop")
        #expect(spaced?.action == "拷")
    }

    @Test("前后与中间的多余空白不算对象的一部分")
    func splitTrims() {
        let split = RowActionCatalog.split("  chrome   拷贝路径  ")
        #expect(split?.object == "chrome")
        #expect(split?.action == "拷贝路径")
    }

    @Test("只有一段就不是动作查询——普通应用名不能被判成对象+动作")
    func splitNeedsTwoParts() {
        #expect(RowActionCatalog.split("chrome") == nil)
        #expect(RowActionCatalog.split("  chrome  ") == nil)
        #expect(RowActionCatalog.split("") == nil)
        #expect(RowActionCatalog.split("chrome   ") == nil)
    }

    // MARK: 匹配

    @Test("整词命中排在包含命中前面")
    func exactBeatsContains() {
        let hits = RowActionCatalog.match("退出")
        #expect(hits.map(\.code) == ["quit", "forceQuit"])
    }

    @Test("打半个词就看见全部候选：这正是不要 ⌘K 的理由")
    func partialTermListsCandidates() {
        let hits = RowActionCatalog.match("终")
        #expect(hits.contains { $0.code == "terminal" })
    }

    @Test("拷贝路径只在右键菜单里，输入框不再给第二个入口")
    func copyPathIsContextMenuOnly() {
        #expect(RowActionCatalog.app.contains { $0.code == "copyPath" })
        #expect(RowActionCatalog.available(isRunning: false).contains { $0.code == "copyPath" })
        #expect(!RowActionCatalog.match("拷").contains { $0.code == "copyPath" })
        #expect(!RowActionCatalog.match("拷贝路径").contains { $0.code == "copyPath" })
        #expect(!RowActionCatalog.match("path").contains { $0.code == "copyPath" })
    }

    @Test("中文、拼音、英文三条路都通")
    func threeSpellings() {
        #expect(RowActionCatalog.match("终端").map(\.code) == ["terminal"])
        #expect(RowActionCatalog.match("zhongduan").map(\.code) == ["terminal"])
        #expect(RowActionCatalog.match("terminal").map(\.code) == ["terminal"])
        #expect(RowActionCatalog.match("TERMINAL").map(\.code) == ["terminal"])
    }

    @Test("同分保持声明顺序，低档位排在后面")
    func tiesKeepDeclarationOrder() {
        // quit / forceQuit 都是前缀命中，relaunch 只靠拼音 cq 的包含命中，档位更低。
        let hits = RowActionCatalog.match("q")
        #expect(hits.map(\.code) == ["quit", "forceQuit", "relaunch"])
    }

    @Test("空词与生词都不出动作")
    func noMatch() {
        #expect(RowActionCatalog.match("").isEmpty)
        #expect(RowActionCatalog.match("   ").isEmpty)
        #expect(RowActionCatalog.match("zzzzz").isEmpty)
    }

    // MARK: 可用性与执行语义

    @Test("没在运行就不给退出/重启/强制退出")
    func quitNeedsRunning() {
        let codes = Set(RowActionCatalog.available(isRunning: false).map(\.code))
        #expect(!codes.contains("quit"))
        #expect(!codes.contains("relaunch"))
        #expect(!codes.contains("forceQuit"))
        #expect(codes.contains("open"))
        #expect(codes.contains("copyPath"))
        #expect(RowActionCatalog.available(isRunning: true).count == RowActionCatalog.app.count)
    }

    @Test("每个声明的动作都有执行语义——加了动作忘了接线会静默变成 .none")
    func everyActionIsMapped() {
        for action in RowActionCatalog.app {
            #expect(isMapped(action.code), "动作 \(action.code) 没接进 toolAction")
        }
    }

    @Test("终端动作要开包所在的文件夹，不是 cd 进 .app 里面")
    func terminalOpensContainingFolder() {
        let action = RowActionCatalog.toolAction("terminal", for: app)
        guard case .openInTerminal(let url) = action else {
            Issue.record("terminal 没映射到 openInTerminal")
            return
        }
        #expect(url.path == "/Applications")
    }

    @Test("强制退出是唯一带破坏性标记的动作")
    func onlyForceQuitIsDestructive() {
        let destructive = RowActionCatalog.app.filter(\.isDestructive).map(\.code)
        #expect(destructive == ["forceQuit"])
    }

    private func isMapped(_ code: String) -> Bool {
        if case .none = RowActionCatalog.toolAction(code, for: app) { return false }
        return true
    }

    // MARK: 门禁

    @Test("视图不许再手写一遍应用动作清单")
    func contextMenuReadsTheCatalog() throws {
        let text = try sourceText(of: "Sources/MiscKit/UI/LauncherView.swift")
        // 正对照：扫描确实读到了这个文件，且它真的在用表
        #expect(text.contains("RowActionCatalog.available"))
        #expect(text.contains("RowActionCatalog.toolAction"))
        for title in ["打开", "在访达中显示", "拷贝路径", "在终端打开", "设置别名…"] {
            #expect(!text.contains("Button(\"\(title)\")"),
                    "「\(title)」写死在视图里了，右键与输入框会分叉")
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(of relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }
}