import CoreServices
import Foundation
import Testing
@testable import MiscKitCore

@Suite("文件索引：语法、SQLite 存储、扫描与增量归类")
struct FileIndexTests {
    private struct Fixture {
        let root: URL
        let state: URL
        let cleanup: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-index-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func query(_ syntax: String, category: FileCategory = .all,
                       scope: FileScope = .mac, directories: [URL] = [],
                       sort: FileSort = .relevance, limit: Int = 100) -> FileIndexQuery {
        FileIndexQuery(syntax: FileSearchSyntax.parse(syntax), category: category,
                       scope: scope, directories: directories, sort: sort, limit: limit)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: 语法

    @Test("语法：空格 AND、-排除、短语、类型过滤与通配")
    func syntaxParsing() {
        let syntax = FileSearchSyntax.parse("报价 -草稿 folder: ext:pdf,docx \"季度 报告\" ?final*")
        #expect(syntax.folderOnly)
        #expect(!syntax.fileOnly)
        #expect(syntax.extensions == ["pdf", "docx"])
        #expect(syntax.terms.map(\.text) == ["报价", "草稿", "季度 报告", "?final*"])
        #expect(syntax.terms[1].isNegated)
        #expect(syntax.terms[2].isQuoted)
        #expect(syntax.terms[3].hasWildcard)
        #expect(syntax.highlightTerm == "报价")
        #expect(FileSearchSyntax.likePattern(for: syntax.terms[3]) == "_final%")

        let conflict = FileSearchSyntax.parse("folder: file:")
        #expect(!conflict.folderOnly && !conflict.fileOnly)

        let escaped = FileSearchSyntax.parse("100%_x").terms[0]
        #expect(FileSearchSyntax.likePattern(for: escaped) == "%100\\%\\_x%")
    }

    @Test("折叠：大小写、变音与组合字符归一")
    func folding() {
        #expect(FileIndexText.fold("Résumé.PDF") == "resume.pdf")
        #expect(FileIndexText.fold("ＣＡＦＥ") == "cafe")
        #expect(FileIndexText.escapeLike("50%_off\\x") == "50\\%\\_off\\\\x")
    }

    // MARK: 存储

    @Test("SQLite：相关度排序、类型/范围/扩展名过滤与截断计数")
    func databaseQuery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let documents = fixture.root.appendingPathComponent("Documents", isDirectory: true)
        let projects = fixture.root.appendingPathComponent("Projects", isDirectory: true)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.upsert([
            FileIndexEntry(path: documents.appendingPathComponent("报价.docx").path,
                           name: "报价.docx", isDirectory: false, ext: "docx", kind: "word",
                           size: 12, modified: modified),
            FileIndexEntry(path: documents.appendingPathComponent("年度报价汇总.docx").path,
                           name: "年度报价汇总.docx", isDirectory: false, ext: "docx",
                           kind: "word", size: 40),
            FileIndexEntry(path: projects.appendingPathComponent("报价.pdf").path,
                           name: "报价.pdf", isDirectory: false, ext: "pdf", kind: "pdf",
                           size: 8),
            FileIndexEntry(path: projects.path, name: "Projects", isDirectory: true,
                           ext: "", kind: "folder"),
        ])

        let count = try await db.count()
        #expect(count == 4)

        let all = try await db.query(query("报价"))
        #expect(all.total == 3)
        #expect(all.entries.count == 3)
        #expect(Set(all.entries.prefix(2).map(\.name)) == ["报价.docx", "报价.pdf"])
        #expect(all.entries.last?.name == "年度报价汇总.docx")
        #expect(all.entries.first?.modified == modified)

        let words = try await db.query(query("报价", category: .word))
        #expect(words.total == 2)
        #expect(words.entries.allSatisfy { $0.kind == "word" })

        let folders = try await db.query(query("folder:"))
        #expect(folders.total == 1)
        #expect(folders.entries.first?.isDirectory == true)

        let scoped = try await db.query(query("报价", scope: .folders, directories: [projects]))
        #expect(scoped.total == 1)
        #expect(scoped.entries.first?.name == "报价.pdf")

        let pdf = try await db.query(query("ext:pdf"))
        #expect(pdf.total == 1)
        #expect(pdf.entries.first?.name == "报价.pdf")

        let limited = try await db.query(query("报价", limit: 1))
        #expect(limited.total == 3)
        #expect(limited.entries.count == 1)

        let excluded = try await db.query(query("报价 -pdf"))
        #expect(excluded.total == 2)
        #expect(excluded.entries.allSatisfy { !$0.name.hasSuffix(".pdf") })

        // 走表达式索引的排序仍要带回准确总数（总数改由标量子查询取，不再靠窗口函数）。
        let byModified = try await db.query(query("报价", sort: .modified))
        #expect(byModified.total == 3)
        #expect(byModified.entries.map(\.name) == ["报价.docx", "年度报价汇总.docx", "报价.pdf"])

        let bySize = try await db.query(query("报价", sort: .size))
        #expect(bySize.total == 3)
        #expect(bySize.entries.map(\.name) == ["年度报价汇总.docx", "报价.docx", "报价.pdf"])

        // 带范围参数时，标量子查询与外部 WHERE 各绑一遍，参数顺序不能错。
        let scopedByModified = try await db.query(
            query("报价", scope: .folders, directories: [projects], sort: .modified))
        #expect(scopedByModified.total == 1)
        #expect(scopedByModified.entries.first?.name == "报价.pdf")
    }

    @Test("SQLite：相关度按「相等→前缀→包含」分段，段内名字序")
    func databaseRankingGroups() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        // 名字刻意交错写入：结果对不对只看排序，不看插入顺序。
        let names = ["quoted.txt", "xquote.txt", "quote.txt", "quote", "aquote.bak"]
        try await db.upsert(names.map { name in
            FileIndexEntry(path: fixture.root.appendingPathComponent(name).path,
                           name: name, isDirectory: false, ext: "txt", kind: "other")
        })

        let result = try await db.query(query("quote"))
        #expect(result.entries.map(\.name) == [
            "quote",          // 完全相等
            "quote.txt",      // 前缀，段内名字序
            "quoted.txt",
            "aquote.bak",     // 其余，名字序
            "xquote.txt",
        ])
        #expect(result.total == 5)
        #expect(result.totalIsExact)
    }

    @Test("SQLite：fast/body/count 三阶段与完整查询同语义")
    func databaseQueryPhases() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let names = [
            "quote", "quote.txt", "quoted.txt", "aquote.bak",
            "xquote.txt", "quote%2.txt", "quote_2.txt",
            "[quote].txt", "a]quote.txt", "a_b.txt", "axb.txt",
        ]
        try await db.upsert(names.map { name in
            FileIndexEntry(path: fixture.root.appendingPathComponent(name).path,
                           name: name, isDirectory: false, ext: "txt", kind: "other")
        })

        let complete = try await db.query(query("quote"))
        let fast = try await db.query(query("quote"), phase: .fast)
        let body = try await db.query(query("quote"), phase: .body)
        let count = try await db.query(query("quote"), phase: .count)

        #expect(!fast.exhausted)
        #expect(fast.entries == Array(complete.entries.prefix(fast.entries.count)))
        #expect(fast.entries.count < complete.entries.count)
        #expect(body.entries == complete.entries)
        #expect(body.total == complete.total)
        #expect(body.totalIsExact)
        #expect(count.entries.isEmpty)
        #expect(count.total == complete.total)
        #expect(count.totalIsExact)

        // `[` / `]` 走 GLOB 时必须被转义，否则前缀段会从有结果变成 0 条。
        let bracket = try await db.query(query("["))
        let bracketFast = try await db.query(query("["), phase: .fast)
        #expect(!bracket.entries.isEmpty)
        #expect(bracketFast.entries == Array(bracket.entries.prefix(bracketFast.entries.count)))

        // 非通配词走 instr 时，`_` 和 `%` 是字面量，不能像旧 LIKE 那样被当成通配。
        let underscore = try await db.query(query("a_b"))
        #expect(underscore.entries.map(\.name) == ["a_b.txt"])
        let percent = try await db.query(query("quote%2"))
        #expect(percent.entries.map(\.name) == ["quote%2.txt"])
    }

    @Test("SQLite：命中超过计数上限时只报下界")
    func databaseCountCap() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let total = FileIndexDatabase.countCap + 3
        try await db.upsert((0..<total).map { index in
            FileIndexEntry(path: fixture.root.appendingPathComponent("cap-\(index).txt").path,
                           name: "cap-\(index).txt", isDirectory: false, ext: "txt", kind: "other")
        })

        let result = try await db.query(query("cap-", limit: 10))
        #expect(result.entries.count == 10)
        #expect(result.total == FileIndexDatabase.countCap)
        #expect(!result.totalIsExact)

        // 封顶线以下的命中仍要给精确总数。
        let few = try await db.query(query("cap-1.txt", limit: 10))
        #expect(few.total == 1)
        #expect(few.totalIsExact)
    }

    @Test("SQLite：子目录删除对 LIKE 通配字符安全，元数据重开仍在")
    func databaseDeleteAndPersist() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()

        let underscore = fixture.root.appendingPathComponent("keep/a_b", isDirectory: true)
        let plain = fixture.root.appendingPathComponent("keep/ab", isDirectory: true)
        try await db.upsert([
            FileIndexEntry(path: underscore.appendingPathComponent("one.txt").path,
                           name: "one.txt", isDirectory: false, ext: "txt", kind: "other"),
            FileIndexEntry(path: plain.appendingPathComponent("two.txt").path,
                           name: "two.txt", isDirectory: false, ext: "txt", kind: "other"),
        ])
        try await db.deleteSubtree(underscore.path)

        let count = try await db.count()
        #expect(count == 1)
        let remaining = try await db.query(query("txt"))
        #expect(remaining.entries.first?.name == "two.txt")

        try await db.setMeta("last_event_id", value: "42")
        await db.close()

        let reopened = makeDatabase(fixture)
        try await reopened.open()
        let saved = try await reopened.meta("last_event_id")
        #expect(saved == "42")
        let reopenedCount = try await reopened.count()
        #expect(reopenedCount == 1)
        await reopened.close()
    }

    // MARK: 扫描

    @Test("扫描：隐藏文件入库、排除目录跳过、包不展开")
    func scannerFixture() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.root
        try write("export PATH", to: root.appendingPathComponent(".zshrc"))
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try directory(documents)
        try write("docx", to: documents.appendingPathComponent("报价.docx"))
        let modules = root.appendingPathComponent("node_modules", isDirectory: true)
        try directory(modules)
        try write("module", to: modules.appendingPathComponent("dep.js"))
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try directory(git)
        try write("config", to: git.appendingPathComponent("config"))
        let contents = root.appendingPathComponent("Tool.app/Contents", isDirectory: true)
        try directory(contents)
        try write("plist", to: contents.appendingPathComponent("Info.plist"))
        let internalDirectory = root.appendingPathComponent("Internal", isDirectory: true)
        try directory(internalDirectory)
        try write("db", to: internalDirectory.appendingPathComponent("index.sqlite3"))
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        try directory(appSupport)
        try write("state", to: appSupport.appendingPathComponent("state.bin"))
        let mobile = library.appendingPathComponent("Mobile Documents", isDirectory: true)
        try directory(mobile)
        try write("cloud", to: mobile.appendingPathComponent("note.txt"))

        let db = makeDatabase(fixture)
        try await db.open()
        let result = try await FileIndexScanner.scan(
            roots: [root], into: db,
            policy: FileIndexPolicy(home: root, internalDirectory: internalDirectory))
        let all = try await db.query(query("", limit: 100))
        let paths = Set(all.entries.map(\.path))
        #expect(result.inserted == 8,
                "inserted=\(result.inserted) paths=\(paths.sorted().joined(separator: ","))")

        #expect(paths.contains(root.path))
        #expect(paths.contains(root.appendingPathComponent(".zshrc").path))
        #expect(paths.contains(documents.path))
        #expect(paths.contains(documents.appendingPathComponent("报价.docx").path))
        #expect(paths.contains(root.appendingPathComponent("Tool.app").path))
        #expect(!paths.contains(contents.appendingPathComponent("Info.plist").path))
        #expect(!paths.contains(modules.appendingPathComponent("dep.js").path))
        #expect(!paths.contains(git.appendingPathComponent("config").path))
        #expect(!paths.contains(internalDirectory.appendingPathComponent("index.sqlite3").path))
        #expect(paths.contains(mobile.appendingPathComponent("note.txt").path))
        #expect(!paths.contains(appSupport.appendingPathComponent("state.bin").path))

        let app = all.entries.first { $0.name == "Tool.app" }
        #expect(app?.isDirectory == false)
        let docx = all.entries.first { $0.name == "报价.docx" }
        #expect(docx?.kind == "word")
    }

    // MARK: 增量归类

    @Test("增量事件：按磁盘当前状态归为删除、刷元数据或重扫子树")
    func eventPlanning() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let policy = FileIndexPolicy(home: fixture.root)
        let note = fixture.root.appendingPathComponent("note.txt")
        try write("x", to: note)
        let folder = fixture.root.appendingPathComponent("Folder", isDirectory: true)
        try directory(folder)
        let package = fixture.root.appendingPathComponent("Tool.app", isDirectory: true)
        try directory(package)
        let git = fixture.root.appendingPathComponent(".git", isDirectory: true)
        try directory(git)
        let gitConfig = git.appendingPathComponent("config")
        try write("x", to: gitConfig)
        let insidePackage = package.appendingPathComponent("Contents/Info.plist")
        try directory(insidePackage.deletingLastPathComponent())
        try write("x", to: insidePackage)
        let missing = fixture.root.appendingPathComponent("gone.txt")

        func flags(_ value: Int) -> FSEventStreamEventFlags {
            FSEventStreamEventFlags(value)
        }
        let plan = FileIndexEventPlanner.makePlan(events: [
            FileIndexEvent(path: note.path,
                           flags: flags(kFSEventStreamEventFlagItemModified), id: 10),
            FileIndexEvent(path: folder.path,
                           flags: flags(kFSEventStreamEventFlagItemModified), id: 11),
            FileIndexEvent(path: folder.path,
                           flags: flags(kFSEventStreamEventFlagItemCreated), id: 12),
            FileIndexEvent(path: missing.path,
                           flags: flags(kFSEventStreamEventFlagItemRemoved), id: 13),
            FileIndexEvent(path: package.path,
                           flags: flags(kFSEventStreamEventFlagItemCreated)
                               | flags(kFSEventStreamEventFlagItemIsDir), id: 14),
            FileIndexEvent(path: gitConfig.path,
                           flags: flags(kFSEventStreamEventFlagItemModified), id: 15),
            FileIndexEvent(path: insidePackage.path,
                           flags: flags(kFSEventStreamEventFlagItemModified), id: 16),
        ], policy: policy, roots: FileIndexRootMap(roots: [fixture.root]))

        #expect(plan.fileRefreshes.contains(note.path))
        #expect(plan.fileRefreshes.contains(package.path))
        #expect(plan.dirRefreshes.contains(folder.path))
        #expect(plan.rescans.contains(folder.path))
        #expect(plan.deletions.contains(missing.path))
        #expect(plan.deletions.contains(gitConfig.path))
        #expect(plan.deletions.contains(insidePackage.path))
        #expect(plan.maxEventID == 16)

        var pruned = plan
        FileIndexEventPlanner.prune(&pruned)
        #expect(pruned.dirRefreshes.isEmpty)
        #expect(pruned.rescans == [folder.path])

        let nested = FileIndexEventPlan(
            fileRefreshes: [folder.appendingPathComponent("Sub/a.txt").path],
            rescans: [folder.path, folder.appendingPathComponent("Sub").path])
        var prunedNested = nested
        FileIndexEventPlanner.prune(&prunedNested)
        #expect(prunedNested.rescans == [folder.path])
        #expect(prunedNested.fileRefreshes.isEmpty)

        let rootChanged = FileIndexEventPlanner.makePlan(events: [
            FileIndexEvent(path: fixture.root.path,
                           flags: flags(kFSEventStreamEventFlagRootChanged), id: 20),
        ], policy: policy, roots: FileIndexRootMap(roots: [fixture.root]))
        #expect(rootChanged.needsFullRescan)
    }

    @Test("事件路径映射：FSEvents 的规范路径回到配置根写法")
    func rootPathMapping() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("Target", isDirectory: true)
        try directory(target)
        let link = fixture.root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let map = FileIndexRootMap(roots: [link])
        let canonical = FileIndexRootMap.canonicalPath(for: target)
        #expect(map.displayPath(for: canonical + "/a.txt") == link.path + "/a.txt")
        #expect(map.displayPath(for: canonical) == link.path)
        #expect(map.displayPath(for: link.path + "/a.txt") == link.path + "/a.txt")
        #expect(map.displayPath(for: "/opt/elsewhere/a.txt") == "/opt/elsewhere/a.txt")
    }

    // MARK: 根目录

    @Test("根目录：去重、剔除子目录、签名与顺序无关")
    func rootNormalization() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let downloads = home.appendingPathComponent("Downloads")
        let normalized = FileIndexRoots.normalized([home, downloads, home])
        #expect(normalized.map(\.path) == [home.path])
        #expect(FileIndexRoots.signature([home, downloads])
                == FileIndexRoots.signature([downloads, home]))
    }

    // MARK: 溢出兜底

    @Test("溢出计数：策略根本不收的路径不占用增量队列")
    func overflowIgnoresExcludedPaths() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let policy = FileIndexPolicy(home: fixture.root)
        let filter = FileIndexEventFilter(roots: [fixture.root], policy: policy)
        let note = fixture.root.appendingPathComponent("note.txt")

        func event(_ path: String) -> FileIndexEvent {
            FileIndexEvent(path: path,
                           flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                           id: 1)
        }
        // 编译一次实测能吐出两万条以上事件，全落在这些根本不进索引的目录里。
        var churn: [FileIndexEvent] = []
        for index in 0...20_000 {
            let path = switch index % 3 {
            case 0: fixture.root.appendingPathComponent("Caches/\(index).bin").path
            case 1: fixture.root.appendingPathComponent("Library/Application Support/App/\(index)").path
            default: fixture.root.appendingPathComponent("Code/.build/\(index).o").path
            }
            churn.append(event(path))
        }
        let noise = filter.process(churn)
        #expect(noise.kept.isEmpty)
        #expect(noise.buckets.isEmpty)

        let mixed = filter.process(churn + [event(note.path)])
        #expect(mixed.kept.map(\.path) == [note.path])
        #expect(mixed.buckets == [note.path])
        // 只有真会入库的事件才参与判定，两万条噪声不该顶穿阈值。
        #expect(mixed.kept.count <= FileIndex.pendingEventLimit)
    }

    @Test("事件折叠：溢出归并到根下第一层目录，不推倒整库")
    func bucketFolding() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let roots = [home, URL(fileURLWithPath: "/Applications")]
        #expect(FileIndex.bucket(of: "/Users/tester/Downloads/a/b/c.txt", roots: roots)
                == "/Users/tester/Downloads")
        #expect(FileIndex.bucket(of: "/Users/tester/文件/Code/MiscKit/.build/x", roots: roots)
                == "/Users/tester/文件")
        #expect(FileIndex.bucket(of: "/Applications/Foo.app/Contents/MacOS/Foo", roots: roots)
                == "/Applications/Foo.app")
        #expect(FileIndex.bucket(of: "/Users/tester", roots: roots) == "/Users/tester")
        #expect(FileIndex.bucket(of: "/private/tmp/elsewhere/a.txt", roots: roots) == nil)
    }

    @Test("事件折叠：目录桶分批消化，剩下的退回队列而不是整库推倒")
    func rescanBatching() {
        let dirs = ["/U/a", "/U/b", "/U/c", "/U/d", "/U/e", "/U/f",
                    "/U/longer1", "/U/longer2", "/U/longer3", "/U/longer4"]
        let split = FileIndex.splitRescans(Set(dirs), limit: 6)
        #expect(split.take == Set(["/U/a", "/U/b", "/U/c", "/U/d", "/U/e", "/U/f"]))
        #expect(split.rest == Set(["/U/longer1", "/U/longer2", "/U/longer3", "/U/longer4"]))
        let few = FileIndex.splitRescans(["/U/a"], limit: 6)
        #expect(few.take == ["/U/a"])
        #expect(few.rest.isEmpty)
    }

    // MARK: 暂存与交换

    @Test("全量重扫：交换前中止，正式表和完成标记一字未动")
    func stagingAbortKeepsLiveIndex() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()
        let live = fixture.root.appendingPathComponent("keep/a.txt").path
        try await db.upsert([
            FileIndexEntry(path: live, name: "a.txt", isDirectory: false, ext: "txt", kind: "other"),
        ])
        try await db.setMeta(FileIndexMetaKey.completedAt, value: "1700000000")
        try await db.setMeta(FileIndexMetaKey.rootsSignature, value: "old")

        try await db.beginStaging()
        try await db.setMeta(FileIndexMetaKey.rebuilding, value: "1700000900")
        var staged: [FileIndexEntry] = []
        for index in 0..<5 {
            staged.append(FileIndexEntry(
                path: fixture.root.appendingPathComponent("new/\(index).txt").path,
                name: "\(index).txt", isDirectory: false, ext: "txt", kind: "other"))
        }
        try await db.stage(staged)
        // 扫描期间正式表照常可查。
        #expect(try await db.count() == 1)
        #expect(try await db.stagedCount() == 5)

        // 模拟扫描中途被杀：交换没发生，标记留在库里。
        try await db.discardStaging()
        await db.close()

        let reopened = makeDatabase(fixture)
        try await reopened.open()
        #expect(try await reopened.count() == 1)
        #expect(try await reopened.meta(FileIndexMetaKey.completedAt) == "1700000000")
        #expect(try await reopened.meta(FileIndexMetaKey.rootsSignature) == "old")
        #expect(try await reopened.meta(FileIndexMetaKey.rebuilding) != nil)
        let query = try await reopened.query(self.query("a.txt"))
        #expect(query.entries.map(\.path) == [live])
        await reopened.close()
    }

    @Test("全量重扫：交换把整库换成暂存内容，旧行与旧标记一起退场")
    func stagingPublishSwapsTable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()
        try await db.upsert([
            FileIndexEntry(path: fixture.root.appendingPathComponent("gone.txt").path,
                           name: "gone.txt", isDirectory: false, ext: "txt", kind: "other"),
        ])
        try await db.setMeta(FileIndexMetaKey.completedAt, value: "1700000000")
        try await db.beginStaging()
        try await db.setMeta(FileIndexMetaKey.rebuilding, value: "1700000900")
        try await db.stage([
            FileIndexEntry(path: fixture.root.appendingPathComponent("fresh.docx").path,
                           name: "fresh.docx", isDirectory: false, ext: "docx", kind: "word"),
        ])
        try await db.publishStaging(meta: [
            (FileIndexMetaKey.rootsSignature, "new"),
            (FileIndexMetaKey.completedAt, "1700001000"),
            (FileIndexMetaKey.rebuilding, nil),
        ])
        #expect(try await db.count() == 1)
        #expect(try await db.meta(FileIndexMetaKey.completedAt) == "1700001000")
        #expect(try await db.meta(FileIndexMetaKey.rootsSignature) == "new")
        #expect(try await db.meta(FileIndexMetaKey.rebuilding) == nil)
        let hits = try await db.query(self.query("folder:"))
        #expect(hits.total == 0)
        let words = try await db.query(self.query("fresh"))
        #expect(words.entries.map(\.name) == ["fresh.docx"])

        // 交换后仍能继续收增量，说明索引跟着了新表而不是留在旧表上。
        try await db.upsert([
            FileIndexEntry(path: fixture.root.appendingPathComponent("later.pdf").path,
                           name: "later.pdf", isDirectory: false, ext: "pdf", kind: "pdf"),
        ])
        try await db.deleteSubtree(fixture.root.appendingPathComponent("fresh.docx").path)
        #expect(try await db.count() == 1)

        // 交换之后索引仍跟着正式表：连续再来两轮，棵数不涨、名字两套轮流用
        var previous = try await db.liveIndexNames()
        #expect(previous.count == 5)
        for round in 1...3 {
            try await db.beginStaging()
            try await db.stage([FileIndexEntry(
                path: fixture.root.appendingPathComponent("r\(round)/a.txt").path,
                name: "a.txt", isDirectory: false, ext: "txt", kind: "other")])
            try await db.buildStagingIndexes()
            try await db.publishStaging(meta: [(FileIndexMetaKey.completedAt, "170000\(round)000")])
            let names = try await db.liveIndexNames()
            #expect(names.count == 5, "第\(round)轮后索引=\(names.sorted())")
            #expect(names != previous, "第\(round)轮该换另一套名字")
            previous = names
        }
        #expect(try await db.count() == 1)
        await db.close()
    }

    @Test("子树重扫：交换前中止不删原行，交换后才用暂存内容顶掉那棵子树")
    func subtreeSwapIsAtomic() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let db = makeDatabase(fixture)
        try await db.open()
        func entry(_ path: String) -> FileIndexEntry {
            FileIndexEntry(path: path, name: (path as NSString).lastPathComponent,
                           isDirectory: false, ext: "txt", kind: "other")
        }
        let keep = fixture.root.appendingPathComponent("b/1.txt").path
        let stale = fixture.root.appendingPathComponent("a/1.txt").path
        let renewed = fixture.root.appendingPathComponent("a/2.txt").path
        try await db.upsert([entry(stale), entry(renewed), entry(keep)])

        // 扫到一半被打断：交换没发生，那棵子树一行都不能少。
        try await db.beginStagingSubtree()
        try await db.stage([entry(fixture.root.appendingPathComponent("a/3.txt").path)])
        #expect(try await db.count() == 3)
        try await db.discardStaging()
        #expect(try await db.count() == 3)

        try await db.beginStagingSubtree()
        try await db.stage([entry(renewed),
                            entry(fixture.root.appendingPathComponent("a/3.txt").path)])
        try await db.publishStagingSubtree(fixture.root.appendingPathComponent("a").path)
        let after = try await db.query(self.query("txt"))
        #expect(Set(after.entries.map(\.path)) == [keep, renewed,
                                                  fixture.root.appendingPathComponent("a/3.txt").path])
        // 兄弟子树不受影响
        #expect(try await db.query(self.query("1.txt")).entries.map(\.path) == [keep])
        await db.close()
    }

    @Test("补洞判定：只在行数掉过两成才判有洞，小库和正常波动不算")
    func holeDetection() {
        #expect(!FileIndex.suspectsHole(now: 377_905, atCompletion: nil))
        #expect(!FileIndex.suspectsHole(now: 12_000, atCompletion: 900))
        #expect(!FileIndex.suspectsHole(now: 302_324, atCompletion: 377_905))
        #expect(FileIndex.suspectsHole(now: 302_323, atCompletion: 377_905))
        // 实测装新版时被旧代码带走的那一刀：~/Documents 整棵没了
        #expect(FileIndex.suspectsHole(now: 205_131, atCompletion: 377_905))
    }
}
