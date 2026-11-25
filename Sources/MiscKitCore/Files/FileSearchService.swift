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
    /// 路径直达失败后的回退：只搜完整路径，不搜文件名。
    public var pathSearch: Bool

    public init(text: String, category: FileCategory = .all, scope: FileScope = .mac,
                directories: [URL] = [], sort: FileSort = .relevance, limit: Int = 80,
                pathSearch: Bool = false) {
        self.text = text
        self.category = category
        self.scope = scope
        self.directories = directories
        self.sort = sort
        self.limit = limit
        self.pathSearch = pathSearch
    }
}

/// Spotlight 查询封装：一次查询在驻留查询结束时取回，取消时停掉在途查询。
@MainActor
public final class FileSearchService {
    public static let shared = FileSearchService()

    private var activeQuery: NSMetadataQuery?
    /// 冷启动按目录扇出时的多个查询；新搜索开始时一并停掉。
    private var scopedColdQueries: [NSMetadataQuery] = []
    /// 只写 `true`：探针的"能用"是稳定结论，"不能用"可能只是 Spotlight 还没热，见 `prewarmSpotlightAvailability`。
    private var spotlightAvailable: Bool?
    private var lastNegativeProbeAt: Date?
    private var availabilityTask: Task<Bool, Never>?
    private var querySequence = 0
    /// 只用于中断在途 body/count：有新的输入/分类切换时，旧结果本来就会被 token 丢掉，
    /// 这里再把 SQLite 里的旧查询停掉，避免它们排队挡住新查询。
    private var bodyQueryToken = 0
    private var bodyQueryActive = false
    private var countQueryToken = 0
    private var countQueryActive = false
    private static let negativeProbeRetry: TimeInterval = 30
    private let log = Logger(subsystem: "app.misckit.launcher", category: "filesearch")

    private init() {}

    public func search(_ request: FileSearchRequest) async -> FileSearchResponse {
        // 正则不是 SQL 能表达的东西，必须走索引的精筛通道；索引没就绪时如实说明。
        if FileSearchSyntax.parse(request.text).regex != nil {
            guard FileIndex.shared.isReady else {
                return FileSearchResponse(items: [], total: 0, isTruncated: false,
                                          notice: L10n.Files.Notice.regexUnavailable)
            }
            FileIndex.shared.prepareForSearch()
            if let indexed = await searchIndex(term: request.text, request: request) {
                return indexed
            }
        }

        let parser = FileQueryParser(aliases: FileAliasStore.shared.aliases)
        switch parser.parse(request.text) {
        case .none:
            return FileSearchResponse(items: [], total: 0, isTruncated: false)
        case .browse:
            return browseHistory(request)
        case .path(let path):
            // 路径不存在时不再只给一句“找不到”：`src/main` 这类半截路径改走索引的路径段搜索。
            if !path.exists, let body = parser.searchTerm(request.text),
               body.contains("/") || body.hasPrefix("~") {
                var fallback = request
                fallback.pathSearch = true
                if FileIndex.shared.isReady,
                   let indexed = await searchIndex(term: body, request: fallback),
                   !indexed.items.isEmpty {
                    return indexed
                }
            }
            return resolve(path: path, request: request)
        case .search(let term):
            // 索引就绪时只走 SQLite；未就绪时让 Spotlight 和索引并行，谁先有非空结果谁先上屏。
            if !FileIndex.shared.isReady {
                return await coldStartSearch(term: term, request: request)
            }
            FileIndex.shared.prepareForSearch()
            if let indexed = await searchIndex(term: term, request: request) {
                return indexed
            }
            return await searchSpotlight(term: term, request: request)
        }
    }

    /// 索引未就绪：Spotlight 立刻开跑，同时等索引打开。谁先给出非空结果谁上屏；
    /// 索引落后时先返回 Spotlight，之后 FileSearchModel.observeIndexPhase 会在索引 ready
    /// 后用索引结果覆盖。两边都空时最多等 1.2s，和原来的兜底等待一致。
    private func coldStartSearch(term: String, request: FileSearchRequest) async -> FileSearchResponse {
        let entered = Date()
        var spotlight: FileSearchResponse?
        let spotlightTask = Task { @MainActor [self] in
            let response = await searchSpotlight(term: term, request: request, earlyResultCount: 1)
            spotlight = response
            return response
        }
        // 先把 Spotlight 任务排上，再开索引：索引 open/count 会占主线程一小段时间，
        // 反过来先开索引会让首条白白晚上几十毫秒。给 Spotlight 一个 60ms 的抢跑窗口，
        // 但最多只延后 60ms，索引仍能在 1.2s 兜底前 ready。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            FileIndex.shared.prepareForSearch()
        }
        let deadline = ContinuousClock.now + .milliseconds(1200)
        var triedIndex = false

        while ContinuousClock.now < deadline {
            if let spotlight, !spotlight.items.isEmpty {
                traceColdRace(winner: "spotlight", started: entered, term: term)
                return spotlight
            }
            if FileIndex.shared.isReady, !triedIndex {
                triedIndex = true
                if let indexed = await searchIndex(term: term, request: request) {
                    spotlightTask.cancel()
                    traceColdRace(winner: "index", started: entered, term: term)
                    return indexed
                }
                // 索引查询失败时不要把 Spotlight 一起取消：它仍可能给出可用结果。
            }
            // 只有 idle/opening/ready 还有“马上就好”的可能；building/failed/disabled 不该再等。
            switch FileIndex.shared.phase {
            case .idle, .opening, .ready:
                break
            case .building, .disabled, .failed:
                var spotlightResult: FileSearchResponse?
                if let spotlight { spotlightResult = spotlight }
                spotlightTask.cancel()
                if let spotlightResult { return spotlightResult }
                return await spotlightTask.value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        spotlightTask.cancel()
        if FileIndex.shared.isReady, !triedIndex,
           let indexed = await searchIndex(term: term, request: request) {
            traceColdRace(winner: "index", started: entered, term: term)
            return indexed
        }
        if let spotlight {
            traceColdRace(winner: "spotlight-empty", started: entered, term: term)
            return spotlight
        }
        let empty = await spotlightTask.value
        traceColdRace(winner: "empty", started: entered, term: term)
        return empty
    }

    private func traceColdRace(winner: String, started: Date, term: String) {
        Breadcrumbs.event("file.search.cold", [
            "winner": winner,
            "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            "termLen": String(term.count),
        ])
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

    // MARK: 分段查询

    /// 快段：只查等值 + 前缀，先让第一屏有内容。索引没就绪时返回 nil，
    /// 由 `search()` 继续走原来的等待/Spotlight 兜底。
    public func searchFast(_ request: FileSearchRequest) async -> FileSearchResponse? {
        await searchIndexPhase(request, phase: .fast)
    }

    /// 补全段：把包含段加到快段后面。
    public func searchBody(_ request: FileSearchRequest) async -> FileSearchResponse? {
        await searchIndexPhase(request, phase: .body)
    }

    /// 计数段：只返回 total / totalIsExact，items 为空。
    public func searchCount(_ request: FileSearchRequest) async -> FileSearchResponse? {
        await searchIndexPhase(request, phase: .count)
    }

    /// 调度层开始新查询时调用。只在确有 body/count 在途时才向连接发 interrupt；
    /// 没有在途查询时保持 no-op，避免把中断标志留给下一条 SQL。
    public func cancelPendingQueries() {
        if bodyQueryActive { FileIndex.shared.interruptBodyQuery() }
        if countQueryActive { FileIndex.shared.interruptCountQuery() }
    }

    private func searchIndexPhase(_ request: FileSearchRequest,
                                  phase: FileIndexQueryPhase) async -> FileSearchResponse? {
        let parser = FileQueryParser(aliases: FileAliasStore.shared.aliases)
        guard case .search(let term) = parser.parse(request.text),
              FileSearchSyntax.parse(term).regex == nil,
              FileIndex.shared.isReady else { return nil }
        let bodyToken = phase == .body ? beginBodyQuery() : nil
        let countToken = phase == .count ? beginCountQuery() : nil
        defer {
            if let bodyToken { endBodyQuery(bodyToken) }
            if let countToken { endCountQuery(countToken) }
        }
        let started = Date()
        do {
            let response: FileSearchResponse
            switch phase {
            case .fast:
                response = try await FileIndex.shared.searchFast(term: term, request: request)
            case .body:
                response = try await FileIndex.shared.searchBody(term: term, request: request)
            case .count:
                response = try await FileIndex.shared.searchCount(term: term, request: request)
            case .complete:
                response = try await FileIndex.shared.search(term: term, request: request)
            }
            let via = "index-\(phase)"
            debugLog(String(format: "%@ term=%@ count=%ld total=%ld %.1fms",
                            via, term, response.items.count, response.total,
                            Date().timeIntervalSince(started) * 1000))
            traceSearch(via: via, started: started, count: response.items.count, term: term)
            return response
        } catch {
            log.error("\(String(describing: phase)) query failed: \(error.localizedDescription, privacy: .public)")
            traceSearch(via: "index-\(phase)-error", started: started, count: 0, term: term)
            return nil
        }
    }

    /// 每次 body/count 拿一个序号；旧查询的 defer 不能把新查询的 active 状态清掉。
    private func beginBodyQuery() -> Int {
        bodyQueryToken += 1
        bodyQueryActive = true
        return bodyQueryToken
    }

    private func endBodyQuery(_ token: Int) {
        guard bodyQueryToken == token else { return }
        bodyQueryActive = false
    }

    private func beginCountQuery() -> Int {
        countQueryToken += 1
        countQueryActive = true
        return countQueryToken
    }

    private func endCountQuery(_ token: Int) {
        guard countQueryToken == token else { return }
        countQueryActive = false
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

    private func searchSpotlight(term: String, request: FileSearchRequest,
                                 earlyResultCount: Int = 0) async -> FileSearchResponse {
        let entered = Date()
        let hidden: [FileItem]
        if earlyResultCount > 0 {
            // 冷启动首屏先让 Spotlight 跑起来；dotfiles 扫描是同步的，放到索引 ready 后的
            // 常规查询里再做，否则会把这 50ms 的首条窗口白白吃掉。
            hidden = []
        } else {
            HiddenFileIndex.shared.start()
            hidden = HiddenFileIndex.shared.search(term: term, category: request.category)
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
                                    scopes: scopes, sort: request.sort, limit: request.limit,
                                    earlyResultCount: earlyResultCount)
        if Task.isCancelled { return FileSearchResponse(items: [], total: 0, isTruncated: false) }

        // 冷启动时 Spotlight 能力探针可能比查询本身还慢；先看查询有没有命中，
        // 只有 0 命中时才需要探针区分“没结果”和“Spotlight 被关掉”。
        let spotlightAvailable = result.total > 0 ? true : await isSpotlightAvailable()
        if !spotlightAvailable {
            let limited = Array(hidden.prefix(request.limit))
            traceSearch(via: "spot-off", started: entered, count: limited.count, term: term)
            return FileSearchResponse(
                items: limited, total: hidden.count, isTruncated: hidden.count > limited.count,
                notice: L10n.Files.Notice.spotlightDisabled,
                isSpotlightAvailable: false)
        }

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
                                  isTruncated: result.partial || total > limited.count,
                                  totalIsExact: !result.partial && total <= limited.count,
                                  notice: notice, isSpotlightAvailable: true)
    }

    private struct QueryResult {
        let items: [FileItem]
        let total: Int
        let timedOut: Bool
        var partial = false
    }

    private func runQuery(predicate: NSPredicate, scopes: [Any], sort: FileSort,
                          limit: Int, earlyResultCount: Int = 0) async -> QueryResult {
        activeQuery?.stop()
        stopScopedColdQueries()
        if earlyResultCount > 0, scopes.count > 1 {
            return await runScopedQueries(predicate: predicate, scopes: scopes, limit: limit)
        }

        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        // 冷启动预览不要带 sortDescriptors：按修改时间排序会逼 Spotlight 先收齐元数据，
        // 首条从 ~60ms 掉到 200ms+。先拿一批结果，回来按本地字段排一次，索引 ready 后再精确替换。
        query.sortDescriptors = earlyResultCount > 0 ? [] : sortDescriptors(for: sort)
        query.notificationBatchingInterval = 0.05
        activeQuery = query
        query.start()

        let deadline = ContinuousClock.now + .seconds(4)
        // 冷启动只等第一批结果：NSMetadataQuery 在 gathering 期间就已经能取到结果，
        // 等它彻底收完反而要多花几百毫秒。partial 会让 footer 显示 "+"，索引 ready 后覆盖。
        while query.isGathering && ContinuousClock.now < deadline {
            if Task.isCancelled {
                query.stop()
                if activeQuery === query { activeQuery = nil }
                return QueryResult(items: [], total: 0, timedOut: false)
            }
            if earlyResultCount > 0, query.resultCount >= earlyResultCount {
                let snapshot = snapshot(query, limit: limit, preview: true)
                query.stop()
                if activeQuery === query { activeQuery = nil }
                return QueryResult(items: snapshot.items, total: snapshot.total,
                                   timedOut: false, partial: true)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }

        let timedOut = query.isGathering
        let snapshot = snapshot(query, limit: limit)
        query.stop()
        if activeQuery === query { activeQuery = nil }
        return QueryResult(items: snapshot.items, total: snapshot.total, timedOut: timedOut)
    }

    private func snapshot(_ query: NSMetadataQuery, limit: Int,
                          preview: Bool = false) -> (items: [FileItem], total: Int) {
        let total = query.resultCount
        let count = min(total, limit)
        var items: [FileItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let metadata = query.result(at: index) as? NSMetadataItem else { continue }
            let item = preview ? makePreviewItem(metadata) : makeItem(metadata)
            if let item { items.append(item) }
        }
        return (items, total)
    }

    /// 多个 folders 根目录时逐个开查询，而不是一个 query 带 3 个 scope：
    /// Spotlight 对多 scope 的首条要等各目录都回话；单目录 Desktop 约 50ms 就有结果，
    /// 翼支付约 50ms，Downloads 约 100ms。谁先回非空就先上屏，其余取消。
    /// NSMetadataQuery 的 scope 是 `Any`（URL 或 LocalComputerScope 常量），本身不可变；
    /// 用这个盒子只为了跨 task 边界时不触发 Swift 6 的 Sendable 检查。
    private struct ScopeBox: @unchecked Sendable {
        let value: Any
    }

    private struct QuerySpec: @unchecked Sendable {
        let predicate: NSPredicate
        let limit: Int
    }

    private func runScopedQueries(predicate: NSPredicate, scopes: [Any], limit: Int) async -> QueryResult {
        let boxes = scopes.map(ScopeBox.init(value:))
        let spec = QuerySpec(predicate: predicate, limit: limit)
        return await withTaskGroup(of: QueryResult.self) { group in
            for box in boxes {
                group.addTask { [weak self, spec] in
                    guard let self else { return QueryResult(items: [], total: 0, timedOut: false) }
                    return await self.runSingleScopedQuery(spec: spec, scope: box.value)
                }
            }
            var firstNonEmpty: QueryResult?
            for await result in group {
                if result.total > 0 {
                    firstNonEmpty = result
                    group.cancelAll()
                    break
                }
            }
            return firstNonEmpty ?? QueryResult(items: [], total: 0, timedOut: false)
        }
    }

    private func runSingleScopedQuery(spec: QuerySpec, scope: Any) async -> QueryResult {
        let query = NSMetadataQuery()
        query.predicate = spec.predicate
        query.searchScopes = [scope]
        query.notificationBatchingInterval = 0.02
        scopedColdQueries.append(query)
        defer {
            query.stop()
            scopedColdQueries.removeAll { $0 === query }
        }
        query.start()

        let deadline = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                return QueryResult(items: [], total: 0, timedOut: false)
            }
            if query.resultCount > 0 {
                let snapshot = snapshot(query, limit: spec.limit, preview: true)
                return QueryResult(items: snapshot.items, total: snapshot.total,
                                   timedOut: false, partial: true)
            }
            if !query.isGathering { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = snapshot(query, limit: spec.limit, preview: true)
        return QueryResult(items: snapshot.items, total: snapshot.total,
                           timedOut: false, partial: true)
    }

    private func stopScopedColdQueries() {
        for query in scopedColdQueries { query.stop() }
        scopedColdQueries.removeAll()
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

    /// 冷启动首屏只读 Spotlight 已经给的元数据：`makeItem` 里的 resourceValues
    /// 会逐条碰磁盘，15 条也能吃掉几十毫秒。索引 ready 后会被完整结果替换。
    private func makePreviewItem(_ metadata: NSMetadataItem) -> FileItem? {
        guard let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let tree = metadata.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        return FileItem(
            url: URL(fileURLWithPath: path),
            isDirectory: tree.contains("public.folder"),
            contentType: metadata.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
            contentTypeTree: tree,
            creationDate: metadata.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
            modificationDate: metadata.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            lastUsedDate: metadata.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date,
            fileSize: (metadata.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            isUbiquitous: (metadata.value(forAttribute: NSMetadataItemIsUbiquitousKey) as? Bool) ?? false,
            isDownloaded: true,
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
