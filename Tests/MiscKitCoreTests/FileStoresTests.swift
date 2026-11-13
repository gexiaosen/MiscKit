import Foundation
import Testing

@testable import MiscKitCore

private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "misckit-filestores-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

private func cleanup(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("misckit-filestores-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFile(_ name: String, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try "x".write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// 三个存储都从 `UserDefaults` 读，测试一律用独立 suite，不许碰真实域。
/// 涉及"文件是否存在"的路径都落在真实临时目录里：`pruneMissing` 是按磁盘现状判断的。
@MainActor
@Suite("文件：最近打开、固定、别名与搜索偏好")
struct FileStoresTests {
    @Test("最近打开：重复项提到最前，只留 9 条")
    func recentsDedupAndCap() throws {
        let (defaults, suite) = makeDefaults()
        let dir = try makeTempDir()
        defer { cleanup(defaults, suite); try? FileManager.default.removeItem(at: dir) }
        let store = FileHistoryStore(defaults: defaults)

        var urls: [URL] = []
        for index in 0..<11 {
            let url = try makeFile("f\(index).txt", in: dir)
            urls.append(url)
            store.recordOpen(url)
        }
        #expect(store.recents.count == 9, "上限就是 9 条")
        #expect(store.recents.first?.lastPathComponent == "f10.txt")
        #expect(store.recents.contains { $0.lastPathComponent == "f0.txt" } == false,
                "最早的两条该被挤掉")

        store.recordOpen(urls[5])
        #expect(store.recents.first?.lastPathComponent == "f5.txt", "再打开旧项要提到最前")
        #expect(store.recents.filter { $0.lastPathComponent == "f5.txt" }.count == 1, "不许出现两份")
        #expect(store.recents.count == 9)
    }

    @Test("候选：固定排在最近前面，同一路径只出现一次")
    func candidatesPinFirstThenRecents() throws {
        let (defaults, suite) = makeDefaults()
        let dir = try makeTempDir()
        defer { cleanup(defaults, suite); try? FileManager.default.removeItem(at: dir) }
        let store = FileHistoryStore(defaults: defaults)
        let a = try makeFile("a.txt", in: dir)
        let b = try makeFile("b.txt", in: dir)

        store.togglePin(a)
        store.recordOpen(b)
        store.recordOpen(a)

        let candidates = store.candidates()
        #expect(candidates.map(\.url.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(candidates.first?.origin == .pinned)
        #expect(candidates.last?.origin == .recent)

        store.togglePin(a)
        #expect(!store.isPinned(a))
        #expect(store.candidates().map(\.url.lastPathComponent) == ["a.txt", "b.txt"],
                "取消固定后 a 仍在最近里，不该丢")
    }

    @Test("重开时把已经不存在的路径清掉")
    func prunesMissingPathsOnLoad() throws {
        let (defaults, suite) = makeDefaults()
        let dir = try makeTempDir()
        defer { cleanup(defaults, suite); try? FileManager.default.removeItem(at: dir) }
        let x = try makeFile("x.txt", in: dir)
        let y = try makeFile("y.txt", in: dir)
        let first = FileHistoryStore(defaults: defaults)
        first.recordOpen(x)
        first.recordOpen(y)
        #expect(first.recents.count == 2)

        try FileManager.default.removeItem(at: y)
        let second = FileHistoryStore(defaults: defaults)
        #expect(second.recents.map(\.lastPathComponent) == ["x.txt"])
    }

    @Test("别名：设置、覆盖、删除、重开还在；纯空白名字不生效")
    func aliasStoreLifecycle() throws {
        let (defaults, suite) = makeDefaults()
        let dir = try makeTempDir()
        defer { cleanup(defaults, suite); try? FileManager.default.removeItem(at: dir) }
        let store = FileAliasStore(defaults: defaults)
        let first = dir.appendingPathComponent("one", isDirectory: true)
        let second = dir.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        store.set("报价", for: first)
        #expect(store.alias(for: first) == "报价")

        store.set("   ", for: second)
        #expect(store.alias(for: second) == nil, "空白名字不该存进来")

        store.set("报价", for: second)
        #expect(store.alias(for: first) == nil, "同名重新指向后旧目录不再有别名")
        #expect(store.alias(for: second) == "报价")

        let reopened = FileAliasStore(defaults: defaults)
        #expect(reopened.alias(for: second) == "报价", "别名要落盘")

        reopened.remove("报价")
        #expect(reopened.alias(for: second) == nil)
        #expect(FileAliasStore(defaults: defaults).alias(for: second) == nil, "删除也要落盘")
    }

    @Test("搜索偏好：目录去重、删空回全盘、重开还在")
    func searchSettingsLifecycle() throws {
        let (defaults, suite) = makeDefaults()
        let dir = try makeTempDir()
        defer { cleanup(defaults, suite); try? FileManager.default.removeItem(at: dir) }
        let store = FileSearchSettings(defaults: defaults)
        #expect(store.scope == .mac)
        #expect(store.sort == .relevance)
        #expect(store.viewMode == .split)
        #expect(store.directories.isEmpty)

        store.addDirectory(dir)
        store.addDirectory(dir)
        #expect(store.directories.count == 1, "同一目录加两次不能出现两份")

        store.scope = .folders
        store.sort = .name
        store.viewMode = .list
        let reopened = FileSearchSettings(defaults: defaults)
        #expect(reopened.scope == .folders)
        #expect(reopened.sort == .name)
        #expect(reopened.viewMode == .list)
        #expect(reopened.directories.map(\.path) == [dir.path])

        reopened.removeDirectory(dir)
        #expect(reopened.directories.isEmpty)
        #expect(reopened.scope == .mac, "删光指定目录要退回全盘，否则搜索范围是空的")
        #expect(FileSearchSettings(defaults: defaults).scope == .mac)
    }
}
