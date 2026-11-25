import Foundation
import Testing
@testable import MiscKitCore

@Suite("文件索引：FTS5、拼音、路径、模糊与正则")
struct FileIndexFeatureTests {
    private struct Fixture {
        let root: URL
        let state: URL
        let cleanup: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-feature-tests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Files", isDirectory: true)
        let state = base.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        return Fixture(root: root, state: state,
                       cleanup: { try? FileManager.default.removeItem(at: base) })
    }

    private func makeDatabase(_ fixture: Fixture) -> FileIndexDatabase {
        FileIndexDatabase(url: fixture.state.appendingPathComponent("index.sqlite3"))
    }

    private func query(_ syntax: String, pathSearch: Bool = false,
                       limit: Int = 100) -> FileIndexQuery {
        FileIndexQuery(syntax: FileSearchSyntax.parse(syntax), category: .all, scope: .mac,
                       directories: [], sort: .relevance, limit: limit,
                       pathSearch: pathSearch)
    }

    private func entry(_ path: String, isDirectory: Bool = false) -> FileIndexEntry {
        let name = (path as NSString).lastPathComponent
        let ext = isDirectory ? "" : (path as NSString).pathExtension.lowercased()
        return FileIndexEntry(path: path, name: name, isDirectory: isDirectory,
                              ext: ext,
                              kind: isDirectory ? FileCategory.folder.rawValue
                                                : FileIndexKind.classify(ext: ext))
    }

    // MARK: FTS

    @Test("FTS：重建后包含段与 instr 扫描结果一致")
    func ftsMatchesScan() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let names = ["report-2026.pdf", "annual-report.docx", "notes.txt",
                     "会议纪要.pdf", "报价单.xlsx", "readme.md"]
        try await db.upsert(names.map { entry(fixture.root.appendingPathComponent($0).path) })
        try await db.rebuildFTS()

        for term in ["report", "纪要", "会议纪要", "report-2026"] {
            let fts = try await db.query(query(term), usingFTS: true)
            let scan = try await db.query(query(term), usingFTS: false)
            #expect(fts.entries.map(\.path) == scan.entries.map(\.path), "\(term)")
            #expect(fts.total == scan.total, "\(term)")
        }
        #expect(try await db.ftsRowCount() == names.count)
        await db.close()
    }

    @Test("FTS：增量和删除都跟着正式表走")
    func ftsIncremental() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        try await db.upsert([entry(fixture.root.appendingPathComponent("alpha.txt").path),
                             entry(fixture.root.appendingPathComponent("beta.txt").path)])
        try await db.rebuildFTS()
        try await db.upsert([entry(fixture.root.appendingPathComponent("gamma.txt").path)],
                            maintainFTS: true)
        try await db.deleteSubtree(fixture.root.appendingPathComponent("alpha.txt").path,
                                   maintainFTS: true)

        #expect(try await db.ftsRowCount() == 2)
        #expect(try await db.query(query("alpha"), usingFTS: true).total == 0)
        #expect(try await db.query(query("gamma"), usingFTS: true).total == 1)
        #expect(try await db.query(query("beta"), usingFTS: true).total == 1)
        await db.close()
    }

    @Test("FTS：子树交换后只保留新内容")
    func ftsSubtreeSwap() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let dir = fixture.root.appendingPathComponent("a")
        try await db.upsert([entry(dir.appendingPathComponent("1.txt").path),
                             entry(dir.appendingPathComponent("2.txt").path),
                             entry(fixture.root.appendingPathComponent("b/1.txt").path)])
        try await db.rebuildFTS()

        try await db.beginStagingSubtree()
        try await db.stage([entry(dir.appendingPathComponent("2.txt").path),
                            entry(dir.appendingPathComponent("3.txt").path)])
        try await db.publishStagingSubtree(dir.path, maintainFTS: true)

        #expect(try await db.query(query("3.txt"), usingFTS: true).entries.map(\.name) == ["3.txt"])
        #expect(try await db.query(query("2.txt"), usingFTS: true).entries.map(\.name) == ["2.txt"])
        #expect(try await db.query(query("1.txt"), usingFTS: true).entries.map(\.name) == ["1.txt"])
        await db.close()
    }

    @Test("FTS：整库交换后清空并标记未就绪，等后台重建")
    func fullSwapClearsFTS() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        try await db.upsert([entry(fixture.root.appendingPathComponent("old.txt").path)])
        try await db.rebuildFTS()
        try await db.beginStaging()
        try await db.stage([entry(fixture.root.appendingPathComponent("fresh.docx").path)])
        try await db.buildStagingIndexes()
        try await db.publishStaging(meta: [])

        #expect(try await db.ftsRowCount() == 0)
        #expect(try await db.meta(FileIndexMetaKey.ftsReady) == nil)
        await db.close()
    }

    // MARK: 拼音

    @Test("拼音：汉字名的全拼与首字母进索引")
    func pinyinIndex() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let names = ["会议纪要.pdf", "报价单.xlsx", "年度报告.docx"]
        try await db.upsert(names.map { entry(fixture.root.appendingPathComponent($0).path) })
        try await db.rebuildFTS()

        #expect(try await db.query(query("hyjy"), usingFTS: true).entries.map(\.name) == ["会议纪要.pdf"])
        #expect(try await db.query(query("huiyijiyao"), usingFTS: true).entries.map(\.name) == ["会议纪要.pdf"])
        #expect(try await db.query(query("bjd"), usingFTS: true).entries.map(\.name) == ["报价单.xlsx"])
        #expect(try await db.query(query("niandu"), usingFTS: true).entries.map(\.name) == ["年度报告.docx"])

        // 英文名不生成拼音，避免把百万行英文名白算一遍。
        #expect(FileIndexPinyin.make("report.pdf") == ("", ""))
        #expect(FileIndexPinyin.make("会议纪要.pdf") == ("huiyijiyao.pdf", "hyjy"))
        await db.close()
    }

    // MARK: 路径

    @Test("路径：直达失败后的回退只搜完整路径")
    func pathFallback() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let main = fixture.root.appendingPathComponent("src/main.rs")
        let helper = fixture.root.appendingPathComponent("src/util/helper.swift")
        let doc = fixture.root.appendingPathComponent("docs/main.md")
        try await db.upsert([entry(main.path), entry(helper.path), entry(doc.path)])

        let byPath = try await db.query(query("src/main", pathSearch: true))
        #expect(byPath.entries.map(\.name) == ["main.rs"])

        let bySyntax = try await db.query(query("path:src/main"))
        #expect(bySyntax.entries.map(\.name) == ["main.rs"])

        let byName = try await db.query(query("main"))
        #expect(Set(byName.entries.map(\.name)) == ["main.rs", "main.md"])
        await db.close()
    }

    @Test("in: 作用域把命中限定在目录子树内")
    func scopeFilter() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        try await db.upsert([entry(fixture.root.appendingPathComponent("src/helper.swift").path),
                             entry(fixture.root.appendingPathComponent("docs/helper.md").path)])
        let scoped = try await db.query(query("in:\(fixture.root.path)/src helper"))
        #expect(scoped.entries.map(\.name) == ["helper.swift"])
        await db.close()
    }

    // MARK: 模糊与语法

    @Test("模糊：~term 按字符子序列匹配")
    func fuzzyMatch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        try await db.upsert([entry(fixture.root.appendingPathComponent("report.pdf").path),
                             entry(fixture.root.appendingPathComponent("annual-report.docx").path),
                             entry(fixture.root.appendingPathComponent("notes.txt").path)])
        let result = try await db.query(query("~rpt"))
        #expect(Set(result.entries.map(\.name)) == ["report.pdf", "annual-report.docx"])
        #expect(try await db.query(query("~xyz")).total == 0)
        await db.close()
    }

    @Test("语法：~ 模糊、path:、in:、re: 与裸 /正则/ 的边界")
    func syntaxAdditions() {
        #expect(FileSearchSyntax.parse("~rpt").terms.first?.kind == .fuzzy)
        #expect(FileSearchSyntax.parse("path:src/main").pathOnly)
        #expect(FileSearchSyntax.parse("in:~/Downloads 报价").scopes == ["~/Downloads"])
        #expect(FileSearchSyntax.parse("re:report.*pdf").regex?.pattern == "report.*pdf")
        #expect(FileSearchSyntax.parse("re:/^IMG_.*\\.png$/i").regex?.caseInsensitive == true)
        #expect(FileSearchSyntax.parse("re:/^IMG_.*\\.png$/c").regex?.caseInsensitive == false)
        // 没有元字符的 `/tmp/` 是路径，不是正则。
        #expect(FileSearchSyntax.parse("/tmp/").regex == nil)
        #expect(FileSearchSyntax.parse(NSHomeDirectory() + "/Documents/").regex == nil)
    }

    @Test("正则：字面锚点只取真正必须出现的片段")
    func regexAnchor() {
        #expect(FileSearchRegex.literalAnchor("IMG_\\d{4}") == "IMG_")
        #expect(FileSearchRegex.literalAnchor("\\.png$") == ".png")
        #expect(FileSearchRegex.literalAnchor("^.*$") == nil)
        #expect(FileSearchRegex.literalAnchor("(foo|bar)") == nil)
    }

    @Test("全链路：并行扫描 → 暂存交换 → FTS 重建")
    func fullPipeline() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.root.appendingPathComponent("notes"),
                               withIntermediateDirectories: true)
        let files = ["alpha.txt", "photo.jpg", "notes/beta.md", "notes/gamma.txt", "会议纪要.pdf"]
        for name in files {
            try "x".write(to: fixture.root.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
        }

        let db = makeDatabase(fixture)
        try await db.open()
        try await db.beginStaging()
        let result = try await FileIndexScanner.scan(
            roots: [fixture.root], into: db,
            policy: FileIndexPolicy(internalDirectory: fixture.state), staging: true)
        #expect(result.inserted == files.count + 2) // 根 + notes 目录
        #expect(result.unreadable == 0)

        try await db.buildStagingIndexes()
        try await db.publishStaging(meta: [])
        try await db.rebuildFTS()

        #expect(try await db.count() == result.inserted)
        #expect(try await db.ftsRowCount() == result.inserted)
        #expect(try await db.query(query("alpha"), usingFTS: true).entries.map(\.name) == ["alpha.txt"])
        #expect(try await db.query(query("notes/beta", pathSearch: true)).entries.map(\.name) == ["beta.md"])
        #expect(try await db.query(query("hyjy"), usingFTS: true).entries.map(\.name) == ["会议纪要.pdf"])
        await db.close()
    }

    @Test("计数上限与 UI 单屏对齐：300")
    func countCapAlignment() {
        #expect(FileIndexDatabase.countCap == 300)
    }
}
