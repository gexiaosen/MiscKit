import Foundation
import Testing

@testable import MiscKitCore

/// `scan` 只读磁盘，测试全部落在临时目录里；`home` 参数就是为这件事开的。
private func makeTree() throws -> (home: URL, root: URL, cleanup: () -> Void) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("misckit-hidden-\(UUID().uuidString)", isDirectory: true)
    let home = base.appendingPathComponent("home", isDirectory: true)
    let root = base.appendingPathComponent("project", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    return (home, root, { try? fm.removeItem(at: base) })
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "x".write(to: url, atomically: true, encoding: .utf8)
}

private func names(_ items: [FileItem], under root: URL) -> Set<String> {
    Set(items.map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") })
}

@Suite("隐藏文件索引：白名单扫描")
struct HiddenFileIndexScanTests {
    @Test("~ 下只收一级 dotfiles，普通文件不进索引")
    func homeOnlyDotfiles() throws {
        let (home, root, cleanup) = try makeTree()
        defer { cleanup() }
        try touch(home.appendingPathComponent(".zshrc"))
        try touch(home.appendingPathComponent(".config/git/config"))
        try touch(home.appendingPathComponent("visible.txt"))

        let items = HiddenFileIndex.scan(projectRoots: [], maxDepth: 3, limit: 100,
                                         excluded: [], home: home)
        #expect(items.map(\.name).sorted() == [".config", ".zshrc"],
                "只收一级 dotfiles：dot 目录本身进，内容不展开；普通文件一律不进")
    }

    @Test("项目根：深度是相对根算的，超深的整棵剪掉")
    func depthLimitIsRelativeToRoot() throws {
        let (home, root, cleanup) = try makeTree()
        defer { cleanup() }
        try touch(root.appendingPathComponent("a.txt"))
        try touch(root.appendingPathComponent("sub/b.txt"))
        let deep = root.appendingPathComponent("sub/deep/c.txt")
        try touch(deep)
        let tooDeep = root.appendingPathComponent("sub/deep/deeper/d.txt")
        try touch(tooDeep)

        let items = HiddenFileIndex.scan(projectRoots: [root], maxDepth: 3, limit: 100,
                                         excluded: [], home: home)
        let got = names(items, under: root)
        #expect(got.contains("a.txt"))
        #expect(got.contains("sub/b.txt"))
        #expect(got.contains("sub/deep/c.txt"))
        #expect(!got.contains("sub/deep/deeper/d.txt"), "深过 maxDepth 的条目要整棵跳过")

        let shallow = HiddenFileIndex.scan(projectRoots: [root], maxDepth: 1, limit: 100,
                                           excluded: [], home: home)
        #expect(names(shallow, under: root) == ["a.txt", "sub"],
                "maxDepth 也是相对根算，不是全局绝对路径深度")
    }

    @Test("排除目录连同子树一起跳过，上限按已收条目算")
    func excludedAndLimit() throws {
        let (home, root, cleanup) = try makeTree()
        defer { cleanup() }
        try touch(root.appendingPathComponent("node_modules/pkg/index.js"))
        try touch(root.appendingPathComponent(".git/config"))
        try touch(root.appendingPathComponent("keep.txt"))

        let items = HiddenFileIndex.scan(projectRoots: [root], maxDepth: 4, limit: 100,
                                         excluded: ["node_modules", ".git"], home: home)
        let got = names(items, under: root)
        #expect(got.contains("keep.txt"))
        #expect(!got.contains("node_modules/pkg/index.js"), "排除目录连同子树一起跳过")
        #expect(!got.contains(".git/config"))

        let capped = HiddenFileIndex.scan(projectRoots: [root], maxDepth: 4, limit: 1,
                                          excluded: [], home: home)
        #expect(capped.count == 1, "上限到了就停，不是超了才截")
    }

    @Test("不存在的项目根不炸，直接跳过")
    func missingRootIsSkipped() throws {
        let (home, root, cleanup) = try makeTree()
        defer { cleanup() }
        let ghost = root.appendingPathComponent("ghost", isDirectory: true)
        let items = HiddenFileIndex.scan(projectRoots: [ghost], maxDepth: 3, limit: 100,
                                         excluded: [], home: home)
        #expect(items.isEmpty)
    }
}
