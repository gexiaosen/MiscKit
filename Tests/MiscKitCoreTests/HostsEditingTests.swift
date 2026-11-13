import Foundation
import Testing

@testable import MiscKitCore

/// 段与行的编辑。重点盯两个静默错误：改名没同步标题行、删行没重映射逐行禁用。
/// （`#expect` 宏里不能调 mutating 方法，所以下面都是先赋值再断言。）
@Suite("Hosts 段与行编辑")
struct HostsEditingTests {
    private let sample = """
        #-------- 共用 --------
        127.0.0.1 localhost
        ::1 localhost
        #-------- DEMO --------
        10.0.0.7 a.demo
        10.0.0.8 b.demo
        10.0.0.9 c.demo
        10.0.0.10 d.demo
        """

    private func doc(_ text: String) -> HostsDocument { HostsDocument.parse(text) }

    // MARK: 改名

    @Test("改名会连标题行一起改写，重新导入时长回来的还是新名")
    func renameRewritesHeaderLine() {
        var d = doc(sample)
        let id = d.sections[1].id
        let renamed = d.renameSection(id: id, to: "DEMO 测试环境")
        #expect(renamed)
        #expect(!d.serialized().contains("#-------- DEMO --------"))
        #expect(d.serialized().contains("#-------- DEMO 测试环境 --------"))
        #expect(d.rendered().contains("#-------- DEMO 测试环境 --------"))

        // 关键：从文件再解析一次，名字对得上、行没丢
        let again = doc(d.rendered())
        #expect(again.sections.map(\.name) == ["共用", "DEMO 测试环境"])
        #expect(again.sections[1].lines.count == 4)
    }

    @Test("CRLF 文件里改名不破坏行尾风格")
    func renameKeepsLineEnding() {
        var d = doc(sample.replacingOccurrences(of: "\n", with: "\r\n"))
        let id = d.sections[1].id
        let renamed = d.renameSection(id: id, to: "新名")
        #expect(renamed)
        let header = d.sections[1].headerLine ?? ""
        #expect(header.hasSuffix("\r"), "CRLF 文档的标题行必须带 \\r，实得 \(header.debugDescription)")
        #expect(d.serialized().contains("\r\n"))
    }

    @Test("重名被拒，大小写不同也算重名，且被拒后原文没被改坏")
    func duplicateNamesRejected() {
        var d = doc(sample)
        let id = d.sections[1].id
        let clashToBase = d.renameSection(id: id, to: "共用")
        #expect(!clashToBase)
        let dupLower = d.addSection(named: "demo")
        let dupUpper = d.addSection(named: "DEMO")
        #expect(dupLower == nil)
        #expect(dupUpper == nil)
        #expect(d.serialized() == doc(sample).serialized())
        // 改名成自己现在的名字不该算撞名
        #expect(HostsDocument.nameProblem("DEMO", in: d.sections, ignoring: id) == nil)
    }

    @Test("整段替换保留注释/空行，清空逐行禁用标记")
    func replaceLinesBulk() {
        var d = doc(sample)
        let id = d.sections[1].id
        d.sections[1].disabledLines = [1, 3]
        let newLines = ["# 一段新注释", "", "10.0.0.20 x.demo", "10.0.0.21 y.demo"]
        let replaced = d.replaceLines(in: id, with: newLines)
        #expect(replaced)
        #expect(d.sections[1].lines == newLines)
        #expect(d.sections[1].disabledLines.isEmpty, "整段替换后旧下标不能留着")

        let again = doc(d.rendered())
        #expect(again.sections[1].lines == newLines)
    }

    @Test("段名首尾短横线会被解析吃掉，所以直接拒绝；中间的合法")
    func dashEdgeNamesRejected() {
        var d = doc(sample)
        let badDash = d.addSection(named: "-x-")
        let badBlank = d.addSection(named: "   ")
        let badNewline = d.addSection(named: "a\nb")
        let badLong = d.addSection(named: String(repeating: "名", count: 41))
        #expect(badDash == nil); #expect(badBlank == nil)
        #expect(badNewline == nil); #expect(badLong == nil)
        let ok = d.addSection(named: "内-部-短-横-线")
        #expect(ok != nil)
    }

    @Test("基座删不掉，叠加段能删干净")
    func baseCannotBeDeleted() {
        var d = doc(sample)
        let dropBase = d.removeSection(id: d.sections[0].id)
        #expect(!dropBase)
        #expect(d.sections.count == 2)
        let dropped = d.removeSection(id: d.sections[1].id)
        #expect(dropped)
        #expect(d.sections.count == 1)
        #expect(d.sections[0].isBase)
    }

    // MARK: 行编辑与 disabledLines 重映射

    @Test("删行后逐行禁用跟着前移 —— 按内容断言，不按编号")
    func deleteLineRemapsDisabled() {
        var d = doc(sample)
        let id = d.sections[1].id
        // DEMO 段的行下标：0=a.demo 1=b.demo 2=c.demo 3=d.demo
        d.sections[1].disabledLines = [3]              // 禁 d.demo
        #expect(!d.rendered().contains("d.demo"))
        #expect(d.rendered().contains("c.demo"))

        let deleted = d.deleteLine(in: id, at: 1)      // 删掉 b.demo
        #expect(deleted)
        #expect(d.sections[1].disabledLines == [2])
        // 剩下 a/c/d 三行，下标 2 必须仍然指着 d.demo —— 不能悄悄挪到 c.demo 上
        let out = d.rendered()
        #expect(out.contains("a.demo"))
        #expect(!out.contains("b.demo"), "被删的那行不该再出现")
        #expect(out.contains("c.demo"), "禁用标记错位的话，c.demo 会被吞掉")
        #expect(!out.contains("d.demo"))
        #expect(d.sections[1].lines[2].contains("d.demo"))
    }

    @Test("删掉被禁用的那一行时，标记消失且其余不错位")
    func deleteTheDisabledLineItself() {
        var d = doc(sample)
        d.sections[1].disabledLines = [1, 3]           // 禁 b.demo 与 d.demo
        let deleted2 = d.deleteLine(in: d.sections[1].id, at: 1)
        #expect(deleted2)
        #expect(d.sections[1].disabledLines == [2])
        let out = d.rendered()
        #expect(!out.contains("b.demo"))
        #expect(out.contains("c.demo"))
        #expect(!out.contains("d.demo"))
    }

    @Test("插行让插入点之后的禁用标记后移一位")
    func insertLineShiftsDisabledForward() {
        var d = doc(sample)
        let id = d.sections[1].id
        d.sections[1].disabledLines = [2]              // 禁 c.demo
        let inserted = d.insertLine("10.0.0.99 new.example.test", in: id, at: 1)
        #expect(inserted)
        #expect(d.sections[1].disabledLines == [3])
        #expect(d.sections[1].lines[3] == "10.0.0.9 c.demo")
        let out = d.rendered()
        #expect(!out.contains("c.demo"))
        #expect(out.contains("new.example.test"))
    }

    @Test("段尾追加不动已有禁用标记")
    func appendLineKeepsDisabled() {
        var d = doc(sample)
        let id = d.sections[1].id
        d.sections[1].disabledLines = [0]
        let appended = d.insertLine("10.0.9.9 tail.example.test", in: id)
        #expect(appended)
        #expect(d.sections[1].disabledLines == [0])
        let out = d.rendered()
        #expect(!out.contains("a.demo"))
        #expect(out.contains("tail.example.test"))
    }

    @Test("就地改行不动下标，禁用状态原样保留")
    func updateLineKeepsDisabledState() {
        var d = doc(sample)
        let id = d.sections[1].id
        d.sections[1].disabledLines = [2]
        let updated = d.updateLine(in: id, at: 2, to: "10.0.0.9 c.demo.changed")
        #expect(updated)
        #expect(d.sections[1].disabledLines == [2])
        #expect(!d.rendered().contains("c.demo.changed"))
    }

    @Test("新建段进 rendered，并排在基座之后")
    func addedSectionRenders() {
        var d = doc(sample)
        let id = d.addSection(named: "SYNC")
        #expect(id != nil)
        if let id {
            let put = d.insertLine("10.0.2.40 pg.local", in: id)
            #expect(put)
        }
        let out = d.rendered()
        #expect(out.contains("#-------- SYNC --------"))
        #expect(out.contains("pg.local"))
        #expect(d.orderedSections.map(\.name).last == "SYNC")
    }
}
