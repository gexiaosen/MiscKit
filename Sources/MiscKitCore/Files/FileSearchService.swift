import AppKit
import Foundation
import os

public struct FileSearchRequest: Sendable {
    public var text: String
    public var category: FileCategory
    public var scope: FileScope
    public var directories: [URL]
    public var sort: FileSort
    public var limit: Int

    public init(text: String, category: FileCategory = .all, scope: FileScope = .mac,
                directories: [URL] = [], sort: FileSort = .relevance, limit: Int = 80) {
        self.text = text
        self.category = category
        self.scope = scope
        self.directories = directories
        self.sort = sort
        self.limit = limit
    }
}

/// Spotlight 查询封装：一次查询在驻留查询结束时取回，取消时停掉在途查询。
@MainActor
public final class FileSearchService {
    public static let shared = FileSearchService()

    private var activeQuery: NSMetadataQuery?
    /// 只写 `true`：探针的"能用"是稳定结论，"不能用"可能只是 Spotlight 还没热，见 `prewarmSpotlightAvailability`。
    private var spotlightAvailable: Bool?
    private var lastNegativeProbeAt: Date?
    private var availabilityTask: Task<Bool, Never>?
    private var querySequence = 0
    private static let negativeProbeRetry: TimeInterval = 30
    private let log = Logger(subsystem: "app.misckit.launcher", category: "filesearch")

    private init() {}

    public func search(_ request: FileSearchRequest) async -> FileSearchResponse {
        let parser = FileQueryParser(aliases: FileAliasStore.shared.aliases)
        switch parser.parse(request.text) {
        case .none:
            return FileSearchResponse(items: [], total: 0, isTruncated: false)
        case .browse:
            return browseHistory(request)
        case .path(let path):
            return resolve(path: path, request: request)
        case .search(let term):
            FileIndex.shared.prepareForSearch()
            // 「还没就绪」不等于「坏了」：冷启动第一次搜索几乎必然撞上 .idle/.opening，
            // 立刻掉到兜底就永远看不到索引结果。实测打开 + 计数 4.9ms，等一拍代价极低。
            if !FileIndex.shared.isReady {
                _ = await FileIndex.shared.waitForReady(timeout: .milliseconds(1200))
            }
            if FileIndex.shared.isReady,
               let indexed = await searchIndex(term: term, request: request) {
                return indexed
            }
            return await searchSpotlight(term: term, request: request)
        }
    }

    /// 索引就绪后的主路径：查询直接走 SQLite，不再启动 Spotlight。
    private func searchIndex(term: String, request: FileSearchRequest) async -> FileSearchResponse? {
        let started = Date()
        do {
            let response = try await FileIndex.shared.search(term: term, request: request)
            debugLog(String(format: "index query term=%@ count=%ld index=%.1fms",
                            term, response.total,
                            Date().timeIntervalSince(started) * 1000))
            traceSearch(via: "index", started: started, count: response.items.count, term: term)
            return response
        } catch {
            log.error("index query failed: \(error.localizedDescription, privacy: .public)")
            traceSearch(via: "index-error", started: started, count: 0, term: term)
            return nil
        }
    }

    /// 每次搜索走哪条路、多久、几条——打包版也要有读数，否则"搜索中…"卡住时无从下手。
    /// 只记长度，不记查询词与文件名。
    private func traceSearch(via: String, started: Date, count: Int, term: String) {
        Breadcrumbs.event("file.search", [
            "via": via,
            "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            "count": String(count),
            "termLen": String(term.count),
        ])
    }

    public func prewarmSpotlightAvailability() {
        guard spotlightAvailable != true, availabilityTask == nil else { return }
        // 「不能用」只留 30 秒：永久缓存会把一次冷探失败钉死整个进程的兜底，
        // 完全不缓存又会让真的关了索引的机器每次搜索都白等 1.5 秒探针。
        if let at = lastNegativeProbeAt, Date().timeIntervalSince(at) < Self.negativeProbeRetry {
            return
        }
        availabilityTask = Task { [weak self] in
            guard let self else { return false }
            let value = await self.probeSpotlight()
            if value {
                self.spotlightAvailable = true
            } else {
                self.lastNegativeProbeAt = Date()
            }
            self.availabilityTask = nil
            return value
        }
    }

    // MARK: 空查询：固定 + 最近

    private func browseHistory(_ request: FileSearchRequest) -> FileSearchResponse {
        let candidates = FileHistoryStore.shared.candidates()
        var items: [FileItem] = []
        for candidate in candidates {
            let item = FileItemFactory.make(url: candidate.url, origin: candidate.origin)
            guard request.category.matches(item) else { continue }
            items.append(item)
        }
        let notice = items.isEmpty
            ? L10n.Files.Notice.emptyQuery
            : nil
        return FileSearchResponse(items: items, total: items.count, isTruncated: false,
                                  notice: notice)
    }

    // MARK: 路径直达

    private func resolve(path: PathQuery, request: FileSearchRequest) -> FileSearchResponse {
        guard path.exists else {
            return FileSearchResponse(items: [], total: 0, isTruncated: false,
                                      notice: L10n.Files.Notice.missingPath(FilePathDisplay.abbreviated(path.url)))
        }
        let values = try? path.url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory ?? path.url.hasDirectoryPath

        if path.listsChildren, isDirectory {
            return listChildren(of: path.url, request: request)
        }

        let item = FileItemFactory.make(url: path.url, origin: .path)
        return FileSearchResponse(items: [item], total: 1, isTruncated: false)
    }

    private func listChildren(of directory: URL, request: FileSearchRequest) -> FileSearchResponse {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
            options: []
        ) else {
            return FileSearchResponse(items: [], total: 0, isTruncated: false,
                                      notice: L10n.Files.Notice.unreadableDir(FilePathDisplay.abbreviated(directory)))
        }
        var items = children.map { FileItemFactory.make(url: $0, origin: .path) }
            .filter(request.category.matches)
        items = sorted(items, by: request.sort, term: "")
        let total = items.count
        let limited = Array(items.prefix(request.limit))
        return FileSearchResponse(items: limited, total: total,
                                  isTruncated: total > limited.count)
    }

    // MARK: Spotlight

    private func searchSpotlight(term: String, request: FileSearchRequest) async -> FileSearchResponse {
        let entered = Date()
        HiddenFileIndex.shared.start()

        let hidden = HiddenFileIndex.shared.search(term: term, category: request.category)
        guard await isSpotlightAvailable() else {
            let limited = Array(hidden.prefix(request.limit))
            traceSearch(via: "spot-off", started: entered, count: limited.count, term: term)
            return FileSearchResponse(
                items: limited, total: hidden.count, isTruncated: hidden.count > limited.count,
                notice: L10n.Files.Notice.spotlightDisabled,
                isSpotlightAvailable: false)
        }

        let scopes: [Any]
        var scopeNotice: String?
        switch request.scope {
        case .mac:
            scopes = [NSMetadataQueryLocalComputerScope]
        case .folders:
            let roots = request.directories.isEmpty
                ? [FileManager.default.homeDirectoryForCurrentUser]
                : request.directories
            scopes = roots
            if request.directories.isEmpty {
                scopeNotice = L10n.Files.Notice.emptyFoldersFallback
            }
        }

        querySequence += 1
        let sequence = querySequence
        let started = Date()
        let result = await runQuery(predicate: makePredicate(term: term, category: request.category),
                                    scopes: scopes, sort: request.sort, limit: request.limit)
        if Task.isCancelled { return FileSearchResponse(items: [], total: 0, isTruncated: false) }

        debugLog(String(format: "file query#%ld term=%@ scope=%@ count=%ld spotlight=%.1fms",
                        sequence, term, request.scope.rawValue, result.total,
                        Date().timeIntervalSince(started) * 1000))
        traceSearch(via: result.timedOut ? "spotlight-timeout" : "spotlight",
                    started: entered, count: result.items.count, term: term)

        var items: [FileItem] = []
        var seen = Set<String>()
        for item in hidden where seen.insert(item.id).inserted { items.append(item) }
        let hiddenCount = items.count
        for item in result.items where seen.insert(item.id).inserted { items.append(item) }

        if request.sort == .relevance {
            // 隐藏文件是白名单命中，放在 Spotlight 结果前；其余保持 Spotlight 相关度顺序
        } else {
            items = sorted(items, by: request.sort, term: term)
        }

        let total = max(result.total, 0) + hiddenCount
        let limited = Array(items.prefix(request.limit))
        let notice = result.timedOut ? L10n.Files.Notice.spotlightTimeout : scopeNotice
        return FileSearchResponse(items: limited, total: total,
                                  isTruncated: total > limited.count,
                                  notice: notice, isSpotlightAvailable: true)
    }

    private struct QueryResult {
        let items: [FileItem]
        let total: Int
        let timedOut: Bool
    }

    private func runQuery(predicate: NSPredicate, scopes: [Any], sort: FileSort,
                          limit: Int) async -> QueryResult {
        activeQuery?.stop()

        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = sortDescriptors(for: sort)
        query.notificationBatchingInterval = 0.05
        activeQuery = query
        query.start()

        let deadline = ContinuousClock.now + .seconds(4)
        while query.isGathering && ContinuousClock.now < deadline {
            if Task.isCancelled {
                query.stop()
                if activeQuery === query { activeQuery = nil }
                return QueryResult(items: [], total: 0, timedOut: false)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }

        let timedOut = query.isGathering
        let total = query.resultCount
        let count = min(total, limit)
        var items: [FileItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let metadata = query.result(at: index) as? NSMetadataItem,
                  let item = makeItem(metadata) else { continue }
            items.append(item)
        }
        query.stop()
        if activeQuery === query { activeQuery = nil }
        return QueryResult(items: items, total: total, timedOut: timedOut)
    }

    private func makePredicate(term: String, category: FileCategory) -> NSPredicate {
        let name = NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: "kMDItemFSName"),
            rightExpression: NSExpression(forConstantValue: term),
            modifier: .direct, type: .contains,
            options: [.caseInsensitive, .diacriticInsensitive])

        guard category != .all else { return name }

        if category == .folder {
            let folder = NSComparisonPredicate(
                leftExpression: NSExpression(forKeyPath: "kMDItemContentTypeTree"),
                rightExpression: NSExpression(forConstantValue: "public.folder"),
                modifier: .any, type: .equalTo, options: [])
            return NSCompoundPredicate(andPredicateWithSubpredicates: [name, folder])
        }

        var typePredicates: [NSPredicate] = category.contentTypeTree.map { identifier in
            NSComparisonPredicate(
                leftExpression: NSExpression(forKeyPath: "kMDItemContentTypeTree"),
                rightExpression: NSExpression(forConstantValue: identifier),
                modifier: .any, type: .equalTo, options: [])
        }
        typePredicates += category.fileExtensions.map { ext in
            NSComparisonPredicate(
                leftExpression: NSExpression(forKeyPath: "kMDItemFSName"),
                rightExpression: NSExpression(forConstantValue: "." + ext),
                modifier: .direct, type: .endsWith,
                options: [.caseInsensitive])
        }
        let categoryPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: typePredicates)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [name, categoryPredicate])
    }

    private func sortDescriptors(for sort: FileSort) -> [NSSortDescriptor] {
        switch sort {
        case .relevance:
            return []
        case .modified:
            return [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)]
        case .created:
            return [NSSortDescriptor(key: "kMDItemFSCreationDate", ascending: false)]
        case .name:
            return [NSSortDescriptor(key: "kMDItemFSName", ascending: true)]
        case .size:
            return [NSSortDescriptor(key: "kMDItemFSSize", ascending: false)]
        }
    }

    private func sorted(_ items: [FileItem], by sort: FileSort, term: String) -> [FileItem] {
        switch sort {
        case .relevance:
            return items.sorted {
                let l = Self.relevance($0, term: term)
                let r = Self.relevance($1, term: term)
                return l == r ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : l > r
            }
        case .modified:
            return items.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .created:
            return items.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .name:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return items.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        }
    }

    private static func relevance(_ item: FileItem, term: String) -> Int {
        guard !term.isEmpty else { return 0 }
        if item.name.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return 100
        }
        if item.name.lowercased().hasPrefix(term.lowercased()) { return 80 }
        return 60
    }

    private func makeItem(_ metadata: NSMetadataItem) -> FileItem? {
        guard let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let tree = metadata.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        let isDirectory = tree.contains("public.folder")
            || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

        var isUbiquitous = (metadata.value(forAttribute: NSMetadataItemIsUbiquitousKey) as? Bool) ?? false
        var downloaded = true
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                          .ubiquitousItemDownloadingStatusKey]) {
            isUbiquitous = values.isUbiquitousItem ?? isUbiquitous
            let status = values.ubiquitousItemDownloadingStatus
            downloaded = status == .current || status == .downloaded
        }

        return FileItem(
            url: url,
            isDirectory: isDirectory,
            contentType: metadata.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
            contentTypeTree: tree,
            creationDate: metadata.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
            modificationDate: metadata.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            lastUsedDate: metadata.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date,
            fileSize: (metadata.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            isUbiquitous: isUbiquitous,
            isDownloaded: downloaded,
            origin: .spotlight)
    }

    // MARK: Spotlight 可用性

    private func isSpotlightAvailable() async -> Bool {
        if spotlightAvailable == true { return true }
        if let availabilityTask { return await availabilityTask.value }
        prewarmSpotlightAvailability()
        return await availabilityTask?.value ?? false
    }

    /// Spotlight 能力探针：问"全盘有没有一个叫 `Applications` 的条目"。
    /// 不能把 scope 设成 `/Applications` 再问同一个名字——scope 不含它自己，而全盘唯一
    /// 叫这名的就是 `/Applications` 本身，那样写恒为 0 命中，兜底路径于是每次都误报
    /// "Spotlight 未启用"（2026-11-06 实测：旧写法 0 条，整盘 scope 2 条，负对照 0 条）。
    private func probeSpotlight() async -> Bool {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemFSName == %@", "Applications")
        query.searchScopes = [URL(fileURLWithPath: "/")]
        query.start()
        let deadline = ContinuousClock.now + .seconds(1.5)
        while query.isGathering && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let available = query.resultCount > 0
        query.stop()
        return available
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil else { return }
        log.info("\(message, privacy: .public)")
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        #endif
    }
}
