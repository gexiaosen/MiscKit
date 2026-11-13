import Foundation
import Testing

@testable import MiscKitCore

@Suite("网址别名")
struct QuicklinkTests {
    private func link(keyword: String = "gh", title: String = "GitHub",
                      template: String = "https://github.com/search?q={q}") -> Quicklink {
        Quicklink(keyword: keyword, title: title, template: template)
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-quicklink-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("quicklinks.json")
    }

    // MARK: 拼接

    @Test("占位符替换：出现几次换几次，也认 path 段")
    func placeholderReplacement() {
        let simple = link()
        let url = try? #require(simple.url(query: "misckit"))
        #expect(url?.absoluteString == "https://github.com/search?q=misckit")

        let twice = link(keyword: "x", title: "x",
                         template: "https://example.com/s?q={q}&from={q}")
        #expect(twice.url(query: "ab")?.absoluteString == "https://example.com/s?q=ab&from=ab")

        let pathSegment = link(keyword: "x", title: "x",
                               template: "https://example.com/search/{q}/results")
        #expect(pathSegment.url(query: "abc")?.absoluteString
                == "https://example.com/search/abc/results")
    }

    @Test("不带占位符的模板直开，多打的词不影响")
    func templateWithoutPlaceholder() {
        let mail = link(keyword: "mail", title: "Gmail", template: "https://mail.google.com/")
        #expect(mail.takesQuery == false)
        #expect(mail.url(query: "")?.absoluteString == "https://mail.google.com/")
    }

    @Test("特殊字符被 percent-encode，URL 结构不被撑破")
    func percentEncoding() throws {
        let search = link()
        let cases = ["a&b=c", "C++", "中文 词", "#hash", "a?b", "x/y", "50%"]
        for query in cases {
            let url = try #require(search.url(query: query), "「\(query)」被整个拒了")
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = components.queryItems ?? []
            #expect(items.count == 1, "「\(query)」被拆成了 \(items.count) 个参数")
            #expect(items.first?.value == query, "「\(query)」往返后变成了「\(items.first?.value ?? "nil")」")
        }
    }

    @Test("只认 http / https：脚本与本地文件一律拒")
    func schemeWhitelist() {
        let bad = [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "vbscript:msgbox(1)",
            "  javascript:alert(1)  ",
            "chrome://settings",
            "not a url",
        ]
        for template in bad {
            let bad = link(keyword: "x", title: "x", template: template)
            #expect(bad.url(query: "a") == nil, "「\(template)」不该被放行")
        }
        let good = link(keyword: "x", title: "x", template: "http://example.com/?q={q}")
        #expect(good.url(query: "a") != nil)
    }

    // MARK: 校验

    @Test("关键词：空、带空格、重复都拒")
    @MainActor
    func keywordValidation() {
        let store = QuicklinkStore(fileURL: tempFile())
        try? store.add(link(keyword: "gh"))
        #expect(throws: QuicklinkValidationError.emptyKeyword) {
            try store.add(link(keyword: "   "))
        }
        #expect(throws: QuicklinkValidationError.keywordHasWhitespace) {
            try store.add(link(keyword: "g h"))
        }
        #expect(throws: QuicklinkValidationError.duplicateKeyword("gh")) {
            try store.add(link(keyword: "GH"))
        }
    }

    @Test("编辑自己时不算重复")
    @MainActor
    func editingExcludesSelf() throws {
        let store = QuicklinkStore(fileURL: tempFile())
        let original = link(keyword: "gh")
        try store.add(original)
        var renamed = original
        renamed.title = "GitHub 搜索"
        try store.update(renamed)
        #expect(store.links.first?.title == "GitHub 搜索")
    }

    @Test("名字不能空，模板必须合法")
    @MainActor
    func titleAndTemplateValidation() {
        let store = QuicklinkStore(fileURL: tempFile())
        #expect(throws: QuicklinkValidationError.emptyTitle) {
            try store.add(link(title: "  "))
        }
        #expect(throws: QuicklinkValidationError.self) {
            try store.add(link(template: "javascript:alert(1)"))
        }
    }

    @Test("校验失败不落盘、不改内存")
    @MainActor
    func failedValidationChangesNothing() throws {
        let file = tempFile()
        let store = QuicklinkStore(fileURL: file)
        try store.add(link())
        let before = try String(contentsOf: file, encoding: .utf8)
        #expect(throws: QuicklinkValidationError.self) {
            try store.add(link(keyword: "gh", title: "重复"))
        }
        #expect(store.links.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
    }

    // MARK: 存取

    @Test("持久化往返：新开一个 store 读出同样的内容")
    @MainActor
    func persistenceRoundTrip() throws {
        let file = tempFile()
        let first = QuicklinkStore(fileURL: file)
        try first.add(link(keyword: "gh", title: "GitHub"))
        try first.add(link(keyword: "mdn", title: "MDN",
                           template: "https://developer.mozilla.org/zh-CN/search?q={q}"))

        let second = QuicklinkStore(fileURL: file)
        #expect(second.links == first.links)

        second.remove(id: try #require(second.links.first?.id))
        let third = QuicklinkStore(fileURL: file)
        #expect(third.links.map(\.keyword) == ["mdn"])
    }

    @Test("坏 JSON 不当场覆盖，先留一份 .broken")
    @MainActor
    func brokenJsonIsBackedUp() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: file)

        let store = QuicklinkStore(fileURL: file)
        #expect(store.links.isEmpty)

        let backup = file.deletingPathExtension().appendingPathExtension("broken.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json at all")
    }

    // MARK: 查找

    @Test("关键词大小写不敏感、首尾空白忽略")
    @MainActor
    func lookupIsCaseInsensitive() throws {
        let store = QuicklinkStore(fileURL: tempFile())
        try store.add(link(keyword: "gh"))
        #expect(store.link(keyword: "GH")?.keyword == "gh")
        #expect(store.link(keyword: "  gh  ")?.keyword == "gh")
        #expect(store.link(keyword: "g") == nil)
    }

    @Test("搜索：前缀命中在前，同分保持存储顺序")
    @MainActor
    func searchRanking() throws {
        let store = QuicklinkStore(fileURL: tempFile())
        try store.add(link(keyword: "abc", title: "后加的前缀"))
        try store.add(link(keyword: "xabc", title: "包含"))
        try store.add(link(keyword: "ab", title: "短前缀"))
        #expect(store.search("ab").map(\.title) == ["短前缀", "后加的前缀", "包含"])
        #expect(store.search("").count == 3)
    }
}
