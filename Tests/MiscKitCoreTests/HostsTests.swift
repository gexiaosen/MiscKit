import Foundation
import Testing
@testable import MiscKitCore

private let hostsFixture = """
# 合成 fixture，仅用于测试
#-------- 共用 --------
127.0.0.1 localhost
10.0.0.1 api.example.test
#-------- 自定义 --------
10.0.0.2 app.example.test
# 这行是注释
10.0.0.3 db.example.test # 行尾注释
#-------- 办公 --------
10.0.0.4 vpn.example.test

"""

private let conflictFixture = """
#-------- 共用 --------
10.0.0.1 same.example.test
#-------- 自定义 --------
10.0.0.2 same.example.test
"""

@Suite("Hosts 解析与渲染")
struct HostsDocumentTests {
    @Test("段标题识别：两侧各至少两个短横线")
    func sectionHeader() {
        #expect(HostsDocument.sectionName(in: "#-------- 共用 --------") == "共用")
        #expect(HostsDocument.sectionName(in: "#-- 自定义 --") == "自定义")
        #expect(HostsDocument.sectionName(in: "# --- x ---") == "x")
        #expect(HostsDocument.sectionName(in: "#-------- a -- b --------") == "a -- b")
        #expect(HostsDocument.sectionName(in: "#- x -") == nil)
        #expect(HostsDocument.sectionName(in: "# ----------") == nil)
        #expect(HostsDocument.sectionName(in: "# 普通注释") == nil)
    }

    @Test("原文往返逐字节一致（LF 与 CRLF）")
    func roundTrip() {
        for text in [hostsFixture, hostsFixture.replacingOccurrences(of: "\n", with: "\r\n")] {
            let document = HostsDocument.parse(text)
            #expect(document.serialized() == text)
            #expect(document.sections.map(\.name) == ["共用", "自定义", "办公"])
            #expect(document.sections.first?.isBase == true)
            #expect(document.preamble.count == 1)
            #expect(document.preamble[0].hasPrefix("# 合成 fixture，仅用于测试"))
        }
        #expect(HostsDocument.parse("a\nb").serialized() == "a\nb")
        #expect(HostsDocument.parse("a\nb\n").serialized() == "a\nb\n")
        #expect(HostsDocument.parse("").serialized() == "")
    }

    @Test("没有段标题的旧文件整体成为共用的基座")
    func headerlessFile() {
        let document = HostsDocument.parse("127.0.0.1 localhost\n10.0.0.1 a.example.test\n")
        #expect(document.preamble.isEmpty)
        #expect(document.sections.count == 1)
        #expect(document.sections[0].name == "共用")
        #expect(document.sections[0].isBase)
        #expect(document.sections[0].mappingLineCount == 2)
        #expect(document.serialized() == "127.0.0.1 localhost\n10.0.0.1 a.example.test\n")
    }

    @Test("渲染：基座在前、禁用段/禁用行不写入")
    func render() {
        var document = HostsDocument.parse(hostsFixture)
        guard let shared = document.sections.firstIndex(where: { $0.name == "共用" }),
              let custom = document.sections.firstIndex(where: { $0.name == "自定义" })
        else {
            Issue.record("fixture 段缺失")
            return
        }
        document.sections[custom].isEnabled = false
        document.sections[shared].disabledLines = [1]

        let rendered = document.rendered()
        #expect(rendered.contains("#-------- 共用 --------"))
        #expect(!rendered.contains("#-------- 自定义 --------"))
        #expect(!rendered.contains("app.example.test"))
        #expect(!rendered.contains("api.example.test"))
        #expect(rendered.contains("127.0.0.1 localhost"))
        #expect(rendered.hasSuffix("\n"))

        var reordered = HostsDocument.parse(hostsFixture)
        reordered.sections.swapAt(0, 2)
        #expect(reordered.rendered().range(of: "共用")!.lowerBound
                < reordered.rendered().range(of: "办公")!.lowerBound)
    }
}

@Suite("Hosts 校验、冲突与 diff")
struct HostsAnalysisTests {
    @Test("逐行校验：IP、域名、列数与 Tab/空格")
    func validation() {
        #expect(HostsLineParser.parse("10.0.0.1 a.example.test").isValidMapping)
        #expect(HostsLineParser.parse("::1 localhost").isValidMapping)
        #expect(HostsLineParser.parse("10.0.0.1 a.example.test b.example.test").isValidMapping)
        #expect(HostsLineParser.parse("10.0.0.1\ta.example.test").issues.isEmpty)
        #expect(HostsLineParser.parse("10.0.0.1 \ta.example.test").issues.first?.severity == .warning)

        let badIP = HostsLineParser.parse("999.0.0.1 a.example.test")
        #expect(badIP.ip == nil && badIP.hasError)
        let noDomain = HostsLineParser.parse("10.0.0.1")
        #expect(noDomain.hasError)
        let badDomain = HostsLineParser.parse("10.0.0.1 bad?.example.test")
        #expect(badDomain.hasError)
        let comment = HostsLineParser.parse("  # 10.0.0.1 ignored.test")
        #expect(comment.isComment && !comment.hasError)
        let inline = HostsLineParser.parse("10.0.0.9 ok.example.test # note")
        #expect(inline.isValidMapping && inline.domains == ["ok.example.test"])
    }

    @Test("跨段同域名不同 IP 判冲突，同 IP 不判")
    func conflicts() {
        let document = HostsDocument.parse(conflictFixture)
        let report = HostsReport.build(document: document, currentText: conflictFixture)
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.entries.count == 2)
        #expect(report.blockingIssues.isEmpty)

        var sameIP = conflictFixture.replacingOccurrences(of: "10.0.0.2", with: "10.0.0.1")
        var sameDocument = HostsDocument.parse(sameIP)
        #expect(HostsReport.build(document: sameDocument, currentText: sameIP)
            .conflicts.isEmpty)

        // 关掉叠加段后冲突消失
        let overlay = sameDocument.sections.firstIndex { !$0.isBase }!
        sameDocument.sections[overlay].isEnabled = false
        sameIP = sameDocument.rendered()
        #expect(HostsReport.build(document: sameDocument, currentText: sameIP)
            .conflicts.isEmpty)
    }

    @Test("diff：新增、移除、改 IP 三类")
    func diff() {
        let current = """
        #-------- 共用 --------
        10.0.0.1 a.example.test
        10.0.0.2 b.example.test

        """
        var document = HostsDocument.parse(current)
        document.sections[0].lines = [
            "10.0.0.9 a.example.test",
            "10.0.0.3 c.example.test",
        ]
        let report = HostsReport.build(document: document, currentText: current)
        #expect(report.diff.added.map(\.domain) == ["c.example.test"])
        #expect(report.diff.removed.map(\.domain) == ["b.example.test"])
        #expect(report.diff.changed.map(\.domain) == ["a.example.test"])
        #expect(report.diff.changed.first?.oldIP == "10.0.0.1")
        #expect(report.diff.changed.first?.newIP == "10.0.0.9")
    }

    @Test("生效预览取后者，并标出来源段")
    func effectiveSource() {
        let document = HostsDocument.parse(conflictFixture)
        let report = HostsReport.build(document: document, currentText: conflictFixture)
        let entry = report.effective.first { $0.domain == "same.example.test" }
        #expect(entry?.ip == "10.0.0.2")
        #expect(entry?.sectionName == "自定义")
    }
}

@Suite("Hosts 状态、备份与写回", .serialized)
@MainActor
struct HostsStoreTests {
    private struct Fixture {
        let root: URL
        let hostsFile: URL
        let support: URL
        let cleanup: () -> Void
    }

    private func makeFixture(_ text: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-hosts-tests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let hosts = root.appendingPathComponent("hosts", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: hosts, atomically: true, encoding: .utf8)
        return Fixture(root: root, hostsFile: hosts, support: support,
                       cleanup: { try? FileManager.default.removeItem(at: root) })
    }

    private func makeStore(_ fixture: Fixture) -> HostsStore {
        HostsStore(paths: HostsPaths(hostsFile: fixture.hostsFile,
                                     supportDirectory: fixture.support))
    }

    @Test("应用、禁用段、回滚与逐字节还原")
    func applyAndRestore() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()
        #expect(store.hasLoaded)
        #expect(store.document.sections.count == 3)

        let custom = try #require(store.document.sections.first { $0.name == "自定义" })
        store.setSectionEnabled(custom.id, enabled: false)
        let result = try await store.apply()
        #expect(result.diff.removed.contains { $0.domain == "app.example.test" })

        let written = try String(contentsOf: fixture.hostsFile, encoding: .utf8)
        #expect(!written.contains("app.example.test"))
        #expect(!written.contains("db.example.test"))
        #expect(written.contains("api.example.test"))
        #expect(store.backups.count == 1)

        let backup = try #require(store.backups.first)
        try await store.restore(backup)
        let restored = try String(contentsOf: fixture.hostsFile, encoding: .utf8)
        #expect(restored == hostsFixture)
        #expect(store.document.sections.count == 3)

        // 回滚本身也留了安全备份
        #expect(store.backups.count == 2)
    }

    @Test("手动备份当前 hosts；手动备份不会被当成应用前备份")
    func manualBackup() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()

        let manual = try store.createBackup()
        #expect(!manual.isApplyBackup)
        #expect(store.backups.count == 1)
        #expect(store.lastApplyBackup == nil, "还没应用过，应用前备份应为空")

        _ = try await store.apply()
        #expect(store.backups.count == 2)
        #expect(store.lastApplyBackup?.isApplyBackup == true)

        _ = try store.createBackup()
        #expect(store.backups.count == 3)
        #expect(store.lastApplyBackup?.isApplyBackup == true,
                "更新的手动备份不能顶掉应用前那一份")
    }

    @Test("行级禁用持久化到工具侧，不写进 hosts")
    func lineDisablePersistence() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()

        let shared = try #require(store.document.sections.first { $0.isBase })
        let index = try #require(shared.lines.firstIndex { $0.contains("api.example.test") })
        store.toggleLine(sectionID: shared.id, lineIndex: index)

        let rendered = store.document.rendered()
        #expect(!rendered.contains("api.example.test"))
        #expect(store.document.sections.first { $0.isBase }?
            .disabledLines.contains(index) == true)

        let reloaded = makeStore(fixture)
        reloaded.ensureLoaded()
        #expect(reloaded.document.sections.first { $0.isBase }?
            .disabledLines.contains(index) == true)
    }

    @Test("外部改动检测：提示且拒绝静默覆盖")
    func externalChange() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()
        #expect(!store.externalChange)

        let manual = hostsFixture + "10.0.0.9 manual.example.test\n"
        try manual.write(to: fixture.hostsFile, atomically: true, encoding: .utf8)
        store.refreshExternalState()
        #expect(store.externalChange)

        await #expect(throws: HostsError.self) {
            _ = try await store.apply()
        }

        try store.reimportFromDisk()
        #expect(!store.externalChange)
        #expect(store.document.sections.contains { section in
            section.lines.contains { $0.contains("manual.example.test") }
        })
    }

    @Test("保留工具版本后不再重复提示，应用会覆盖外部改动")
    func keepToolVersion() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()

        let manual = hostsFixture.replacingOccurrences(of: "api.example.test",
                                                       with: "manual.example.test")
        try manual.write(to: fixture.hostsFile, atomically: true, encoding: .utf8)
        store.refreshExternalState()
        #expect(store.externalChange)

        store.keepToolVersion()
        #expect(!store.externalChange)
        store.refreshExternalState()
        #expect(!store.externalChange)

        _ = try await store.apply()
        let written = try String(contentsOf: fixture.hostsFile, encoding: .utf8)
        #expect(written.contains("api.example.test"))
        #expect(!written.contains("manual.example.test"))
    }

    @Test("跨段冲突必须显式确认后才写入")
    func conflictRequiresConfirmation() async throws {
        let fixture = try makeFixture(conflictFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()
        #expect(store.report.conflicts.count == 1)

        do {
            _ = try await store.apply()
            Issue.record("冲突未确认也应用了")
        } catch let error as HostsError {
            guard case .conflictsRequireConfirmation = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
        _ = try await store.apply(acknowledgingConflicts: true)
        #expect(store.report.conflicts.count == 1)
    }

    @Test("校验错误阻止写入")
    func blockingError() async throws {
        let bad = """
        #-------- 共用 --------
        999.0.0.1 bad.example.test

        """
        let fixture = try makeFixture(bad)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()
        #expect(!store.report.blockingIssues.isEmpty)
        await #expect(throws: HostsError.self) {
            _ = try await store.apply()
        }
        let written = try String(contentsOf: fixture.hostsFile, encoding: .utf8)
        #expect(written == bad)
    }

    @Test("全部段关闭时拒绝写入空白 hosts")
    func refuseEmpty() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()
        for section in store.document.sections {
            store.setSectionEnabled(section.id, enabled: false)
        }
        await #expect(throws: HostsError.self) {
            _ = try await store.apply()
        }
    }

    @Test("异步外部变更检测更新磁盘快照与报告")
    func refreshExternalStateAsyncDetectsModification() async throws {
        let fixture = try makeFixture(hostsFixture)
        defer { fixture.cleanup() }
        let store = makeStore(fixture)
        store.ensureLoaded()
        #expect(!store.externalChange)

        let modified = hostsFixture + "127.0.0.1 external.example.test\n"
        try modified.write(to: fixture.hostsFile, atomically: true, encoding: .utf8)

        await store.refreshExternalStateAsync()
        #expect(store.externalChange)
        #expect(store.report.diff.removed.contains { $0.domain == "external.example.test" })
    }
}

@Test("管理员脚本：写盘失败要报错，DNS 刷新失败不算错")
func privilegedScriptToleratesMissingDnsFlush() {
    let script = HostsWriter.privilegedShellCommand(tempPath: "/tmp/misckit-probe.txt")
    #expect(script.hasPrefix("set -e"), "写盘三步必须失败即停")
    #expect(script.contains("/bin/mv -f '/etc/.hosts.misckit.tmp' '/etc/hosts'"))
    // macOS 26 把 dscacheutil 从 /usr/sbin 挪到了 /usr/bin：两处都要探测，
    // 且刷新失败只能吞掉——写盘成功之后它没资格把整次应用判红。
    #expect(script.contains("if [ -x /usr/bin/dscacheutil ]"))
    #expect(script.contains("elif [ -x /usr/sbin/dscacheutil ]"))
    #expect(script.contains("dscacheutil -flushcache >/dev/null 2>&1 || true"))
    #expect(script.contains("killall -HUP mDNSResponder >/dev/null 2>&1 || true"))
}

@Test("管理员脚本：临时路径含单引号时不能被截断成新命令")
func privilegedScriptQuotesSingleQuotesInPath() {
    let hostile = "/tmp/misckit-'; touch /tmp/pwned; '.txt"
    let script = HostsWriter.privilegedShellCommand(tempPath: hostile)
    // 未转义的 `'` 会提前闭合引号，`; touch …;` 就成了独立命令
    #expect(!script.contains("'\(hostile)'" + " '/etc/.hosts.misckit.tmp'"),
            "路径被原样塞进单引号里 —— 这正是要防的截断")
    #expect(script.contains("'/tmp/misckit-'\\''; touch /tmp/pwned; '\\''.txt'"),
            "按 POSIX 的 '\\'' 规则闭合-转义-重开")
}

@Test("Shell 引用经 /bin/sh 解析后逐字节还原")
func shellQuotedRoundTripsThroughSh() throws {
    // 用 printf 代跑：命令若被 `;` 截断，输出就只剩前半段
    for path in ["/tmp/plain.txt", "/tmp/misckit-'; echo injected; '.txt", "/tmp/带 空格.txt"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(HostsWriter.shellQuoted(path))"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: data, as: UTF8.self) == path, "引用后必须还原成原路径：\(path)")
    }
}

@MainActor
@Test("段按一格移动：下移真的往下走，基座不动")
func moveSectionByOffsetActuallyMoves() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("misckit-hosts-move-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let hosts = root.appendingPathComponent("hosts")
    try hostsFixture.write(to: hosts, atomically: true, encoding: .utf8)
    let store = HostsStore(paths: HostsPaths(hostsFile: hosts,
                                             supportDirectory: root.appendingPathComponent("Support")))
    store.ensureLoaded()
    #expect(store.document.sections.map(\.name) == ["共用", "自定义", "办公"])

    let custom = try #require(store.document.sections.first { $0.name == "自定义" })
    store.moveSection(custom.id, offset: 1)
    #expect(store.document.sections.map(\.name) == ["共用", "办公", "自定义"],
            "下移必须是真下移：以前算出目标后被移除项挤回原位，整条是 no-op")

    store.moveSection(custom.id, offset: -1)
    #expect(store.document.sections.map(\.name) == ["共用", "自定义", "办公"])

    let base = try #require(store.document.sections.first { $0.isBase })
    store.moveSection(base.id, offset: 1)
    #expect(store.document.sections.first?.isBase == true, "基座永远最前")
}
