import Foundation
import Testing
@testable import MiscKitCore

/// 可选的真实快照阶段基准；默认跳过。
/// `MISCKIT_BENCH_DB=~/.cache/misckit-bench/snapshot2.sqlite3 swift test --filter FileIndexPhaseTimingTests`
@Suite("文件索引：阶段延迟基准")
struct FileIndexPhaseTimingTests {
    @Test("6 条代表查询的 fast/body/count 中位耗时",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    func phaseMedians() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        let db = FileIndexDatabase(url: URL(fileURLWithPath: path),
                                   readOnly: true, cacheSizeKB: 32 * 1024)
        try await db.open()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let cases: [(String, FileIndexQuery)] = [
            ("report", FileIndexQuery(syntax: FileSearchSyntax.parse("report"),
                                      category: .all, scope: .mac, directories: [],
                                      sort: .relevance, limit: 300)),
            ("合同", FileIndexQuery(syntax: FileSearchSyntax.parse("合同"),
                                    category: .all, scope: .mac, directories: [],
                                    sort: .relevance, limit: 300)),
            ("会议纪要", FileIndexQuery(syntax: FileSearchSyntax.parse("会议纪要"),
                                        category: .all, scope: .mac, directories: [],
                                        sort: .relevance, limit: 300)),
            ("screenshot", FileIndexQuery(syntax: FileSearchSyntax.parse("screenshot"),
                                          category: .all, scope: .mac, directories: [],
                                          sort: .relevance, limit: 300)),
            ("scope_home_report", FileIndexQuery(syntax: FileSearchSyntax.parse("report"),
                                                 category: .all, scope: .folders,
                                                 directories: [home],
                                                 sort: .relevance, limit: 300)),
            ("报价 2026", FileIndexQuery(syntax: FileSearchSyntax.parse("报价 2026"),
                                         category: .all, scope: .mac, directories: [],
                                         sort: .relevance, limit: 300)),
        ]

        for (_, query) in cases {
            _ = try await db.query(query, phase: .fast)
            _ = try await db.query(query, phase: .body)
            _ = try await db.query(query, phase: .count)
        }

        let reps = 5
        for (label, query) in cases {
            var fast: [Double] = []
            var body: [Double] = []
            var count: [Double] = []
            for _ in 0..<reps {
                var start = Date()
                _ = try await db.query(query, phase: .fast)
                fast.append(Date().timeIntervalSince(start) * 1000)

                start = Date()
                _ = try await db.query(query, phase: .body)
                body.append(Date().timeIntervalSince(start) * 1000)

                start = Date()
                _ = try await db.query(query, phase: .count)
                count.append(Date().timeIntervalSince(start) * 1000)
            }
            let f = median(fast), b = median(body), c = median(count)
            print(String(format: "PHASE %@ fast=%.2fms body=%.2fms count=%.2fms",
                         label, f, b, c))
        }

        await db.close()
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
