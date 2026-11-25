import CoreServices
import Foundation
import Observation
import os

/// 持久化文件索引：首次全量扫描，之后用 FSEvents 做文件级增量更新。
/// Spotlight 只在扫描完成前兜底；索引就绪后查询全部走 SQLite。
@MainActor
@Observable
public final class FileIndex {
    public static let shared = FileIndex()

    public enum Phase: Equatable, Sendable {
        case idle
        case opening
        case building
        case ready
        case disabled
        case failed(String)
    }

    /// 状态每次变化都留一条：这次"索引自己把自己踢下线"查了两小时，就是因为没有轨迹。
    public private(set) var phase: Phase = .idle {
        didSet {
            guard oldValue != phase else { return }
            Breadcrumbs.event("file.phase", [
                "from": String(describing: oldValue),
                "to": String(describing: phase),
                "rows": String(indexedCount),
            ])
        }
    }
    public private(set) var indexedCount = 0
    public private(set) var scannedCount = 0
    public private(set) var currentPath: String?
    public private(set) var lastError: String?
    /// FTS 是否可用：读写四条连接必须看同一个事实，所以由这里统一持有。
    /// 重建/整库交换期间为假，包含段回退到 `instr`（慢但结果对）。
    public private(set) var isFTSReady = false

    @ObservationIgnored private let database: FileIndexDatabase
    /// 查询专用连接：与写连接分离，增量更新/子树重扫再忙也不会把按键的查询堵在后面。
    @ObservationIgnored private let reader: FileIndexDatabase
    /// 补全段与计数段各自一条只读连接：包含段（最长 45ms）和计数（最长 189ms）
    /// 都不能排在快段后面，否则“先出结果”只是把等待挪了个位置。
    @ObservationIgnored private let bodyReader: FileIndexDatabase
    @ObservationIgnored private let countReader: FileIndexDatabase
    @ObservationIgnored private let databaseURL: URL
    @ObservationIgnored private let overrideRoots: [URL]
    @ObservationIgnored private let isDisabled: Bool
    @ObservationIgnored private let log = Logger(subsystem: "app.misckit.launcher",
                                                  category: "fileindex")
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var rootWatchTask: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var eventStream: FileIndexEventStream?
    @ObservationIgnored private var pendingEvents: [FileIndexEvent] = []
    @ObservationIgnored private var pendingBuckets: Set<String> = []
    @ObservationIgnored private var forcedRescans: Set<String> = []
    @ObservationIgnored private var deferredDeletions: Set<String> = []
    @ObservationIgnored private var activeRoots: [URL] = []
    @ObservationIgnored private var rebuildRequested = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var isRebuilding = false
    @ObservationIgnored private var observingRoots = false
    @ObservationIgnored private var readerFailed = false
    @ObservationIgnored private var bodyReaderFailed = false
    @ObservationIgnored private var countReaderFailed = false
    @ObservationIgnored private var ftsTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var lastQueryAt: ContinuousClock.Instant?

    private init() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        isDisabled = env["MISCKIT_DEBUG_NO_FILE_INDEX"] == "1"
        overrideRoots = Self.parseRoots(env["MISCKIT_FILE_INDEX_ROOTS"])
        if let raw = env["MISCKIT_FILE_INDEX_DB"], !raw.isEmpty {
            databaseURL = URL(fileURLWithPath: raw)
        } else {
            databaseURL = AppStoragePaths.file("index.sqlite3")
        }
        #else
        isDisabled = false
        overrideRoots = []
        databaseURL = AppStoragePaths.file("index.sqlite3")
        #endif
        database = FileIndexDatabase(url: databaseURL)
        reader = FileIndexDatabase(url: databaseURL, readOnly: true)
        bodyReader = FileIndexDatabase(url: databaseURL, readOnly: true, cacheSizeKB: 16 * 1024)
        countReader = FileIndexDatabase(url: databaseURL, readOnly: true, cacheSizeKB: 8 * 1024)
    }

    // MARK: 状态

    public var isReady: Bool { phase == .ready }

    /// 空查询说明不需要任何搜索结果，这里只覆盖“索引本身”的状态提示。
    public var statusNotice: String? {
        switch phase {
        case .building:
            let formatted = Self.countFormatter.string(from: NSNumber(value: scannedCount))
                ?? String(scannedCount)
            return L10n.Files.Index.building(formatted)
        case .opening:
            return L10n.Files.Index.opening
        case .failed:
            return L10n.Files.Index.unavailable
        case .idle, .ready, .disabled:
            return nil
        }
    }

    // MARK: 启动

    public func start() {
        guard !isDisabled else {
            phase = .disabled
            return
        }
        guard startTask == nil, phase == .idle else { return }
        observeRootsIfNeeded()
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            await self.prepare()
        }
    }

    /// 每次进入文件搜索时调用：首次启动索引；失败后允许重新打开一次。
    public func prepareForSearch() {
        if case .failed = phase, startTask == nil {
            phase = .idle
        }
        start()
    }

    /// 冷启动的第一次搜索几乎必然撞上 `.idle`/`.opening`——这时候掉到兜底路径，
    /// 用户看到的是"索引不可用"的假降级。实测打开 + 计数 4.9ms（56.6 万行），等一拍就够。
    /// 只等这两态：`.building` / `.failed` / `.disabled` 是"现在确实没有可用索引"，不浪费时间。
    public func waitForReady(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while (phase == .idle || phase == .opening), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isReady
    }

    /// 调用方自己动过磁盘（移进废纸篓）之后，立刻把这些路径从索引里摘掉，目录连子树一起。
    /// 不能等 FSEvents：事件流带 `kFSEventStreamCreateFlagIgnoreSelf`，本进程自己造成的
    /// 改动不会回调给自己——不摘的话，旧行会一直留在表里，下一次搜索又"复活"。
    /// 后台重扫期间先记着，等交换完成再摘，否则暂存表里的旧快照会把它带回来。
    public func forget(_ urls: [URL]) async {
        guard phase == .ready, !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        if isRebuilding { deferredDeletions.formUnion(paths) }
        do {
            try await database.apply(upserts: [], deleting: paths, maintainFTS: isFTSReady)
            indexedCount = try await database.count()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func prepare() async {
        #if DEBUG
        let force = ProcessInfo.processInfo.environment["MISCKIT_FILE_INDEX_FORCE_REBUILD"] == "1"
        #else
        let force = false
        #endif
        phase = .opening
        do {
            try await database.open()
            let roots = currentRoots()
            activeRoots = roots
            let signature = FileIndexRoots.signature(roots)
            let entries = try await database.count()
            let completed = try await database.meta(FileIndexMetaKey.completedAt)
            let savedSignature = try await database.meta(FileIndexMetaKey.rootsSignature)
            let savedPolicy = try await database.meta(FileIndexMetaKey.policyVersion)
            let usable = !force && entries > 0 && completed != nil
                && savedSignature == signature
                && savedPolicy == String(FileIndexPolicy.version)

            if usable {
                indexedCount = entries
                scannedCount = entries
                phase = .ready
                isFTSReady = try await database.meta(FileIndexMetaKey.ftsReady) == "1"
                if isFTSReady, try await database.ftsRowCount() != entries {
                    // 行数对不上说明有事务外写入或上次重建被打断，重建一遍再开。
                    isFTSReady = false
                }
                if !isFTSReady { scheduleFTSRebuild() }
                scheduleMaintenance()
                let saved = try await database.meta(FileIndexMetaKey.lastEventID).flatMap(UInt64.init)
                startEvents(since: saved ?? FSEventsGetCurrentEventId())
                debugLog("index ready entries=\(entries) roots=\(roots.count)")
                let interrupted = try await database.meta(FileIndexMetaKey.rebuilding) != nil
                let savedRows = try await database.meta(FileIndexMetaKey.rowCount).flatMap(Int.init)
                // 上次重扫被杀（装新版/崩溃），或者库里有个补不回来的洞：旧索引照常服务，
                // 重扫在背后补完。
                if interrupted || Self.suspectsHole(now: entries, atCompletion: savedRows) {
                    debugLog("background rebuild interrupted=\(interrupted) "
                             + "rows=\(entries) atCompletion=\(savedRows.map(String.init) ?? "nil")")
                    scheduleFullScan(roots: roots, keepServing: true)
                }
            } else {
                await runFullScan(roots: roots, keepServing: false)
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            fail(error)
        }
    }

    // MARK: 全量扫描

    /// `keepServing` 为真时正式表继续对外服务，重扫只写暂存表，成功那一刻才交换。
    private func scheduleFullScan(roots: [URL], keepServing: Bool) {
        Task { [weak self] in
            await self?.runFullScan(roots: roots, keepServing: keepServing)
        }
    }

    private func runFullScan(roots: [URL], keepServing: Bool) async {
        guard !roots.isEmpty else {
            fail(FileIndexError.open(L10n.Files.Index.noDirectories))
            return
        }
        guard !isRebuilding else {
            rebuildRequested = true
            return
        }
        // FTS 重建占着写连接且按 id 区间扫表；等它收工再换整库，避免把增量写丢。
        if let ftsTask {
            await ftsTask.value
            self.ftsTask = nil
        }
        isRebuilding = true
        defer { isRebuilding = false }
        var pendingRoots = roots
        while !pendingRoots.isEmpty {
            pendingRoots = await performFullScan(roots: pendingRoots, keepServing: keepServing)
        }
    }

    /// 一趟暂存重扫；返回还需要再扫一遍的根（扫期间根目录变了），空数组表示收工。
    private func performFullScan(roots: [URL], keepServing: Bool) async -> [URL] {
        if !keepServing {
            phase = .building
            scannedCount = 0
            currentPath = nil
            indexedCount = 0
        }
        lastError = nil
        activeRoots = roots

        let scanStartEventID = FSEventsGetCurrentEventId()
        startEvents(since: scanStartEventID)

        do {
            try await database.beginStaging()
            try await database.setMeta(FileIndexMetaKey.rebuilding,
                                       value: String(Date().timeIntervalSince1970))

            let result = try await FileIndexScanner.scan(
                roots: roots, into: database, policy: makePolicy(), staging: true,
                // 背后补扫要把磁盘和 CPU 的抢占摊开：每批之间让一下，
                // 一次 37.8 万行大约多花 2 秒，换来期间点击不排队。
                batchPause: keepServing ? .milliseconds(8) : .zero
            ) { [weak self] progress in
                await self?.record(progress)
            }

            let stagedRows = try await database.stagedCount()
            // 索引先在暂存表上建好（这 0.6 秒正式表照常供查询），交换事务只剩改名
            try await database.buildStagingIndexes()
            try await database.publishStaging(meta: [
                (FileIndexMetaKey.rootsSignature, FileIndexRoots.signature(roots)),
                (FileIndexMetaKey.policyVersion, String(FileIndexPolicy.version)),
                (FileIndexMetaKey.completedAt, String(Date().timeIntervalSince1970)),
                (FileIndexMetaKey.lastEventID, String(scanStartEventID)),
                (FileIndexMetaKey.rowCount, String(stagedRows)),
                (FileIndexMetaKey.rebuilding, nil),
            ])
            indexedCount = try await database.count()
            scannedCount = result.inserted
            currentPath = nil
            // 整库交换已经把 FTS 清空，后台补建；补建期间包含段回退 instr。
            isFTSReady = false
            if !keepServing { phase = .ready }
            scheduleFTSRebuild()
            scheduleMaintenance()
            debugLog("full scan done entries=\(indexedCount) inserted=\(result.inserted) "
                     + "unreadable=\(result.unreadable) serving=\(keepServing)")

            if rebuildRequested {
                rebuildRequested = false
                return currentRoots()
            }
            if !pendingEvents.isEmpty || !forcedRescans.isEmpty || !deferredDeletions.isEmpty {
                scheduleApply(delay: .milliseconds(60))
            }
            return []
        } catch is CancellationError {
            try? await database.discardStaging()
            if !keepServing { phase = .idle }
            return []
        } catch {
            try? await database.discardStaging()
            if keepServing {
                lastError = error.localizedDescription
                log.error("background rebuild failed: \(error.localizedDescription, privacy: .public)")
            } else {
                fail(error)
            }
            return []
        }
    }

    private func record(_ progress: FileIndexScanProgress) {
        guard phase == .building else { return }
        scannedCount = progress.inserted
        currentPath = progress.currentPath
    }

    // MARK: 增量更新

    private func startEvents(since eventID: FSEventStreamEventId) {
        stopEvents()
        let paths = activeRoots.map(\.path)
        guard !paths.isEmpty else { return }
        // 过滤和归并都是每个路径构造一次 URL，别放在主线程上——那会让一次点击排在几千个事件后面。
        let filter = FileIndexEventFilter(roots: activeRoots, policy: makePolicy())
        let stream = FileIndexEventStream(paths: paths, since: eventID) { [weak self] events in
            let batch = filter.process(events)
            Task { @MainActor in self?.ingest(batch.kept, buckets: batch.buckets) }
        }
        if let stream {
            eventStream = stream
        } else {
            log.error("FSEvents stream failed to start")
        }
    }

    private func stopEvents() {
        eventStream = nil
    }

    private func ingest(_ events: [FileIndexEvent], buckets: Set<String>) {
        guard !isDisabled, !events.isEmpty else { return }
        if case .failed = phase { return }
        pendingEvents.append(contentsOf: events)
        pendingBuckets.formUnion(buckets)
        if pendingEvents.count > Self.pendingEventLimit {
            spillPendingEvents()
        }
        guard phase == .ready, !isRebuilding else { return }
        scheduleApply()
    }

    /// 事件积压到追不动的程度：整批折成「根下第一层目录整体重扫」，不把整库推倒。
    private func spillPendingEvents() {
        pendingEvents.removeAll(keepingCapacity: true)
        forcedRescans.formUnion(pendingBuckets)
        pendingBuckets.removeAll(keepingCapacity: true)
        debugLog("overflow → \(forcedRescans.count) buckets: "
                 + forcedRescans.sorted().prefix(6).joined(separator: " | "))
    }

    /// 事件和它们的目录桶成对进出，别让两个队列走岔。
    private func takePendingEvents() -> [FileIndexEvent] {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        pendingBuckets.removeAll(keepingCapacity: true)
        return events
    }

    /// 一次消化这么多目录桶，剩下的退回队列：先扫路径短的（通常是更大的树）。
    nonisolated static func splitRescans(_ rescans: Set<String>,
                                         limit: Int) -> (take: Set<String>, rest: Set<String>) {
        guard rescans.count > limit else { return (rescans, []) }
        let sorted = rescans.sorted { $0.count < $1.count }
        return (Set(sorted.prefix(limit)), Set(sorted.dropFirst(limit)))
    }

    /// 事件路径所属根目录下的第一层子目录；路径不在任何根内时返回 nil。
    nonisolated static func bucket(of path: String, roots: [URL]) -> String? {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        var matched: String?
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard clean == rootPath || clean.hasPrefix(rootPath + "/") else { continue }
            if matched == nil || rootPath.count > matched!.count { matched = rootPath }
        }
        guard let root = matched else { return nil }
        let rest = clean.dropFirst(root.count)
        guard rest.hasPrefix("/"), rest.count > 1 else { return root }
        let first = rest.dropFirst().split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? root : root + "/" + first
    }

    private func scheduleApply(delay: Duration = .milliseconds(700)) {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.applyPending()
        }
    }

    private func applyPending() async {
        guard phase == .ready, !isApplying, !isRebuilding else { return }
        // FTS 重建和增量写入共用写连接，且重建按 id 区间扫表；
        // 这时插进来的增量会被跳过，等重建收工再排空队列。
        guard ftsTask == nil else {
            scheduleApply(delay: .seconds(1))
            return
        }
        // 已经在服务（SQLite 里有可用行）时，任何重建都只走背后，不打断搜索；
        // 只有从未就绪过的冷启才让界面显示"正在建立文件索引"。
        let serving = indexedCount > 0
        if rebuildRequested {
            rebuildRequested = false
            debugLog("full rescan: 目录桶超限或根目录变更 serving=\(serving)")
            await runFullScan(roots: currentRoots(), keepServing: serving)
            return
        }
        guard !pendingEvents.isEmpty || !forcedRescans.isEmpty || !deferredDeletions.isEmpty
        else { return }

        let events = takePendingEvents()
        isApplying = true
        defer { isApplying = false }

        // 归类比扫盘本身更贵：每个事件一次 `resourceValues` + `fileExists`，一次 churn
        // （构建、下载、解压）就是几千次 stat；`prune` 还是按路径前缀两两比。
        // 放在主线程上，整个面板——包括正在输入的搜索——都要排队等它跑完，
        // 这才是"搜索偶尔卡一两秒"的主因。整套计划搬到后台算。
        let policy = makePolicy()
        let roots = activeRoots
        let rootMap = FileIndexRootMap(roots: roots)
        let forced = forcedRescans
        let deferred = deferredDeletions
        forcedRescans.removeAll()
        deferredDeletions.removeAll()
        var plan = await Task.detached(priority: .utility) {
            var plan = FileIndexEventPlanner.makePlan(events: events, policy: policy,
                                                      roots: rootMap)
            guard !plan.needsFullRescan else { return plan }
            plan.rescans.formUnion(forced)
            plan.deletions.formUnion(deferred)
            FileIndexEventPlanner.prune(&plan)
            return plan
        }.value
        if plan.needsFullRescan {
            debugLog("full rescan: 事件丢窗（根变更/丢弃标记） serving=\(serving)")
            await runFullScan(roots: currentRoots(), keepServing: serving)
            return
        }
        // 目录桶分批消化：一次最多 rescanBatchLimit 个，剩下的退回队列，下一轮接着扫。
        // 被退回那批覆盖到的刷写也一起等——重扫那棵子树时本来就会按磁盘现状重读。
        let split = Self.splitRescans(plan.rescans, limit: Self.rescanBatchLimit)
        plan.rescans = split.take
        if !split.rest.isEmpty { forcedRescans.formUnion(split.rest) }
        debugLog("events=\(events.count) delete=\(plan.deletions.count) "
                 + "rescan=\(plan.rescans.count) refresh=\(plan.fileRefreshes.count + plan.dirRefreshes.count)")
        debugLog("deletePaths=\(plan.deletions.sorted().prefix(8).joined(separator: " | ")) "
                 + "rescanPaths=\(plan.rescans.sorted().prefix(4).joined(separator: " | "))")

        do {
            if !plan.deletions.isEmpty {
                try await database.apply(upserts: [], deleting: Array(plan.deletions),
                                         maintainFTS: isFTSReady)
            }

            let refreshed = await Task.detached(priority: .utility) {
                Self.readEntries(files: plan.fileRefreshes, dirs: plan.dirRefreshes)
            }.value
            let entries = refreshed.entries
            let vanished = refreshed.vanished
            if !vanished.isEmpty {
                try await database.apply(upserts: [], deleting: vanished,
                                         maintainFTS: isFTSReady)
            }
            if !entries.isEmpty {
                try await database.upsert(entries, maintainFTS: isFTSReady)
            }

            let policy = makePolicy()
            for path in plan.rescans
                where !policy.shouldSkip(path: path) && FileManager.default.fileExists(atPath: path) {
                // 先灌暂存表、成功再一次性顶掉这棵子树：目录内被删/改名的旧路径不会出现在
                // 新扫描结果里，而删除要是先提交、扫到一半被杀，就永久留下补不回来的洞。
                try await database.beginStagingSubtree()
                _ = try await FileIndexScanner.scan(
                    roots: [URL(fileURLWithPath: path)], into: database, policy: policy,
                    staging: true)
                try await database.publishStagingSubtree(path, maintainFTS: isFTSReady)
            }

            try await database.setMeta(FileIndexMetaKey.lastEventID, value: String(plan.maxEventID))
            // 不在每批增量后重数全库：38 万行的 COUNT(*) 要几十毫秒，而这个数字只在
            // `.building` 阶段与调试日志里露脸。0 行时才补一次，保障 `serving` 判定。
            if indexedCount == 0 { indexedCount = try await database.count() }
            lastError = nil
            if !pendingEvents.isEmpty || !forcedRescans.isEmpty || !deferredDeletions.isEmpty {
                scheduleApply()
            }
        } catch is CancellationError {
            // 应用退出时允许中断，下次启动会从持久化的事件号重放；暂存表不留垃圾。
            // 这里**不许**动 phase：`scheduleApply` 每一轮都先 `applyTask?.cancel()`，
            // 把中断写成 `.idle` 等于"被自己的下一次调度打掉索引"——`applyPending` 只认
            // `.ready`，于是增量从此不再应用，每次关键词搜索都掉到 Spotlight 兜底
            //（2026-11-06 那条"Spotlight 未启用或索引不可用"的误报走的就是这条，
            // 而 `mdutil -s /` 明明是 Indexing enabled）。
            try? await database.discardStaging()
        } catch {
            try? await database.discardStaging()
            lastError = error.localizedDescription
            log.error("incremental update failed: \(error.localizedDescription, privacy: .public)")
            await runFullScan(roots: currentRoots(), keepServing: indexedCount > 0)
        }
    }

    // MARK: 事件分类

    /// 批量读属性（一次 stat 一条），在后台线程上跑：供增量更新把刷写事件折成索引行。
    nonisolated static func readEntries(files: Set<String>, dirs: Set<String>)
        -> (entries: [FileIndexEntry], vanished: [String]) {
        var entries: [FileIndexEntry] = []
        var kindCache: [String: String] = [:]
        var vanished: [String] = []
        entries.reserveCapacity(files.count + dirs.count)
        for path in files {
            guard let entry = entry(at: path, isDirectory: false, kindCache: &kindCache) else {
                vanished.append(path)
                continue
            }
            entries.append(entry)
        }
        for path in dirs {
            if let entry = entry(at: path, isDirectory: true, kindCache: &kindCache) {
                entries.append(entry)
            } else {
                vanished.append(path)
            }
        }
        return (entries, vanished)
    }

    private nonisolated static func entry(at path: String, isDirectory: Bool,
                                          kindCache: inout [String: String]) -> FileIndexEntry? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: FileIndexScanner.resourceKeys) else {
            return nil
        }
        let realDirectory = (values.isDirectory ?? false)
            && !(values.isSymbolicLink ?? false)
            && !(values.isPackage ?? false)
        return FileIndexScanner.entry(for: url, isDirectory: isDirectory && realDirectory,
                                      values: values, kindCache: &kindCache)
    }

    // MARK: 查询

    public func search(term: String, request: FileSearchRequest) async throws -> FileSearchResponse {
        if let regex = FileSearchSyntax.parse(term).regex {
            return try await regexSearch(regex: regex, request: request)
        }
        return try await search(term: term, request: request, phase: .complete)
    }

    public func searchFast(term: String, request: FileSearchRequest) async throws -> FileSearchResponse {
        try await search(term: term, request: request, phase: .fast)
    }

    public func searchBody(term: String, request: FileSearchRequest) async throws -> FileSearchResponse {
        try await search(term: term, request: request, phase: .body)
    }

    public func searchCount(term: String, request: FileSearchRequest) async throws -> FileSearchResponse {
        try await search(term: term, request: request, phase: .count)
    }

    /// 新查询已经取代旧查询时，通知只读计数连接中止在途 count。
    /// 只碰 `countReader`：快段/补全段是另外两条连接，不能因为换查询把首屏也停了。
    public func interruptCountQuery() {
        countReader.interrupt()
    }

    /// 补全段同样可能排队；换查询时让旧 body 停下，新 body 不用排在它后面。
    /// fast 仍走独立 `reader`，不会被这里误伤。
    public func interruptBodyQuery() {
        bodyReader.interrupt()
    }

    private func search(term: String, request: FileSearchRequest,
                        phase: FileIndexQueryPhase) async throws -> FileSearchResponse {
        guard self.phase == .ready else { throw FileIndexError.databaseClosed }
        lastQueryAt = ContinuousClock.now
        let syntax = FileSearchSyntax.parse(term)
        let query = FileIndexQuery(
            syntax: syntax, category: request.category, scope: request.scope,
            directories: request.directories, sort: request.sort,
            limit: max(request.limit, 1), pathSearch: request.pathSearch)
        let connection = await readConnection(for: phase)
        let result = try await connection.query(query, phase: phase, usingFTS: isFTSReady)
        if phase == .count {
            return FileSearchResponse(items: [], total: result.total,
                                      isTruncated: !result.totalIsExact,
                                      totalIsExact: result.totalIsExact)
        }

        let items = makeItems(from: result.entries)
        let truncated: Bool
        switch phase {
        case .fast:
            // 快段只跑了等值 + 前缀，包含段还没扫；除非查询本来就无需分段（通配/时间排序），
            // 否则 total 只能当下界用。
            truncated = !result.exhausted || result.total > items.count
        case .body:
            truncated = !result.exhausted || result.total > items.count
        case .complete:
            truncated = !result.totalIsExact || result.total > items.count
        case .count:
            truncated = !result.totalIsExact
        }
        return FileSearchResponse(items: items, total: result.total,
                                  isTruncated: truncated, totalIsExact: result.totalIsExact)
    }

    /// 只读连接按需打开：打不开（旧库还没生成、文件被换掉）就退回写连接，
    /// 慢一点但结果对。下一次搜索会再试一次，恢复了就自动回到快路径。
    private func readConnection(for phase: FileIndexQueryPhase) async -> FileIndexDatabase {
        let connection: FileIndexDatabase
        let failedKeyPath: ReferenceWritableKeyPath<FileIndex, Bool>
        switch phase {
        case .fast, .complete:
            connection = reader
            failedKeyPath = \.readerFailed
        case .body:
            connection = bodyReader
            failedKeyPath = \.bodyReaderFailed
        case .count:
            connection = countReader
            failedKeyPath = \.countReaderFailed
        }
        do {
            try await connection.open()
            self[keyPath: failedKeyPath] = false
            return connection
        } catch {
            if !self[keyPath: failedKeyPath] {
                self[keyPath: failedKeyPath] = true
                log.error("read connection unavailable, falling back to write connection: \(error.localizedDescription, privacy: .public)")
            }
            return database
        }
    }

    // MARK: FTS 与维护

    /// 重建排队：整库交换、首次建库、迁移之后都要补一次。
    /// 这段时间 `isFTSReady` 为假，包含段走 `instr`，结果仍然对。
    private func scheduleFTSRebuild() {
        guard !isFTSReady, ftsTask == nil, phase == .ready else { return }
        ftsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.database.rebuildFTS()
                self.isFTSReady = true
                self.lastError = nil
                self.debugLog("fts rebuilt rows=\(self.indexedCount)")
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("fts rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
            self.ftsTask = nil
            // 重建期间积压的增量现在才能落库。
            self.scheduleApply(delay: .milliseconds(200))
            self.scheduleMaintenance()
        }
    }

    /// 空间回收只能在真正空闲的窗口做：VACUUM 期间写连接被独占，
    /// 刚重建完就立刻跑会把正在看结果的人卡住。等 20 秒没有查询再动手。
    private func scheduleMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                guard self.phase == .ready, !self.isApplying, !self.isRebuilding,
                      self.ftsTask == nil else { continue }
                if let last = self.lastQueryAt,
                   ContinuousClock.now - last < .seconds(20) {
                    continue
                }
                do {
                    let freed = try await self.database.reclaimSpaceIfNeeded()
                    if freed > 0 {
                        self.debugLog("reclaimed \(freed / 1_048_576)MB free pages")
                    }
                } catch {
                    self.log.error("reclaim failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }
    }

    // MARK: 正则

    private static let regexCandidateCap = 20_000

    /// 正则不经过 SQL：先用模式里最长的一段字面文本把候选压到几千条，
    /// 再用 NSRegularExpression 精筛。没有字面锚点就直说，不拿全表去跑正则。
    private func regexSearch(regex: FileSearchSyntax.RegexSpec,
                             request: FileSearchRequest) async throws -> FileSearchResponse {
        guard self.phase == .ready else { throw FileIndexError.databaseClosed }
        lastQueryAt = ContinuousClock.now
        let options: NSRegularExpression.Options = regex.caseInsensitive ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: regex.pattern, options: options) else {
            return FileSearchResponse(items: [], total: 0, isTruncated: false,
                                      notice: L10n.Files.Notice.regexInvalid)
        }
        guard let literal = FileSearchRegex.literalAnchor(regex.pattern) else {
            return FileSearchResponse(items: [], total: 0, isTruncated: false,
                                      notice: L10n.Files.Notice.regexAnchor)
        }
        let query = FileIndexQuery(syntax: FileSearchSyntax(), category: request.category,
                                   scope: request.scope, directories: request.directories,
                                   sort: .name, limit: max(request.limit, 1))
        let connection = await readConnection(for: .complete)
        let candidates = try await connection.regexCandidates(
            query, literal: literal, cap: Self.regexCandidateCap, usingFTS: isFTSReady)
        let matched = candidates.filter { entry in
            let range = NSRange(entry.name.startIndex..., in: entry.name)
            return expression.firstMatch(in: entry.name, options: [], range: range) != nil
        }
        let limited = Array(matched.prefix(max(request.limit, 1)))
        let items = makeItems(from: limited)
        return FileSearchResponse(
            items: items, total: matched.count,
            isTruncated: matched.count > items.count || candidates.count >= Self.regexCandidateCap,
            totalIsExact: candidates.count < Self.regexCandidateCap)
    }

    private func makeItems(from entries: [FileIndexEntry]) -> [FileItem] {
        entries.map { entry in
            FileItem(url: URL(fileURLWithPath: entry.path),
                     isDirectory: entry.isDirectory,
                     contentType: nil,
                     contentTypeTree: entry.isDirectory ? ["public.folder"] : [],
                     creationDate: entry.created,
                     modificationDate: entry.modified,
                     lastUsedDate: entry.lastUsed,
                     fileSize: entry.size,
                     origin: .index)
        }
    }

    // MARK: 根目录

    private func currentRoots() -> [URL] {
        if !overrideRoots.isEmpty {
            return FileIndexRoots.normalized(overrideRoots)
        }
        return FileIndexRoots.defaultRoots(custom: FileSearchSettings.shared.directories)
    }

    private func makePolicy() -> FileIndexPolicy {
        FileIndexPolicy(internalDirectory: databaseURL.deletingLastPathComponent())
    }

    private func observeRootsIfNeeded() {
        guard !observingRoots, overrideRoots.isEmpty else { return }
        observingRoots = true
        rearmRootObservation()
    }

    private func rearmRootObservation() {
        withObservationTracking {
            _ = FileSearchSettings.shared.directories
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rearmRootObservation()
                self.rootsChanged()
            }
        }
    }

    private func rootsChanged() {
        guard phase == .ready || phase == .building || phase == .opening else { return }
        rootWatchTask?.cancel()
        rootWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let roots = self.currentRoots()
            guard FileIndexRoots.signature(roots) != FileIndexRoots.signature(self.activeRoots)
            else { return }
            switch self.phase {
            case .ready:
                await self.runFullScan(roots: roots, keepServing: self.indexedCount > 0)
            case .building, .opening:
                self.rebuildRequested = true
            default:
                break
            }
        }
    }

    // MARK: 辅助

    /// 一轮事件里真正会动到索引的条数上限，超过就折叠成目录级重扫。
    nonisolated static let pendingEventLimit = 20_000
    /// 一次 apply 最多扫几个目录桶，剩下的下一轮接着扫：
    /// 多目录同时 churn 也只是把重扫摊成几小段，不再演变成整库重建。
    nonisolated static let rescanBatchLimit = 6

    /// 交换时记下行数；之后少了两成以上说明中间断过一次"删了子树没扫回来"的
    /// 重扫——这种洞不会自己长回去，得在背后补扫一遍。
    nonisolated static func suspectsHole(now: Int, atCompletion saved: Int?) -> Bool {
        guard let saved, saved > 1000 else { return false }
        return now * 10 < saved * 8
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        phase = .failed(message)
        log.error("file index failed: \(message, privacy: .public)")
        FileHandle.standardError.write("file index failed: \(message)\n".data(using: .utf8)!)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil else { return }
        log.info("\(message, privacy: .public)")
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        #endif
    }

    private nonisolated static func parseRoots(_ raw: String?) -> [URL] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ":")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

/// 索引库 meta 表里判定"这份索引还能接着用"的键。
enum FileIndexMetaKey {
    static let rootsSignature = "roots_signature"
    static let policyVersion = "policy_version"
    static let completedAt = "full_scan_completed_at"
    static let rowCount = "full_scan_row_count"
    static let lastEventID = "last_event_id"
    /// FTS 重建完成才写 1；整库交换/迁移会清空。
    static let ftsReady = "fts_ready"
    /// 重扫开始就写、交换成功才删：还留着说明上一次重扫被打断在半路。
    static let rebuilding = "full_scan_in_progress"
}

/// 在 FSEvents 自己的串行队列上跑：滤掉全量扫描根本不收的路径，再把留下的事件顺手
/// 归并成「根下第一层目录」的桶。这两件事每个路径都要构造一次 URL，放在主线程上
/// 就是一次点击排在几千个事件后面（实测空闲时占主线程 0.7%，churn 大时线性放大）。
struct FileIndexEventFilter: Sendable {
    private let policy: FileIndexPolicy
    private let roots: [URL]
    private let rootMap: FileIndexRootMap

    init(roots: [URL], policy: FileIndexPolicy) {
        self.policy = policy
        self.roots = roots
        self.rootMap = FileIndexRootMap(roots: roots)
    }

    func process(_ events: [FileIndexEvent]) -> (kept: [FileIndexEvent], buckets: Set<String>) {
        var kept: [FileIndexEvent] = []
        var buckets: Set<String> = []
        kept.reserveCapacity(events.count)
        for event in events where !policy.shouldSkip(path: event.path) {
            kept.append(event)
            let display = rootMap.displayPath(
                for: URL(fileURLWithPath: event.path).standardizedFileURL.path)
            guard let bucket = FileIndex.bucket(of: display, roots: roots),
                  !policy.shouldSkip(path: bucket) else { continue }
            buckets.insert(bucket)
        }
        return (kept, buckets)
    }
}
