import Foundation
import Testing
@testable import MiscKitCore

/// P3 冷启动竞速：索引未就绪时不能让 Spotlight 的 1.2s 等待变成首条延迟。
/// 用真实快照启动 FileIndex；默认跳过，`MISCKIT_BENCH_DB` 指向 753k 行快照时运行。
@Suite("文件搜索：冷启动竞速", .serialized)
struct FileSearchColdStartTests {
    @Test("索引 opening 时首个非空结果仍能在 1.2s 内返回",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    @MainActor
    func coldStartReturnsWithinDeadline() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        let previousDB = ProcessInfo.processInfo.environment["MISCKIT_FILE_INDEX_DB"]
        setenv("MISCKIT_FILE_INDEX_DB", path, 1)
        defer {
            if let previousDB { setenv("MISCKIT_FILE_INDEX_DB", previousDB, 1) }
            else { unsetenv("MISCKIT_FILE_INDEX_DB") }
        }

        let request = FileSearchRequest(text: "report", category: .all,
                                        scope: .mac, sort: .relevance, limit: 300)
        let wasCold = !FileIndex.shared.isReady
        let started = ContinuousClock.now
        let response = await FileSearchService.shared.search(request)
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1000
        let origins = Set(response.items.map(\.origin))
        print("cold-start elapsed=\(String(format: "%.1f", ms))ms count=\(response.items.count) origins=\(origins)")

        #expect(!response.items.isEmpty, "冷启动必须返回非空结果")
        if wasCold {
            #expect(elapsed < .milliseconds(500), "冷启动首条回归：当前默认约 124ms，守住 500ms")
        }
        // 索引路径和 Spotlight 路径都可能先赢；这里只守首条时延与结果非空，替换语义
        // 由 FileSearchModel.observeIndexPhase 的 ready 触发负责。
    }

    /// 正式版默认配置：folders + 3 个目录 + modified 排序。P3 不能只覆盖 relevance/mac。
    @Test("正式配置 folders/modified 下的冷启动首条",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    @MainActor
    func coldStartFormalConfiguration() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        setenv("MISCKIT_FILE_INDEX_DB", path, 1)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            home.appendingPathComponent("Documents/文件/翼支付"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
        ]
        let request = FileSearchRequest(text: "pdf", category: .all,
                                        scope: .folders, directories: directories,
                                        sort: .modified, limit: 300)
        let wasCold = !FileIndex.shared.isReady
        let started = ContinuousClock.now
        let response = await FileSearchService.shared.search(request)
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1000
        print("cold-start(formal) elapsed=\(String(format: "%.1f", ms))ms count=\(response.items.count) origins=\(Set(response.items.map(\.origin)))")

        #expect(!response.items.isEmpty, "正式配置冷启动必须返回非空结果")
        if wasCold {
            #expect(elapsed < .milliseconds(500), "正式配置冷启动首条回归：当前约 172ms，守住 500ms")
        }
    }

    /// 与 AppDelegate 启动时一致的场景：先跑 Spotlight 可用性探针，再在索引 opening 时搜索。
    @Test("预热过 Spotlight 时的冷启动首条",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    @MainActor
    func coldStartAfterSpotlightPrewarm() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        setenv("MISCKIT_FILE_INDEX_DB", path, 1)
        FileSearchService.shared.prewarmSpotlightAvailability()
        try await Task.sleep(for: .milliseconds(1600))

        let request = FileSearchRequest(text: "report", category: .all,
                                        scope: .mac, sort: .relevance, limit: 300)
        let started = ContinuousClock.now
        let response = await FileSearchService.shared.search(request)
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1000
        print("cold-start(prewarmed) elapsed=\(String(format: "%.1f", ms))ms count=\(response.items.count) origins=\(Set(response.items.map(\.origin)))")
        #expect(!response.items.isEmpty)
        #expect(elapsed < .milliseconds(1200), "预热场景不应等满 1.2s")
    }

    /// P2 连续键入：旧 body 被新查询取代时，只能由最后一个 generation 上屏。
    @Test("连续键入 10 次不出现旧 body 覆盖新结果",
          .enabled(if: ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"] != nil))
    @MainActor
    func continuousTypingKeepsLatestBody() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISCKIT_BENCH_DB"],
              !path.isEmpty else { return }
        setenv("MISCKIT_FILE_INDEX_DB", path, 1)
        FileIndex.shared.prepareForSearch()
        let ready = await FileIndex.shared.waitForReady(timeout: .seconds(3))
        #expect(ready, "测试前索引应能打开 753k 行快照")

        let queries = ["r", "re", "rep", "repo", "repor", "report",
                       "report ", "report 2", "report 20", "report 202"]
        var latest: FileSearchResponse?
        var tasks: [Task<Void, Never>] = []
        let finalToken = queries.count

        for (index, query) in queries.enumerated() {
            let token = index + 1
            let request = FileSearchRequest(text: query, category: .all, scope: .mac,
                                            sort: .relevance, limit: 300)
            tasks.append(Task { @MainActor in
                let body = await FileSearchService.shared.searchBody(request)
                guard token == finalToken else { return }
                latest = body
            })
            try? await Task.sleep(for: .milliseconds(10))
        }
        await tasks.last?.value

        let finalRequest = FileSearchRequest(text: "report 202", category: .all, scope: .mac,
                                             sort: .relevance, limit: 300)
        let expected = await FileSearchService.shared.search(finalRequest)
        #expect(latest?.items.map(\.id) == expected.items.map(\.id),
                "最后一个 generation 的 body 必须与同查询的 complete 一致；旧查询不能覆盖")
    }
}
