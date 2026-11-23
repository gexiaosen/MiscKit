import Foundation
import SQLite3

// MARK: - 行模型

struct FileIndexEntry: Equatable, Sendable {
    let path: String
    let name: String
    let nameFolded: String
    let ext: String
    let kind: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let lastUsed: Date?

    init(path: String, name: String, isDirectory: Bool, ext: String, kind: String,
         size: Int64? = nil, modified: Date? = nil, created: Date? = nil,
         lastUsed: Date? = nil) {
        self.init(path: path, name: name, nameFolded: FileIndexText.fold(name),
                  isDirectory: isDirectory, ext: ext, kind: kind,
                  size: size, modified: modified, created: created, lastUsed: lastUsed)
    }

    /// 从库里读出来的行已经存过 `name_folded`，别再跑一遍 ICU 折叠：一次查询 80 行，
    /// 每行一次 `precomposedStringWithCanonicalMapping` + `folding` 是白扔的几十毫秒。
    init(path: String, name: String, nameFolded: String, isDirectory: Bool, ext: String,
         kind: String, size: Int64?, modified: Date?, created: Date?, lastUsed: Date?) {
        self.path = path
        self.name = name
        self.nameFolded = nameFolded
        self.ext = ext
        self.kind = kind
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.lastUsed = lastUsed
    }
}

/// 一次查询的产出。`total` 命中计数上限（见 `FileIndexDatabase.countCap`）时只是下界，
/// 这时 `totalIsExact` 为假：宁可显示「1000+」，也不要为了一个精确数字再全表扫一遍。
struct FileIndexQueryResult: Sendable {
    let entries: [FileIndexEntry]
    let total: Int
    let totalIsExact: Bool
    /// 结果集是否已经翻到底。为假时 `total` 只是下界，调用方还可以继续跑补全/计数阶段。
    let exhausted: Bool
}

/// 查询阶段。`fast` 只取等值 + 前缀，先让第一屏有内容；`body` 再补包含段；
/// `count` 只算总数。三个阶段分开后，慢的计数不再决定首屏。
enum FileIndexQueryPhase: Sendable {
    case complete
    case fast
    case body
    case count
}

struct FileIndexQuery: Sendable {
    var syntax: FileSearchSyntax
    var category: FileCategory
    var scope: FileScope
    var directories: [URL]
    var sort: FileSort
    var limit: Int
}

enum FileIndexError: LocalizedError, Equatable {
    case databaseClosed
    case sql(String)
    case open(String)

    var errorDescription: String? {
        switch self {
        case .databaseClosed: return L10n.Files.DB.closed
        case .sql(let message): return L10n.Files.DB.sql(message)
        case .open(let message): return L10n.Files.DB.open(message)
        }
    }
}

// MARK: - SQLite 封装

/// 所有 SQL 都在这个 actor 上串行执行；扫描批次、查询和增量更新共用一条连接。
///
/// `readOnly` 为真时是查询专用连接：同一份库上的第二条连接，只读、只跑 SELECT。
/// 它存在的唯一理由是让查询不必排在增量更新/子树重扫后面——一个 actor 一条连接时，
/// 一次目录重扫能把每一次按键的查询堵住一两秒（对外表现就是"搜索偶尔卡住"）。
actor FileIndexDatabase {
    private let url: URL
    private let readOnly: Bool
    private let cacheSizeKB: Int
    // 连接只在 actor 内使用；deinit 需要关闭它，而 deinit 是非隔离的。
    nonisolated(unsafe) private var db: OpaquePointer?
    /// `sqlite3_interrupt` 必须能从查询所在的 actor 之外调用；句柄与“是否有可中断的 count
    /// 正在执行”一起由这把锁保护，避免在连接关闭后拿到悬空指针，也避免空转时设置中断标志、
    /// 误伤下一条查询。
    private let interruptLock = NSLock()
    nonisolated(unsafe) private var interruptHandle: OpaquePointer?
    nonisolated(unsafe) private var interruptibleQueryRunning = false

    init(url: URL, readOnly: Bool = false, cacheSizeKB: Int = 32 * 1024) {
        self.url = url
        self.readOnly = readOnly
        self.cacheSizeKB = cacheSizeKB
    }

    deinit {
        storeInterruptHandle(nil)
        if let db {
            sqlite3_close_v2(db)
        }
    }

    /// 只中断正在执行的 count 查询。`fast` / `body` 有自己的连接，也不会被标记为可中断；
    /// 没有 count 在跑时是 no-op，不会把中断标志留给下一条 SQL。
    nonisolated func interrupt() {
        interruptLock.lock()
        defer { interruptLock.unlock() }
        guard interruptibleQueryRunning, let interruptHandle else { return }
        sqlite3_interrupt(interruptHandle)
    }

    nonisolated private func storeInterruptHandle(_ handle: OpaquePointer?) {
        interruptLock.lock()
        interruptHandle = handle
        interruptLock.unlock()
    }

    nonisolated private func storeInterruptibleQueryRunning(_ value: Bool) {
        interruptLock.lock()
        interruptibleQueryRunning = value
        interruptLock.unlock()
    }

    func open() throws {
        guard db == nil else { return }
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | (readOnly ? 0 : SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw FileIndexError.open(message)
        }
        db = handle
        storeInterruptHandle(handle)
        sqlite3_busy_timeout(handle, 4000)
        if readOnly {
            // 只读连接自己不做 checkpoint，页缓存与 mmap 归它自己：
            // 38 万行、800MB 的库靠 read() 逐页取，冷页就是几十毫秒起步。
            try execute("PRAGMA query_only=1")
            try execute("PRAGMA mmap_size=\(256 * 1024 * 1024)")
            try execute("PRAGMA cache_size=\(-cacheSizeKB)")
            try execute("PRAGMA temp_store=MEMORY")
            return
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA temp_store=MEMORY")
        try migrate()
    }

    func close() {
        guard let db else { return }
        storeInterruptHandle(nil)
        sqlite3_close_v2(db)
        self.db = nil
    }

    // MARK: schema

    private func migrate() throws {
        let version = try userVersion()
        if version != Self.schemaVersion {
            try execute("DROP TABLE IF EXISTS \(Self.liveTable)")
            try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
            try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
            try execute("DROP TABLE IF EXISTS meta")
            try createSchema()
            try setUserVersion(Self.schemaVersion)
        } else {
            try createSchema()
        }
    }

    private func createSchema() throws {
        try createEntriesTable(Self.liveTable)
        try execute("""
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """)
        try healIndexesIfDefinitionChanged()
    }

    /// 索引定义换过版（单列 DESC → 与查询 ORDER BY 同式的复合表达式）就得整套换掉，
    /// 光数"有没有 5 棵"是换不掉的。
    private func healIndexesIfDefinitionChanged() throws {
        guard try meta(Self.indexDefinitionKey) != String(Self.indexDefinitionVersion) else {
            try ensureLiveIndexes()
            return
        }
        for name in try liveIndexNames() {
            try execute("DROP INDEX IF EXISTS \(name)")
        }
        try createIndexes(on: Self.liveTable, names: try freeIndexNames())
        try setMeta(Self.indexDefinitionKey, value: String(Self.indexDefinitionVersion))
    }

    private func createEntriesTable(_ table: String) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS \(table)(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            name_folded TEXT NOT NULL,
            ext TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL DEFAULT 'other',
            is_directory INTEGER NOT NULL DEFAULT 0,
            size INTEGER,
            modified REAL,
            created REAL,
            last_used REAL
        )
        """)
    }

    /// 交换之后正式表挂的是暂存表那套索引名，所以"缺不缺索引"只能数棵数，不能按名字查。
    private func ensureLiveIndexes() throws {
        guard try liveIndexNames().count < Self.indexColumns.count else { return }
        for name in try liveIndexNames() {
            try execute("DROP INDEX IF EXISTS \(name)")
        }
        try createIndexes(on: Self.liveTable, names: try freeIndexNames())
    }

    /// 正式表上实际挂着的索引名（自动建的 UNIQUE 索引不算）。
    func liveIndexNames() throws -> [String] {
        let statement = try prepare(
            "SELECT name FROM pragma_index_list('\(Self.liveTable)') WHERE name NOT LIKE 'sqlite_%'")
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(columnText(statement, 0)) }
        return names
    }

    private func existingIndexNames() throws -> Set<String> {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type = 'index'")
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(columnText(statement, 0)) }
        return names
    }

    /// 两套名字轮流用：交换事务里旧表连同它那套名字一起退场，下一轮暂存表就能占另一套。
    private func freeIndexNames() throws -> [String] {
        let taken = try existingIndexNames()
        for names in Self.indexNameSets where !names.contains(where: { taken.contains($0) }) {
            return names
        }
        return Self.indexNameSets[0]
    }

    private func createIndexes(on table: String, names: [String]) throws {
        for (name, column) in zip(names, Self.indexColumns) {
            try execute("CREATE INDEX IF NOT EXISTS \(name) ON \(table)(\(column))")
        }
    }

    private static let liveTable = "entries"
    private static let stagingTable = "entries_staging"
    private static let retiredTable = "entries_retired"
    private static let indexDefinitionKey = "index_definition_version"
    private static let indexDefinitionVersion = 2

    private static let indexColumns = [
        "name_folded", "kind",
        // 表达式要和查询里的 ORDER BY 写成同一棵树，否则规划器不认，
        // 排序只能全表扫 + TEMP B-TREE（实测 45ms 走索引后 0ms）。
        "COALESCE(modified, 0) DESC, name_folded",
        "COALESCE(created, 0) DESC, name_folded",
        "COALESCE(size, 0) DESC, name_folded",
    ]
    private static let indexNameSets: [[String]] = [
        ["idx_entries_name", "idx_entries_kind", "idx_entries_modified",
         "idx_entries_created", "idx_entries_size"],
        ["idx_stage_name", "idx_stage_kind", "idx_stage_modified",
         "idx_stage_created", "idx_stage_size"],
    ]

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return sqlite3_column_int(statement, 0)
    }

    private func setUserVersion(_ value: Int32) throws {
        try execute("PRAGMA user_version = \(value)")
    }

    // MARK: 写入

    func upsert(_ entries: [FileIndexEntry]) throws {
        try apply(upserts: entries, into: Self.liveTable, deleting: [])
    }

    func apply(upserts: [FileIndexEntry], deleting deletes: [String]) throws {
        try apply(upserts: upserts, into: Self.liveTable, deleting: deletes)
    }

    private func apply(upserts: [FileIndexEntry], into table: String,
                       deleting deletes: [String]) throws {
        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if !deletes.isEmpty {
                // 子树用 path 范围删除：能走 UNIQUE 索引，避免每条删除都全表扫一遍。
                let statement = try prepare(
                    "DELETE FROM \(table) WHERE path = ? OR (path >= ? AND path < ?)")
                defer { sqlite3_finalize(statement) }
                for path in deletes {
                    let clean = Self.cleanPath(path)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bindText(clean, to: statement, at: 1)
                    try bindText(clean + "/", to: statement, at: 2)
                    try bindText(clean + "0", to: statement, at: 3)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
                }
            }

            if !upserts.isEmpty {
                let statement = try prepare("""
                INSERT INTO \(table)(path, name, name_folded, ext, kind,
                                     is_directory, size, modified, created, last_used)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    name = excluded.name,
                    name_folded = excluded.name_folded,
                    ext = excluded.ext,
                    kind = excluded.kind,
                    is_directory = excluded.is_directory,
                    size = excluded.size,
                    modified = excluded.modified,
                    created = excluded.created,
                    last_used = excluded.last_used
                """)
                defer { sqlite3_finalize(statement) }
                for entry in upserts {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bindText(entry.path, to: statement, at: 1)
                    try bindText(entry.name, to: statement, at: 2)
                    try bindText(entry.nameFolded, to: statement, at: 3)
                    try bindText(entry.ext, to: statement, at: 4)
                    try bindText(entry.kind, to: statement, at: 5)
                    sqlite3_bind_int(statement, 6, entry.isDirectory ? 1 : 0)
                    if let size = entry.size {
                        sqlite3_bind_int64(statement, 7, size)
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    if let modified = entry.modified {
                        sqlite3_bind_double(statement, 8, modified.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 8)
                    }
                    if let created = entry.created {
                        sqlite3_bind_double(statement, 9, created.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 9)
                    }
                    if let lastUsed = entry.lastUsed {
                        sqlite3_bind_double(statement, 10, lastUsed.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 10)
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func deleteSubtree(_ path: String) throws {
        try apply(upserts: [], deleting: [path])
    }

    // MARK: 全量重扫的暂存与交换

    /// 重扫先灌暂存表，正式表在扫描期间保持原样可用；崩溃在这里留下的只有暂存表。
    func beginStaging() throws {
        try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
        try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
        try createEntriesTable(Self.stagingTable)
    }

    func stage(_ entries: [FileIndexEntry]) throws {
        try apply(upserts: entries, into: Self.stagingTable, deleting: [])
    }

    /// 交换之前：把 5 棵索引先在暂存表上建好。这 0.6 秒里正式表照常供查询，
    /// 交换事务就只剩两次改名——不再有"每次重扫结尾硬顿一下"。
    func buildStagingIndexes() throws {
        try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
        try createIndexes(on: Self.stagingTable, names: try freeIndexNames())
    }

    func discardStaging() throws {
        try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
    }

    /// 一次事务里改名 + 落元数据：提交前崩溃 = 旧索引一字未动。
    func publishStaging(meta updates: [(key: String, value: String?)]) throws {
        let staged = try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            values: [.text(Self.stagingTable)])
        guard staged > 0 else { throw FileIndexError.sql(L10n.Files.DB.noStaged) }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("ALTER TABLE \(Self.liveTable) RENAME TO \(Self.retiredTable)")
            try execute("ALTER TABLE \(Self.stagingTable) RENAME TO \(Self.liveTable)")
            // 旧表连同它那套索引名一起退场：下一轮暂存表才建得同名索引。
            try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
            // 索引本该在交换前就建在暂存表上（跟着改名一起过来）；真缺了这里补上，
            // 别让正式表裸奔到下一次重扫。
            try ensureLiveIndexes()
            for update in updates {
                try setMeta(update.key, value: update.value)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// 旧表腾出的页留在文件里，攒多了整理一次，别把磁盘越用越大。
    /// VACUUM 期间这条连接什么都干不了，所以只在本来就没在服务查询的时候做。
    func reclaimSpaceIfNeeded() throws {
        let freePages = try scalarInt("PRAGMA freelist_count", values: [])
        let pageSize = try scalarInt("PRAGMA page_size", values: [])
        guard freePages * pageSize > 64 * 1024 * 1024 else { return }
        try execute("VACUUM")
    }

    // MARK: 子树重扫的暂存与交换

    /// 目录级重扫也不能"先删再扫"：删除一旦提交，扫到一半被杀就永久留下空洞。
    /// 所以同样先灌暂存表，成功后一次事务里用暂存内容顶掉那棵子树。
    func beginStagingSubtree() throws {
        try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
        try createEntriesTable(Self.stagingTable)
    }

    func publishStagingSubtree(_ path: String) throws {
        let clean = Self.cleanPath(path)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM \(Self.liveTable) WHERE path = ? OR (path >= ? AND path < ?)",
                        values: [clean, clean + "/", clean + "0"])
            try execute("""
            INSERT INTO \(Self.liveTable)(path, name, name_folded, ext, kind,
                                          is_directory, size, modified, created, last_used)
            SELECT path, name, name_folded, ext, kind,
                   is_directory, size, modified, created, last_used
            FROM \(Self.stagingTable)
            """)
            try execute("DROP TABLE \(Self.stagingTable)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, text) in values.enumerated() {
            try bindText(text, to: statement, at: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    func stagedCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM \(Self.stagingTable)", values: [])
    }

    // MARK: 读取

    func count() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM \(Self.liveTable)", values: [])
    }

    func meta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    func setMeta(_ key: String, value: String?) throws {
        if let value {
            let statement = try prepare("""
            INSERT INTO meta(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
            defer { sqlite3_finalize(statement) }
            try bindText(key, to: statement, at: 1)
            try bindText(value, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        } else {
            let statement = try prepare("DELETE FROM meta WHERE key = ?")
            defer { sqlite3_finalize(statement) }
            try bindText(key, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        }
    }

    // MARK: 查询

    /// 命中计数的上限：超过它就只报「这么多」而不追求精确。
    /// 一个 38 万行的库上，精确总数意味着每次按键都要多扫一遍全表，
    /// 而用户真正需要的信息只是「还有很多，先给你 80 条」。
    nonisolated static let countCap = 1000

    /// 查询计划分成三类子句：基础过滤（类型/范围/扩展名）、词过滤、排序。
    /// `whereSQL` 与 `values` 必须按 append 顺序成对使用。
    private struct Filter {
        var clauses: [String] = []
        var values: [SQLValue] = []

        var whereSQL: String { clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ") }

        mutating func merge(_ other: Filter) {
            clauses.append(contentsOf: other.clauses)
            values.append(contentsOf: other.values)
        }

        mutating func append(_ clause: String, _ values: [SQLValue] = []) {
            clauses.append(clause)
            self.values.append(contentsOf: values)
        }
    }

    func query(_ query: FileIndexQuery) throws -> FileIndexQueryResult {
        try self.query(query, phase: .complete)
    }

    /// `phase == .complete` 保持原有的一次性语义，测试和兜底路径用它；
    /// 主搜索走 `.fast` → `.body` → `.count`，慢段不再挡首屏。
    func query(_ query: FileIndexQuery, phase: FileIndexQueryPhase) throws -> FileIndexQueryResult {
        let interruptible = phase == .body || phase == .count
        if interruptible { storeInterruptibleQueryRunning(true) }
        defer {
            if interruptible { storeInterruptibleQueryRunning(false) }
        }

        let limit = max(query.limit, 0)
        let base = baseFilter(query)
        let rankingIndex = query.syntax.terms.firstIndex { !$0.isNegated }

        if phase == .count {
            let count = try cappedCount(fullFilter(query))
            return FileIndexQueryResult(entries: [], total: count.count,
                                        totalIsExact: count.exact, exhausted: true)
        }

        guard limit > 0 else {
            let count = try cappedCount(fullFilter(query))
            return FileIndexQueryResult(entries: [], total: count.count,
                                        totalIsExact: count.exact, exhausted: true)
        }

        // 相关度排序走「分段取」：完全相等 → 前缀 → 其余，三段合起来正好覆盖全部命中，
        // 段内按名字序。前两段顺着 `name_folded` 索引区间走，第三段才扫包含；
        // `.fast` 只跑前两段，命中够了就停。
        if query.sort == .relevance,
           let rankingIndex,
           !query.syntax.terms[rankingIndex].text.isEmpty,
           !query.syntax.terms[rankingIndex].hasWildcard {
            return try queryRanking(query, base: base, rankingIndex: rankingIndex,
                                    limit: limit, phase: phase)
        }

        return try queryOrdered(query, base: base, limit: limit, phase: phase)
    }

    private func queryRanking(_ query: FileIndexQuery, base: Filter, rankingIndex: Int,
                              limit: Int, phase: FileIndexQueryPhase) throws -> FileIndexQueryResult {
        let folded = FileIndexText.fold(query.syntax.terms[rankingIndex].text)
        let rest = termFilter(query, skipping: rankingIndex)
        var seen = Set<String>()
        var collected: [FileIndexEntry] = []
        var overflow = false
        for group in Self.rankingGroups(folded: folded, phase: phase) {
            if collected.count > limit { break }
            var filter = base
            filter.merge(rest)
            filter.append(group.clause, group.values)
            let rows = try select(filter, order: "name_folded ASC, id ASC", limit: limit + 1)
            if rows.count > limit { overflow = true }
            for row in rows where seen.insert(row.path).inserted {
                collected.append(row)
            }
        }

        // `.fast` 只跑了前两段，包含段还没扫，不能宣称“到底了”；
        // `.body` 三段都跑过，收集数没超过上限才算到底。
        let exhausted = phase == .fast ? false : (!overflow && collected.count <= limit)
        return try makeResult(collected, limit: limit, filter: fullFilter(query),
                              exhausted: exhausted, phase: phase)
    }

    private func queryOrdered(_ query: FileIndexQuery, base: Filter,
                              limit: Int, phase: FileIndexQueryPhase) throws -> FileIndexQueryResult {
        let order: String
        switch query.sort {
        case .relevance, .name:
            // 没有可分段的正向词（只有排除词 / 通配词）时退回名字序。
            order = "name_folded ASC, id ASC"
        case .modified:
            order = "COALESCE(modified, 0) DESC, name_folded ASC, id ASC"
        case .created:
            order = "COALESCE(created, 0) DESC, name_folded ASC, id ASC"
        case .size:
            order = "COALESCE(size, 0) DESC, name_folded ASC, id ASC"
        }
        var filter = base
        filter.merge(termFilter(query, skipping: nil))
        let rows = try select(filter, order: order, limit: limit + 1)
        let exhausted = rows.count <= limit
        return try makeResult(rows, limit: limit, filter: fullFilter(query),
                              exhausted: exhausted, phase: phase)
    }

    /// 三段排序子句：`name_folded` 上的等值、前缀、包含。
    /// 前缀改用 `GLOB`：`LIKE 'x%' ESCAPE` 在 SQLite 里会退化成全索引 `SCAN`，
    /// `GLOB` 才能让规划器走 `name_folded` 的区间；含 `[` / `]` 的名字由 `globPrefix` 转义。
    private static func rankingGroups(folded: String,
                                      phase: FileIndexQueryPhase) -> [(clause: String, values: [SQLValue])] {
        let groups: [(clause: String, values: [SQLValue])] = [
            ("name_folded = ?", [.text(folded)]),
            ("name_folded GLOB ?", [.text(FileIndexText.globPrefix(folded))]),
            ("instr(name_folded, ?) > 0", [.text(folded)]),
        ]
        return phase == .fast ? Array(groups.prefix(2)) : groups
    }

    /// 截断判定与总数：取到的行没到 limit 说明已经翻到底，总数就是行数；
    /// 到顶了才去数一遍（有上限，见 `countCap`）。`.fast` / `.body` 不数，
    /// 把 `total` 作为下界交给 UI，等 `.count` 阶段再补齐。
    private func makeResult(_ rows: [FileIndexEntry], limit: Int, filter: Filter,
                            exhausted: Bool, phase: FileIndexQueryPhase) throws -> FileIndexQueryResult {
        let items = Array(rows.prefix(limit))
        if phase != .complete {
            return FileIndexQueryResult(entries: items, total: items.count,
                                        totalIsExact: exhausted, exhausted: exhausted)
        }
        guard !exhausted else {
            return FileIndexQueryResult(entries: items, total: items.count,
                                        totalIsExact: true, exhausted: true)
        }
        let count = try cappedCount(filter)
        return FileIndexQueryResult(entries: items, total: count.count,
                                    totalIsExact: count.exact, exhausted: false)
    }

    /// 分类 / 范围 / `folder:` `file:` / `ext:` 这些与词无关的过滤。
    private func baseFilter(_ query: FileIndexQuery) -> Filter {
        var filter = Filter()
        if query.syntax.folderOnly { filter.append("is_directory = 1") }
        if query.syntax.fileOnly { filter.append("is_directory = 0") }
        if !query.syntax.extensions.isEmpty {
            let placeholders = Array(repeating: "?", count: query.syntax.extensions.count)
                .joined(separator: ",")
            filter.append("ext IN (\(placeholders))",
                          query.syntax.extensions.map { .text($0) })
        }

        switch query.category {
        case .all:
            break
        case .folder:
            filter.append("is_directory = 1")
        default:
            filter.append("kind = ?", [.text(query.category.rawValue)])
        }

        if query.scope == .folders {
            let directories = query.directories.isEmpty
                ? [FileManager.default.homeDirectoryForCurrentUser]
                : query.directories
            var scopes: [String] = []
            var values: [SQLValue] = []
            for directory in directories {
                let path = Self.cleanPath(directory.path)
                // 子树判定用 path 区间而不是 LIKE：`path` 上有 UNIQUE 索引，
                // 区间能顺着索引走，LIKE 'x/%' 只能逐行比对。
                scopes.append("(path = ? OR (path >= ? AND path < ?))")
                values.append(.text(path))
                values.append(.text(path + "/"))
                values.append(.text(path + "0"))
            }
            filter.append("(" + scopes.joined(separator: " OR ") + ")", values)
        }
        return filter
    }

    /// 全部词的过滤；`skipping` 用于分段取时把排序那一个词换成段子句。
    /// 不含通配符的词用 `instr` 做字面包含，不再拼 `%...%` 让 LIKE 逐行解析；
    /// 通配词仍走 LIKE，因为 `?` / `*` 要保留模式语义。
    private func termFilter(_ query: FileIndexQuery, skipping: Int?) -> Filter {
        var filter = Filter()
        for (index, term) in query.syntax.terms.enumerated() where index != skipping {
            if term.hasWildcard {
                let pattern = FileSearchSyntax.likePattern(for: term)
                filter.append(term.isNegated
                    ? "name_folded NOT LIKE ? ESCAPE '\\'"
                    : "name_folded LIKE ? ESCAPE '\\'",
                    [.text(pattern)])
            } else {
                let needle = FileIndexText.fold(term.text)
                filter.append(term.isNegated
                    ? "instr(name_folded, ?) = 0"
                    : "instr(name_folded, ?) > 0",
                    [.text(needle)])
            }
        }
        return filter
    }

    private func fullFilter(_ query: FileIndexQuery) -> Filter {
        var filter = baseFilter(query)
        filter.merge(termFilter(query, skipping: nil))
        return filter
    }

    private func select(_ filter: Filter, order: String, limit: Int) throws -> [FileIndexEntry] {
        let sql = """
        SELECT path, name, name_folded, is_directory, ext, kind, size, modified, created, last_used
        FROM \(Self.liveTable)
        WHERE \(filter.whereSQL)
        ORDER BY \(order)
        LIMIT ?
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in filter.values {
            try bind(value, to: statement, at: index)
            index += 1
        }
        sqlite3_bind_int64(statement, index, Int64(max(limit, 0)))

        var entries: [FileIndexEntry] = []
        entries.reserveCapacity(max(limit, 0))
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(entryFromRow(statement))
        }
        return entries
    }

    /// 数命中，但最多数到 `countCap + 1` 就停：索引扫到第 1001 个命中即收手。
    private func cappedCount(_ filter: Filter) throws -> (count: Int, exact: Bool) {
        let sql = """
        SELECT COUNT(*) FROM (
            SELECT 1 FROM \(Self.liveTable) WHERE \(filter.whereSQL) LIMIT ?
        )
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in filter.values {
            try bind(value, to: statement, at: index)
            index += 1
        }
        sqlite3_bind_int64(statement, index, Int64(Self.countCap + 1))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        let value = Int(sqlite3_column_int64(statement, 0))
        return value > Self.countCap ? (Self.countCap, false) : (value, true)
    }

    private func entryFromRow(_ statement: OpaquePointer) -> FileIndexEntry {
        let size = sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 6)
        let modified = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let created = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        let lastUsed = sqlite3_column_type(statement, 9) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
        return FileIndexEntry(path: columnText(statement, 0),
                              name: columnText(statement, 1),
                              nameFolded: columnText(statement, 2),
                              isDirectory: sqlite3_column_int(statement, 3) != 0,
                              ext: columnText(statement, 4),
                              kind: columnText(statement, 5),
                              size: size, modified: modified,
                              created: created, lastUsed: lastUsed)
    }

    // MARK: 绑定与错误

    private enum SQLValue {
        case text(String)
        case int(Int64)
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer, at index: Int32) throws {
        switch value {
        case .text(let text):
            try bindText(text, to: statement, at: index)
        case .int(let number):
            sqlite3_bind_int64(statement, index, number)
        }
    }

    private func bindText(_ text: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = text.withCString {
            sqlite3_bind_text(statement, index, $0, -1, fileIndexSQLiteTransient)
        }
        guard result == SQLITE_OK else { throw currentError() }
    }

    private func scalarInt(_ sql: String, values: [SQLValue]) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in values {
            try bind(value, to: statement, at: index)
            index += 1
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw FileIndexError.databaseClosed }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw FileIndexError.sql(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw FileIndexError.databaseClosed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw currentError()
        }
        return statement
    }

    private func currentError() -> FileIndexError {
        guard let db else { return .databaseClosed }
        return .sql(String(cString: sqlite3_errmsg(db)))
    }

    private static func cleanPath(_ path: String) -> String {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        return clean.count > 1 && clean.hasSuffix("/") ? String(clean.dropLast()) : clean
    }

    private static let schemaVersion: Int32 = 1
}

nonisolated(unsafe) private let fileIndexSQLiteTransient =
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
