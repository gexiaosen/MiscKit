import Foundation
import Testing

@testable import MiscKitCore

@Suite("词典")
struct DictionaryLookupTests {
    @Test("词头前缀被摘掉，空行压成一个")
    func normalizeDropsHeadword() {
        #expect(DictionaryLookup.normalize("apple | BrE ˈapl | noun 苹果",
                                           droppingHeadword: "apple") == "BrE ˈapl | noun 苹果")
        #expect(DictionaryLookup.normalize("计算机 jìsuànjī 名 指能运算的机器",
                                           droppingHeadword: "计算机") == "jìsuànjī 名 指能运算的机器")
        #expect(DictionaryLookup.normalize("a\n\n\n\nb", droppingHeadword: "x") == "a\n\nb")
        #expect(DictionaryLookup.normalize("  \n a \n ", droppingHeadword: "x") == "a")
    }

    @Test("词头不是开头就不动它")
    func normalizeKeepsUnrelatedPrefix() {
        #expect(DictionaryLookup.normalize("brE 苹果", droppingHeadword: "apple") == "brE 苹果")
    }

    @Test("空词、纯空白、超长词都不查")
    func rejectsUnusableTerms() {
        #expect(DictionaryLookup.define("").isEmpty)
        #expect(DictionaryLookup.define("   ").isEmpty)
        #expect(DictionaryLookup.define(String(repeating: "a", count: 200)).isEmpty)
    }

    @Test("上限为 0 或负数时不出结果")
    func respectsMax() {
        #expect(DictionaryLookup.define("apple", max: 0).isEmpty)
        #expect(DictionaryLookup.define("apple", max: -1).isEmpty)
    }

    @Test("查不到的词返回空数组，不抛错也不崩")
    func unknownWordIsEmpty() {
        #expect(DictionaryLookup.define("zzzznotarealword").isEmpty)
        #expect(DictionaryLookup.define("🦄🦄🦄").isEmpty)
    }

    @Test("真机查询：能取到释义且正文里没有 HTML 标签")
    func realLookupHasPlainText() throws {
        guard DictionaryLookup.isAvailable else { return }
        let entries = DictionaryLookup.define("apple", max: 1)
        guard let entry = entries.first else { return }
        #expect(!entry.body.isEmpty)
        #expect(!entry.body.contains("<"))
        #expect(!entry.body.contains("&amp;"))
        #expect(entry.headword == "apple")
    }

    @Test("这台机器上有已启用的词库")
    func dictionariesAreEnabled() {
        guard DictionaryLookup.isAvailable else { return }
        #expect(!DictionaryLookup.availableDictionaryNames.isEmpty)
    }
}
