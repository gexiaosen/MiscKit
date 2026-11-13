import Foundation
import UniformTypeIdentifiers

// MARK: - 扫描策略

struct FileIndexPolicy: Sendable {
    /// 跳过规则变化时 +1；持久化版本不一致会触发一次全量重建。
    static let version = 2

    let home: URL
    let internalDirectory: String?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         internalDirectory: URL? = nil) {
        self.home = home.standardizedFileURL
        self.internalDirectory = internalDirectory?.standardizedFileURL.path
    }

    static let excludedNames: Set<String> = [
        ".git", ".svn", ".hg", ".build", "node_modules", "DerivedData", "Pods",
        ".gradle", ".venv", "venv", "__pycache__", ".next", ".nuxt", ".cache",
        ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".vol", "Caches",
    ]

    /// Application Support 是应用私有数据与缓存的聚集地（常占几十万项），
    /// 对文件搜索没有价值；iCloud Drive 所在的 Mobile Documents 仍然索引。
    private static let excludedLibraryChildren: Set<String> = [
        "Application Support", "Caches", "Developer", "Containers", "Group Containers",
        "Logs", "Saved Application State", "Metadata", "Biome", "Assistant", "MobileSync",
    ]

    func shouldSkip(directory url: URL, name: String) -> Bool {
        if Self.excludedNames.contains(name) { return true }
        if let internalDirectory, url.standardizedFileURL.path == internalDirectory {
            return true
        }
        if isExcludedHomeLibraryChild(url) { return true }
        return false
    }

    func shouldSkip(entry url: URL) -> Bool {
        guard let internalDirectory else { return false }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(internalDirectory + "/")
    }

    /// 增量事件的路径级过滤：全量扫描跳过的目录，后续事件也不能写回索引。
    func shouldSkip(path: String) -> Bool {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        if let internalDirectory,
           clean == internalDirectory || clean.hasPrefix(internalDirectory + "/") {
            return true
        }
        let components = clean.split(separator: "/").map(String.init)
        if components.contains(where: { Self.excludedNames.contains($0) }) { return true }

        let library = home.appendingPathComponent("Library").standardizedFileURL.path
        if clean.hasPrefix(library + "/") {
            let rest = clean.dropFirst(library.count + 1)
            if let first = rest.split(separator: "/").first,
               Self.excludedLibraryChildren.contains(String(first)) {
                return true
            }
        }
        if components.dropLast().contains(where: { component in
            Self.packageExtensions.contains { component.hasSuffix("." + $0) }
        }) {
            return true
        }
        return false
    }

    private static let packageExtensions: [String] = [
        "app", "framework", "bundle", "plugin", "appex", "kext", "systemextension",
        "xcodeproj", "xcworkspace", "playground", "docset", "pkg", "mpkg",
    ]

    private func isExcludedHomeLibraryChild(_ url: URL) -> Bool {
        let library = home.appendingPathComponent("Library").standardizedFileURL.path
        guard url.deletingLastPathComponent().standardizedFileURL.path == library else {
            return false
        }
        return Self.excludedLibraryChildren.contains(url.lastPathComponent)
    }
}

// MARK: - 类型归类

enum FileIndexKind {
    static func classify(ext: String) -> String {
        guard !ext.isEmpty else { return "other" }
        if FileCategory.word.fileExtensions.contains(ext) { return FileCategory.word.rawValue }
        if FileCategory.excel.fileExtensions.contains(ext) { return FileCategory.excel.rawValue }
        if FileCategory.ppt.fileExtensions.contains(ext) { return FileCategory.ppt.rawValue }
        guard let type = UTType(filenameExtension: ext) else { return "other" }
        if type.conforms(to: .image) { return FileCategory.image.rawValue }
        if type.conforms(to: .audio) { return FileCategory.audio.rawValue }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return FileCategory.video.rawValue
        }
        if type.conforms(to: .pdf) { return FileCategory.pdf.rawValue }
        return "other"
    }
}

// MARK: - 全量扫描

struct FileIndexScanProgress: Sendable {
    let inserted: Int
    let unreadable: Int
    let currentPath: String?
}

struct FileIndexScanResult: Sendable {
    let inserted: Int
    let unreadable: Int
}

enum FileIndexScanner {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentAccessDateKey,
    ]

    /// 非隔离的递归扫描；只在批间 `await`，不会占住主线程。
    /// `staging: true` 时写暂存表，正式表要等调用方交换才更新——全量重扫靠这个保证中断不丢索引。
    /// `batchPause` 给背后补扫用：每批之间让一下，把分钟级的磁盘与 CPU 抢占摊平（冷启不摊，那时没东西可服务）。
    static func scan(roots: [URL], into db: FileIndexDatabase, policy: FileIndexPolicy,
                     staging: Bool = false, batchPause: Duration = .zero,
                     progress: @Sendable (FileIndexScanProgress) async -> Void = { _ in })
        async throws -> FileIndexScanResult {
        let fm = FileManager.default
        var inserted = 0
        var unreadable = 0
        var batch: [FileIndexEntry] = []
        var kindCache: [String: String] = [:]
        var lastReport = ContinuousClock.now
        let reportInterval = Duration.milliseconds(220)

        for root in roots {
            if Task.isCancelled { throw CancellationError() }
            let rootURL = URL(fileURLWithPath: root.standardizedFileURL.path)
            if let internalDirectory = policy.internalDirectory,
               rootURL.path == internalDirectory || rootURL.path.hasPrefix(internalDirectory + "/") {
                continue
            }
            guard fm.fileExists(atPath: rootURL.path) else { continue }

            let rootEntry = entry(for: rootURL, isDirectory: true,
                                  values: try? rootURL.resourceValues(forKeys: resourceKeys),
                                  kindCache: &kindCache)
            batch.append(rootEntry)

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    unreadable += 1
                    return true
                }
            ) else {
                unreadable += 1
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { throw CancellationError() }
                var skipSubtree = false
                let entry: FileIndexEntry? = autoreleasepool {
                    if policy.shouldSkip(entry: url) { return nil }
                    let values = try? url.resourceValues(forKeys: resourceKeys)
                    let name = url.lastPathComponent
                    let isSymlink = values?.isSymbolicLink ?? false
                    let isDirectory = (values?.isDirectory ?? false) && !isSymlink
                    if isDirectory {
                        if policy.shouldSkip(directory: url, name: name) {
                            skipSubtree = true
                            return nil
                        }
                        // 包（.app/.xcodeproj 等）本身可被搜到，但不展开内部结构。
                        let isPackage = values?.isPackage ?? false
                        if isPackage {
                            skipSubtree = true
                            return entry(for: url, isDirectory: false,
                                         values: values, kindCache: &kindCache)
                        }
                    }
                    return entry(for: url, isDirectory: isDirectory,
                                 values: values, kindCache: &kindCache)
                }
                if skipSubtree { enumerator.skipDescendants() }
                if let entry { batch.append(entry) }

                if batch.count >= 1500 {
                    let chunk = batch
                    batch.removeAll(keepingCapacity: true)
                    if staging { try await db.stage(chunk) } else { try await db.upsert(chunk) }
                    inserted += chunk.count
                    if batchPause > .zero { try? await Task.sleep(for: batchPause) }
                    let now = ContinuousClock.now
                    if now - lastReport >= reportInterval {
                        lastReport = now
                        await progress(FileIndexScanProgress(
                            inserted: inserted, unreadable: unreadable,
                            currentPath: url.path))
                    }
                }
            }
        }

        if !batch.isEmpty {
            let chunk = batch
            batch.removeAll(keepingCapacity: true)
            if staging { try await db.stage(chunk) } else { try await db.upsert(chunk) }
            inserted += chunk.count
        }
        await progress(FileIndexScanProgress(inserted: inserted, unreadable: unreadable,
                                             currentPath: nil))
        return FileIndexScanResult(inserted: inserted, unreadable: unreadable)
    }

    static func entry(for url: URL, isDirectory: Bool, values: URLResourceValues?,
                      kindCache: inout [String: String]) -> FileIndexEntry {
        let clean = url.standardizedFileURL
        let name = clean.lastPathComponent
        if isDirectory {
            return FileIndexEntry(path: clean.path, name: name, isDirectory: true,
                                  ext: "", kind: FileCategory.folder.rawValue,
                                  size: nil,
                                  modified: values?.contentModificationDate,
                                  created: values?.creationDate,
                                  lastUsed: values?.contentAccessDate)
        }
        let ext = clean.pathExtension.lowercased()
        let kind: String
        if let cached = kindCache[ext] {
            kind = cached
        } else {
            let classified = FileIndexKind.classify(ext: ext)
            kindCache[ext] = classified
            kind = classified
        }
        return FileIndexEntry(path: clean.path, name: name, isDirectory: false,
                              ext: ext, kind: kind,
                              size: values?.fileSize.map(Int64.init),
                              modified: values?.contentModificationDate,
                              created: values?.creationDate,
                              lastUsed: values?.contentAccessDate)
    }
}

// MARK: - 索引位置

public enum FileIndexRoots {
    /// 默认索引：主目录、应用目录、共享目录与常见开发根；自定义目录去重并剔除被包含项。
    public static func defaultRoots(
        custom: [URL] = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var roots = [
            home,
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Users/Shared"),
        ]
        for path in ["/usr/local", "/opt/homebrew"] where FileManager.default.fileExists(atPath: path) {
            roots.append(URL(fileURLWithPath: path))
        }
        roots.append(contentsOf: custom.filter {
            FileManager.default.fileExists(atPath: $0.path)
        })
        return normalized(roots)
    }

    /// 去重并剔除被上层目录包含的根，避免同一棵树扫两遍。
    public static func normalized(_ roots: [URL]) -> [URL] {
        var result: [(path: String, url: URL)] = []
        for url in roots {
            let path = url.standardizedFileURL.path
            guard !path.isEmpty else { continue }
            if result.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                continue
            }
            result.removeAll { $0.path.hasPrefix(path + "/") }
            result.append((path, URL(fileURLWithPath: path)))
        }
        return result.map(\.url)
    }

    public static func signature(_ roots: [URL]) -> String {
        roots.map { $0.standardizedFileURL.path }.sorted().joined(separator: "\n")
    }
}
