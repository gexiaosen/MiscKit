import Foundation
import Testing
@testable import MiscKitCore

@Suite("文件搜索：解析、类型与计数")
struct FileSearchTests {
    private func makeFixture() throws -> (root: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "echo hi".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try "a".write(to: downloads.appendingPathComponent("报价.docx"), atomically: true, encoding: .utf8)
        return (root, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("file 前缀剥离，单独关键词进入浏览态")
    func keywordParsing() {
        let parser = FileQueryParser(home: URL(fileURLWithPath: "/Users/tester"), volumes: [])
        #expect(parser.parse("file 报告") == .search(term: "报告"))
        #expect(parser.parse("文件  测试") == .search(term: "测试"))
        #expect(parser.parse("file") == .browse)
        #expect(parser.parse("文件") == .browse)
        #expect(parser.parse("   ") == .none)
        #expect(parser.parse("txhy") == .search(term: "txhy"))
    }

    @Test("路径直达：~、绝对路径、相对路径与尾斜杠")
    func pathParsing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let parser = FileQueryParser(home: fixture.root, volumes: [])

        #expect(parser.parse("~/.zshrc") == .path(PathQuery(
            url: fixture.root.appendingPathComponent(".zshrc"),
            listsChildren: false, exists: true)))

        let downloads = URL(fileURLWithPath: fixture.root.appendingPathComponent("Downloads").path)
        #expect(parser.parse("~/Downloads/") == .path(PathQuery(
            url: downloads, listsChildren: true, exists: true)))
        #expect(parser.parse("Downloads/") == .path(PathQuery(
            url: downloads, listsChildren: true, exists: true)))
        #expect(parser.parse(downloads.path) == .path(PathQuery(
            url: downloads, listsChildren: false, exists: true)))
        #expect(parser.parse("/definitely/missing/misckit") == .path(PathQuery(
            url: URL(fileURLWithPath: "/definitely/missing/misckit"),
            listsChildren: false, exists: false)))
    }

    @Test("卷标开头按挂载卷解析，不进入 Spotlight")
    func volumeParsing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let volume = URL(fileURLWithPath: "/Volumes/Work Disk")
        let parser = FileQueryParser(home: fixture.root, volumes: [volume])

        #expect(parser.parse("Work Disk") == .search(term: "Work Disk"))
        #expect(!parser.isFileMode("Work Disk"), "裸卷名不再把面板切进文件模式")
        guard case .path(let query) = parser.parse("Work Disk/Projects/") else {
            Issue.record("卷标路径没有命中")
            return
        }
        #expect(query.url.path == "/Volumes/Work Disk/Projects")
        #expect(query.listsChildren)
        // 卷本身在测试机上不存在，exists 允许为 false；关键是没走模糊搜索
        #expect(!query.exists)
    }

    @Test("裸卷名不劫持同名应用：安装 DMG 的卷不把「千问」当路径")
    func bareVolumeNameDoesNotHijackApp() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let parser = FileQueryParser(
            home: fixture.root, volumes: [URL(fileURLWithPath: "/Volumes/千问")])

        #expect(parser.parse("千问") == .search(term: "千问"))
        #expect(!parser.isFileMode("千问"), "敲应用名不该被挂载卷带进文件面板")
        #expect(parser.isFileMode("千问/"), "带斜杠仍然直达卷")
    }

    @Test("目录别名优先于同名模糊搜索")
    func aliasParsing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("Downloads")
        let parser = FileQueryParser(home: fixture.root, volumes: [], aliases: ["报价": target])

        #expect(parser.parse("file 报价") == .path(PathQuery(
            url: target, listsChildren: false, exists: true)))
        // 不带关键词也一样命中：别名检查在模糊搜索之前，敲那两个字就直接进目录
        #expect(parser.parse("报价") == .path(PathQuery(
            url: target, listsChildren: false, exists: true)))
        #expect(parser.isFileMode("报价"), "别名命中得把面板带进文件模式，不然这个词只会去搜应用")
    }

    @Test("类型映射：WORD 扩展名与类型树双查，文件夹独立判断")
    func categoryMapping() {
        let docx = FileItem(url: URL(fileURLWithPath: "/tmp/a.docx"), isDirectory: false,
                            contentTypeTree: ["public.data"])
        let docTree = FileItem(url: URL(fileURLWithPath: "/tmp/legacy.bin"), isDirectory: false,
                               contentTypeTree: ["public.word-processing-document"])
        let folder = FileItem(url: URL(fileURLWithPath: "/tmp/项目"), isDirectory: true)
        let png = FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false,
                           contentTypeTree: ["public.image", "public.data"])

        #expect(FileCategory.word.matches(docx))
        #expect(FileCategory.word.matches(docTree))
        #expect(!FileCategory.excel.matches(docx))
        #expect(FileCategory.folder.matches(folder))
        #expect(!FileCategory.folder.matches(png))
        #expect(FileCategory.image.matches(png))
        #expect(FileCategory.all.matches(folder))
        #expect(FileCategory.word.fileExtensions.contains("docx"))
        #expect(FileCategory.word.contentTypeTree.contains("public.word-processing-document"))
    }

    @Test("计数语义：截断时区分总数与已显示数")
    func countSemantics() {
        let one = FileItem(url: URL(fileURLWithPath: "/tmp/a"), isDirectory: false)
        let complete = FileSearchResponse(items: [one], total: 1, isTruncated: false)
        let truncated = FileSearchResponse(items: [one], total: 471, isTruncated: true)
        let empty = FileSearchResponse(items: [], total: 0, isTruncated: false)

        L10n.withLanguage(.zhHans) {
            #expect(complete.countText == "共 1 条")
            #expect(truncated.countText == "共 471 条，仅显示前 1 条")
            #expect(empty.countText == "共 0 条")
        }
        L10n.withLanguage(.en) {
            #expect(complete.countText == "1 items")
            #expect(truncated.countText == "471 items (showing first 1)")
            #expect(empty.countText == "0 items")
        }
    }

    @Test("路径展示把主目录归一化为 ~")
    func pathAbbreviation() {
        let home = URL(fileURLWithPath: "/Users/tester")
        #expect(FilePathDisplay.abbreviated(URL(fileURLWithPath: "/Users/tester/Downloads/a.txt"),
                                            home: home) == "~/Downloads/a.txt")
        #expect(FilePathDisplay.abbreviated(home, home: home) == "~")
        #expect(FilePathDisplay.abbreviated(URL(fileURLWithPath: "/opt/homebrew"), home: home)
                == "/opt/homebrew")
    }
}
