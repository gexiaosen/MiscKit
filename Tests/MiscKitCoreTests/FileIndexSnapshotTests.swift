import Foundation
import Testing
@testable import MiscKitCore

/// 真实索引快照的阶段回归。默认跳过；用 `MISCKIT_BENCH_DB` 指向
/// `~/.cache/misckit-bench/snapshot2.sqlite3` 时运行：
/// `MISCKIT_BENCH_DB=... swift test --filter FileIndexSnapshotTests`
@Suite("文件索引：真实快照阶段回归")
struct FileIndexSnapshotTests {
    private struct QueryCase {
        let label: String
        let text: String
        let category: FileCategory
        let scope: FileScope
        let sort: FileSort
        let directories: [URL]
    }

    @Test("16 条核心 + 12 条边界：fast 是 complete 的前缀，body 等于 complete，count 等于 complete",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    func phasesMatchComplete() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        let db = FileIndexDatabase(url: URL(fileURLWithPath: path),
                                   readOnly: true, cacheSizeKB: 32 * 1024)
        try await db.open()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let core: [QueryCase] = [
            .init(label: "single_common_report", text: "report", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "single_screenshot", text: "screenshot", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "single_rare_zzqxjv", text: "zzqxjv", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "single_cjk_contract", text: "合同", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "single_cjk_meeting_notes", text: "会议纪要", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "multi_quote_2026", text: "报价 2026", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "multi_final_report", text: "final report", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "long_40_rare",
                  text: "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "uppercase_Report", text: "Report", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "wildcard_rep", text: "rep*", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "category_image_screenshot", text: "screenshot", category: .image,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "folder_only_project", text: "project", category: .folder,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "ext_pdf_report", text: "report ext:pdf", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
            .init(label: "scope_home_report", text: "report", category: .all,
                  scope: .folders, sort: .relevance, directories: [home]),
            .init(label: "sort_modified_report", text: "report", category: .all,
                  scope: .mac, sort: .modified, directories: []),
            .init(label: "exclude_tmp_report", text: "report -tmp", category: .all,
                  scope: .mac, sort: .relevance, directories: []),
        ]
        let boundary: [QueryCase] = [
            "[", "]", "a[1]", "a_b", "_test", "%", "café", "CAFÉ",
            "*", "?", "合同", "\"季度 报告\"",
        ].map { .init(label: "boundary_\($0)", text: $0, category: .all,
                      scope: .mac, sort: .relevance, directories: []) }

        for item in core + boundary {
            let syntax = FileSearchSyntax.parse(item.text)
            let query = FileIndexQuery(syntax: syntax, category: item.category,
                                       scope: item.scope, directories: item.directories,
                                       sort: item.sort, limit: 80)
            let complete = try await db.query(query)
            let fast = try await db.query(query, phase: .fast)
            let body = try await db.query(query, phase: .body)
            let count = try await db.query(query, phase: .count)

            #expect(fast.entries == Array(complete.entries.prefix(fast.entries.count)),
                    "\(item.label): fast 不是 complete 的前缀")
            #expect(body.entries == complete.entries,
                    "\(item.label): body 与 complete 行集/顺序不一致")
            // body 不带计数：命中超过 80 时它只能给下界，complete 可能已经数到了精确值。
            #expect(body.total == min(complete.total, 80),
                    "\(item.label): body total 应是 complete total 的截断值")
            #expect(body.totalIsExact == (complete.total <= 80),
                    "\(item.label): body exact 标志应只在未截断时为真")
            #expect(count.total == complete.total,
                    "\(item.label): count total 不等于 complete total")
            #expect(count.totalIsExact == complete.totalIsExact,
                    "\(item.label): count exact 标志不一致")
        }

        await db.close()
    }

    /// P2：count 被新查询取代时能真正停下来，而且下一条 count 不被中断标志污染。
    /// 默认跳过；`MISCKIT_BENCH_DB` 指向 753k 行快照时运行。
    @Test("count 主动中断：在途 count 抛错，随后同一连接仍能正常计数",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    func countInterruptLeavesConnectionUsable() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        let db = FileIndexDatabase(url: URL(fileURLWithPath: path),
                                   readOnly: true, cacheSizeKB: 8 * 1024)
        try await db.open()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let syntax = FileSearchSyntax.parse("report")
        let query = FileIndexQuery(syntax: syntax, category: .all, scope: .folders,
                                   directories: [home], sort: .relevance, limit: 300)

        // scope=home 的 count 在 753k 行快照上约 250ms，留 15ms 让 SQL 真正跑起来。
        let inFlight = Task { try await db.query(query, phase: .count) }
        try await Task.sleep(for: .milliseconds(15))
        db.interrupt()
        let interrupted = await inFlight.result
        switch interrupted {
        case .success:
            Issue.record("count 在 15ms 内就结束了，无法验证 interrupt；请换更慢的查询或缓存状态")
        case .failure:
            break
        }

        // 中断只应影响在途语句；连接必须还能跑下一条 count。
        let next = try await db.query(query, phase: .count)
        #expect(next.total > 0, "中断后同一连接下一条 count 应正常返回")
        await db.close()
    }
}
