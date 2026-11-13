import CoreServices
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - 从磁盘构建结果

public enum FileItemFactory {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey,
        .fileSizeKey, .contentAccessDateKey, .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    public static func make(url: URL, origin: FileOrigin) -> FileItem {
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let tree = type.map(typeTree) ?? (isDirectory ? ["public.folder"] : [])
        let status = values?.ubiquitousItemDownloadingStatus
        let downloaded = status == .current || status == .downloaded
        return FileItem(url: URL(fileURLWithPath: url.standardizedFileURL.path),
                        isDirectory: isDirectory,
                        contentType: type?.identifier,
                        contentTypeTree: tree,
                        creationDate: values?.creationDate,
                        modificationDate: values?.contentModificationDate,
                        lastUsedDate: values?.contentAccessDate,
                        fileSize: values?.fileSize.map(Int64.init),
                        isUbiquitous: values?.isUbiquitousItem ?? false,
                        isDownloaded: downloaded,
                        origin: origin)
    }

    public static func typeTree(_ type: UTType) -> [String] {        var seen = Set<String>()
        var result: [String] = []
        var queue = [type]
        while let current = queue.popLast() {
            guard seen.insert(current.identifier).inserted else { continue }
            result.append(current.identifier)
            queue.append(contentsOf: current.supertypes)
        }
        return result
    }
}

// MARK: - dotfiles 白名单索引

/// Spotlight 不索引隐藏文件。这里只收两类白名单：`~` 一级 dotfiles 与用户指定的项目根（深度 3）。
@MainActor
@Observable
public final class HiddenFileIndex {
    public static let shared = HiddenFileIndex()

    public private(set) var entries: [FileItem] = []

    private var refreshTask: Task<Void, Never>?
    private var homeWatcher: DirectoryEventWatcher?
    private var rootWatchers: [FSEventsDirectoryWatcher] = []
    private var startedRoots: [URL] = []
    private let scanLimit = 5000
    private let maxDepth = 3
    private let excludedNames: Set<String> = ["node_modules", ".build", "DerivedData", ".git", "Pods"]

    private init() {}

    public func start() {
        guard homeWatcher == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 一级 dotfiles 很便宜，先同步铺好，保证第一次查询就能搜到 ~/.zshrc
        entries = Self.scan(projectRoots: [], maxDepth: maxDepth, limit: scanLimit,
                            excluded: [])
        homeWatcher = DirectoryEventWatcher(path: home.path) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        restartRootWatchers()
        refresh()
    }

    public func refresh() {
        let roots = FileSearchSettings.shared.directories
        if roots != startedRoots { restartRootWatchers() }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let scanned = await Task.detached(priority: .utility) {
                Self.scan(projectRoots: roots, maxDepth: 3, limit: 5000,
                          excluded: ["node_modules", ".build", "DerivedData", ".git", "Pods"])
            }.value
            guard !Task.isCancelled else { return }
            self.entries = scanned
        }
    }

    /// 供服务同步取用；匹配大小写/变音不敏感，兼顾 `zshrc` 命中 `.zshrc`。
    public func search(term: String, category: FileCategory) -> [FileItem] {
        let needle = Self.normalize(term)
        guard !needle.isEmpty else { return [] }
        let matches = entries.filter { item in
            guard category.matches(item) else { return false }
            let name = Self.normalize(item.name)
            return name.contains(needle) || Self.normalize(item.url.path).contains(needle)
        }
        return matches.sorted { lhs, rhs in
            let l = Self.score(name: lhs.name, needle: needle)
            let r = Self.score(name: rhs.name, needle: needle)
            if l != r { return l > r }
            return lhs.url.path < rhs.url.path
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func restartRootWatchers() {
        rootWatchers.removeAll()
        let roots = FileSearchSettings.shared.directories
        startedRoots = roots
        guard !roots.isEmpty else { return }
        let watched = FSEventsDirectoryWatcher(paths: roots.map(\.path)) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        rootWatchers = [watched]
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func score(name: String, needle: String) -> Int {
        let clean = normalize(name).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if clean == needle { return 100 }
        if clean.hasPrefix(needle) { return 85 }
        return 70
    }

    /// `home` 只给测试换根；生产一律用默认值。
    nonisolated static func scan(projectRoots: [URL], maxDepth: Int, limit: Int,
                                 excluded: Set<String>,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FileItem] {
        var results: [FileItem] = []
        let fm = FileManager.default

        if let children = try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: []) {
            for url in children where url.lastPathComponent.hasPrefix(".") {
                results.append(FileItemFactory.make(url: url, origin: .hidden))
            }
        }

        for root in projectRoots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            ) else { continue }
            // 深度用枚举器自己的层级，不能用 pathComponents 相减：枚举器返回的是
            // 解析过符号链接的路径（/var 变 /private/var），根在链接下时会整整多算一层。
            while let url = enumerator.nextObject() as? URL {
                if results.count >= limit { return results }
                let depth = enumerator.level
                if depth > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                if excluded.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                results.append(FileItemFactory.make(url: url, origin: .hidden))
            }
        }
        return results
    }
}

// MARK: - 增量监听

/// 只监听目录这一层（不递归），用于 `~` 一级 dotfiles。
private final class DirectoryEventWatcher: @unchecked Sendable {
    private let descriptor: Int32
    private var source: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        descriptor = fd
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "app.misckit.dotfilewatcher", qos: .utility))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
