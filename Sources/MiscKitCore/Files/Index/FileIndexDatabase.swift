import Foundation
import SQLite3

// MARK: - 行模型

struct FileIndexEntry: Equatable, Sendable {
    let path: String
    let name: String
    let nameFolded: String
    /// 汉字名的全拼（无声调、无空格）；非汉字名为空串。
    let namePinyin: String
    /// 汉字名的拼音首字母；非汉字名为空串。
    let nameInitials: String
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
        let pinyin = FileIndexPinyin.make(name)
        self.init(path: path, name: name, nameFolded: FileIndexText.fold(name),
                  namePinyin: pinyin.full, nameInitials: pinyin.initials,
                  isDirectory: isDirectory, ext: ext, kind: kind,
                  size: size, modified: modified, created: created, lastUsed: lastUsed)
    }

    init(path: String, name: String, nameFolded: String,
         namePinyin: String = "", nameInitials: String = "",
         isDirectory: Bool, ext: String, kind: String,
         size: Int64?, modified: Date?, created: Date?, lastUsed: Date?) {
        self.path = path
        self.name = name
        self.nameFolded = nameFolded
        self.namePinyin = namePinyin
        self.nameInitials = nameInitials
        self.isDirectory = isDirectory
        self.ext = ext
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.lastUsed = lastUsed
    }

    /// 从库里读出来的行已经存过各列折叠/转写结果，别再跑一遍 ICU 与拼音转换。
    init(rowPath: String, name: String, nameFolded: String, pinyin: String,
         initials: String, isDirectory: Bool, ext: String, kind: String,
         size: Int64?, modified: Date?, created: Date?, lastUsed: Date?) {
        self.init(path: rowPath, name: name, nameFolded: nameFolded,
                  namePinyin: pinyin, nameInitials: initials,
                  isDirectory: isDirectory, ext: ext, kind: kind,
                  size: size, modified: modified, created: created, lastUsed: lastUsed)
    }
}

/// 一次查询的产出。`total` 命中计数上限（见 `FileIndexDatabase.countCap`）时只是下界，
/// 这时 `totalIsExact` 为假：宁可显示「300+」，也不要为了一个精确数字再全表扫一遍。
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
    /// 路径直达失败后的回退：只看完整路径，不只看文件名。
    var pathSearch: Bool = false
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

    /// 语义 v2：多出拼音列、去掉三张复合排序索引、新增 FTS5 trigram 表。
    /// 版本不一致时整库重建——旧行没有拼音列，补也算不回来，只能重扫。
    private func migrate() throws {
        let version = try userVersion()
        if version != Self.schemaVersion {
            try execute("DROP TABLE IF EXISTS \(Self.liveTable)")
            try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
            try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
            try execute("DROP TABLE IF EXISTS \(Self.ftsTable)")
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
        try createFTS()
        try healIndexesIfDefinitionChanged()
    }

    private func createFTS() throws {
        try execute(Self.ftsDefinition(Self.ftsTable))
    }

    /// 索引定义换过版（五索引 → 名称 + 修改时间两索引）就得整套换掉，
    /// 光数"够不够"是换不掉的。
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
            name_pinyin TEXT NOT NULL DEFAULT '',
            name_initials TEXT NOT NULL DEFAULT '',
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
    static let ftsTable = "name_fts"
    private static let indexDefinitionKey = "index_definition_version"
    private static let indexDefinitionVersion = 3

    /// 只留两棵：名称（等值/前缀/名字序）与修改时间（默认的"最近"排序）。
    /// 原先 created/size 各自再挂一棵带 name_folded 的复合索引，等于把名字又抄了两份，
    /// 一百万行白占 110MB；非名字排序改为在候选集上排，候选集本来就只有几百条。
    private static let indexColumns = [
        "name_folded",
        "COALESCE(modified, 0) DESC, name_folded",
    ]
    /// 供测试核对"两套名字轮流用、棵数不涨"。
    nonisolated static var liveIndexCount: Int { indexColumns.count }
    private static let indexNameSets: [[String]] = [
        ["idx_entries_name", "idx_entries_modified"],
        ["idx_stage_name", "idx_stage_modified"],
    ]

    private static func ftsDefinition(_ name: String) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS \(name) USING fts5(
            name, pinyin, initials,
            content='', contentless_delete=1, tokenize='trigram'
        )
        """
    }

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

    func upsert(_ entries: [FileIndexEntry], maintainFTS: Bool = false) throws {
        try apply(upserts: entries, into: Self.liveTable, deleting: [], maintainFTS: maintainFTS)
    }

    func apply(upserts: [FileIndexEntry], deleting deletes: [String],
               maintainFTS: Bool = false) throws {
        try apply(upserts: upserts, into: Self.liveTable, deleting: deletes,
                  maintainFTS: maintainFTS)
    }

    private func apply(upserts: [FileIndexEntry], into table: String,
                       deleting deletes: [String], maintainFTS: Bool) throws {
        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if !deletes.isEmpty {
                if maintainFTS {
                    // 先按旧 id 删 FTS，再删行：删完行就查不到 id 了。
                    let statement = try prepare(
                        "DELETE FROM \(Self.ftsTable) WHERE rowid IN ("
                        + "SELECT id FROM \(table) WHERE path = ? OR (path >= ? AND path < ?))")
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
                // RETURNING 带回 id：FTS 的 rowid 必须和正式表一致。
                let statement = try prepare("""
                INSERT INTO \(table)(path, name, name_folded, name_pinyin, name_initials,
                                     ext, kind, is_directory, size, modified, created, last_used)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    name = excluded.name,
                    name_folded = excluded.name_folded,
                    name_pinyin = excluded.name_pinyin,
                    name_initials = excluded.name_initials,
                    ext = excluded.ext,
                    kind = excluded.kind,
                    is_directory = excluded.is_directory,
                    size = excluded.size,
                    modified = excluded.modified,
                    created = excluded.created,
                    last_used = excluded.last_used
                RETURNING id
                """)
                defer { sqlite3_finalize(statement) }
                let ftsDelete = maintainFTS
                    ? try prepare("DELETE FROM \(Self.ftsTable) WHERE rowid = ?") : nil
                let ftsInsert = maintainFTS
                    ? try prepare("INSERT INTO \(Self.ftsTable)(rowid, name, pinyin, initials)"
                                  + " VALUES(?, ?, ?, ?)") : nil
                defer {
                    if let ftsDelete { sqlite3_finalize(ftsDelete) }
                    if let ftsInsert { sqlite3_finalize(ftsInsert) }
                }
                for entry in upserts {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bindText(entry.path, to: statement, at: 1)
                    try bindText(entry.name, to: statement, at: 2)
                    try bindText(entry.nameFolded, to: statement, at: 3)
                    try bindText(entry.namePinyin, to: statement, at: 4)
                    try bindText(entry.nameInitials, to: statement, at: 5)
                    try bindText(entry.ext, to: statement, at: 6)
                    try bindText(entry.kind, to: statement, at: 7)
                    sqlite3_bind_int(statement, 8, entry.isDirectory ? 1 : 0)
                    if let size = entry.size {
                        sqlite3_bind_int64(statement, 9, size)
                    } else {
                        sqlite3_bind_null(statement, 9)
                    }
                    if let modified = entry.modified {
                        sqlite3_bind_double(statement, 10, modified.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 10)
                    }
                    if let created = entry.created {
                        sqlite3_bind_double(statement, 11, created.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 11)
                    }
                    if let lastUsed = entry.lastUsed {
                        sqlite3_bind_double(statement, 12, lastUsed.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 12)
                    }
                    guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
                    let id = sqlite3_column_int64(statement, 0)
                    if let ftsDelete {
                        sqlite3_reset(ftsDelete)
                        sqlite3_clear_bindings(ftsDelete)
                        sqlite3_bind_int64(ftsDelete, 1, id)
                        guard sqlite3_step(ftsDelete) == SQLITE_DONE else { throw currentError() }
                    }
                    if let ftsInsert {
                        sqlite3_reset(ftsInsert)
                        sqlite3_clear_bindings(ftsInsert)
                        sqlite3_bind_int64(ftsInsert, 1, id)
                        try bindText(entry.nameFolded, to: ftsInsert, at: 2)
                        try bindText(entry.namePinyin, to: ftsInsert, at: 3)
                        try bindText(entry.nameInitials, to: ftsInsert, at: 4)
                        guard sqlite3_step(ftsInsert) == SQLITE_DONE else { throw currentError() }
                    }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func deleteSubtree(_ path: String, maintainFTS: Bool = false) throws {
        try apply(upserts: [], into: Self.liveTable, deleting: [path], maintainFTS: maintainFTS)
    }

    // MARK: 全量重扫的暂存与交换

    /// 重扫先灌暂存表，正式表在扫描期间保持原样可用；崩溃在这里留下的只有暂存表。
    func beginStaging() throws {
        try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
        try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
        try createEntriesTable(Self.stagingTable)
    }

    func stage(_ entries: [FileIndexEntry]) throws {
        try apply(upserts: entries, into: Self.stagingTable, deleting: [], maintainFTS: false)
    }

    /// 交换之前：索引先在暂存表上建好。这 0.6 秒里正式表照常供查询，
    /// 交换事务就只剩两次改名——不再有"每次重扫结尾硬顿一下"。
    func buildStagingIndexes() throws {
        try execute("DROP TABLE IF EXISTS \(Self.retiredTable)")
        try createIndexes(on: Self.stagingTable, names: try freeIndexNames())
    }

    func discardStaging() throws {
        try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
    }

    /// 一次事务里改名 + 落元数据：提交前崩溃 = 旧索引一字未动。
    /// FTS 表在这里清空并标记未就绪：行 id 已经换了一整套，旧 FTS 记录会指向别的文件；
    /// 重建由 FileIndex 在后台补，补完之前包含段回退到 `instr`。
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
            try execute("DROP TABLE IF EXISTS \(Self.ftsTable)")
            try createFTS()
            // 索引本该在交换前就建在暂存表上（跟着改名一起过来）；真缺了这里补上，
            // 别让正式表裸奔到下一次重扫。
            try ensureLiveIndexes()
            for update in updates {
                try setMeta(update.key, value: update.value)
            }
            try setMeta(FileIndexMetaKey.ftsReady, value: nil)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// 旧表腾出的页留在文件里，攒多了整理一次，别把磁盘越用越大。
    /// VACUUM 期间这条连接什么都干不了，所以只由 FileIndex 在空闲窗口调用。
    func reclaimSpaceIfNeeded(minimumFreeBytes: Int64 = 96 * 1024 * 1024) throws -> Int64 {
        let freePages = try scalarInt("PRAGMA freelist_count", values: [])
        let pageSize = try scalarInt("PRAGMA page_size", values: [])
        let freeBytes = Int64(freePages) * Int64(pageSize)
        guard freeBytes > minimumFreeBytes else { return 0 }
        // checkpoint 只是顺手缩小 WAL；读连接恰好在读时会 BUSY，别让它挡住 VACUUM。
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return freeBytes
    }

    // MARK: 子树重扫的暂存与交换

    /// 目录级重扫也不能"先删再扫"：删除一旦提交，扫到一半被杀就永久留下空洞。
    /// 所以同样先灌暂存表，成功后一次事务里用暂存内容顶掉那棵子树。
    func beginStagingSubtree() throws {
        try execute("DROP TABLE IF EXISTS \(Self.stagingTable)")
        try createEntriesTable(Self.stagingTable)
    }

    func publishStagingSubtree(_ path: String, maintainFTS: Bool = false) throws {
        let clean = Self.cleanPath(path)
        try execute("BEGIN IMMEDIATE")
        do {
            if maintainFTS {
                try execute("""
                DELETE FROM \(Self.ftsTable) WHERE rowid IN (
                    SELECT id FROM \(Self.liveTable)
                    WHERE path = ? OR (path >= ? AND path < ?))
                """, values: [clean, clean + "/", clean + "0"])
            }
            try execute("DELETE FROM \(Self.liveTable) WHERE path = ? OR (path >= ? AND path < ?)",
                        values: [clean, clean + "/", clean + "0"])
            try execute("""
            INSERT INTO \(Self.liveTable)(path, name, name_folded, name_pinyin, name_initials,
                                          ext, kind, is_directory, size, modified, created, last_used)
            SELECT path, name, name_folded, name_pinyin, name_initials,
                   ext, kind, is_directory, size, modified, created, last_used
            FROM \(Self.stagingTable)
            """)
            if maintainFTS {
                try execute("""
                INSERT INTO \(Self.ftsTable)(rowid, name, pinyin, initials)
                SELECT id, name_folded, name_pinyin, name_initials FROM \(Self.liveTable)
                WHERE path = ? OR (path >= ? AND path < ?)
                """, values: [clean, clean + "/", clean + "0"])
            }
            try execute("DROP TABLE \(Self.stagingTable)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: FTS 重建

    /// 全量重建 FTS。分块插入，避免一次事务把 WAL 撑到几百 MB；
    /// 中途被取消/崩溃时 `fts_ready` 仍为空，下次启动会从头重建。
    func rebuildFTS() throws {
        try setMeta(FileIndexMetaKey.ftsReady, value: nil)
        try execute("DELETE FROM \(Self.ftsTable)")
        let maxID = try scalarInt("SELECT COALESCE(MAX(id), 0) FROM \(Self.liveTable)", values: [])
        var cursor = 0
        let chunk = 20_000
        while cursor < maxID {
            let upper = cursor + chunk
            try execute("""
            INSERT INTO \(Self.ftsTable)(rowid, name, pinyin, initials)
            SELECT id, name_folded, name_pinyin, name_initials FROM \(Self.liveTable)
            WHERE id > \(cursor) AND id <= \(upper)
            """)
            cursor = upper
        }
        try setMeta(FileIndexMetaKey.ftsReady, value: "1")
    }

    /// 增量维护后 FTS 与正式表的行数应当一致；不一致说明有事务外的写入或上次重建没跑完。
    func ftsRowCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM \(Self.ftsTable)", values: [])
    }

    func markFTSReady(_ ready: Bool) throws {
        try setMeta(FileIndexMetaKey.ftsReady, value: ready ? "1" : nil)
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
    /// 与 UI 单次展示的 300 行对齐：再往上多数一个数字，用户也翻不到第 301 条。
    nonisolated static let countCap = 300

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

    /// `phase == .complete` 保持原有的一次性语义，测试和兜底路径用它；
    /// 主搜索走 `.fast` → `.body` → `.count`，慢段不再挡首屏。
    /// `usingFTS` 由 `FileIndex` 给出：读写两条连接对 FTS 是否就绪必须看同一个事实。
    func query(_ query: FileIndexQuery, phase: FileIndexQueryPhase = .complete,
               usingFTS: Bool = false) throws -> FileIndexQueryResult {
        let interruptible = phase == .body || phase == .count
        if interruptible { storeInterruptibleQueryRunning(true) }
        defer {
            if interruptible { storeInterruptibleQueryRunning(false) }
        }

        let limit = max(query.limit, 0)
        let base = baseFilter(query)
        let rankingIndex = query.syntax.terms.firstIndex {
            !$0.isNegated && $0.kind == .substring && !$0.text.isEmpty
        }

        if phase == .count {
            let count = try cappedCount(fullFilter(query, usingFTS: usingFTS))
            return FileIndexQueryResult(entries: [], total: count.count,
                                        totalIsExact: count.exact, exhausted: true)
        }

        guard limit > 0 else {
            let count = try cappedCount(fullFilter(query, usingFTS: usingFTS))
            return FileIndexQueryResult(entries: [], total: count.count,
                                        totalIsExact: count.exact, exhausted: true)
        }

        // 相关度排序走「分段取」：完全相等 → 前缀 → 其余，三段合起来正好覆盖全部命中，
        // 段内按名字序。前两段顺着 `name_folded` 索引区间走，第三段走 FTS；
        // `.fast` 只跑前两段，命中够了就停。
        if query.sort == .relevance,
           !query.pathSearch, !query.syntax.pathOnly,
           let rankingIndex,
           !query.syntax.terms[rankingIndex].hasWildcard,
           query.syntax.terms[rankingIndex].kind == .substring {
            return try queryRanking(query, base: base, rankingIndex: rankingIndex,
                                    limit: limit, phase: phase, usingFTS: usingFTS)
        }

        return try queryOrdered(query, base: base, limit: limit, phase: phase,
                                usingFTS: usingFTS)
    }

    private func queryRanking(_ query: FileIndexQuery, base: Filter, rankingIndex: Int,
                              limit: Int, phase: FileIndexQueryPhase,
                              usingFTS: Bool) throws -> FileIndexQueryResult {
        let folded = FileIndexText.fold(query.syntax.terms[rankingIndex].text)
        let rest = termFilter(query, skipping: rankingIndex, usingFTS: usingFTS)
        let groups = Self.rankingGroups(folded: folded, phase: phase,
                                        ftsQuery: usingFTS ? ftsMatch(folded) : nil)
        var seen = Set<String>()
        var collected: [FileIndexEntry] = []
        var overflow = false
        for group in groups {
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
        return try makeResult(collected, limit: limit,
                              filter: fullFilter(query, usingFTS: usingFTS),
                              exhausted: exhausted, phase: phase)
    }

    private func queryOrdered(_ query: FileIndexQuery, base: Filter,
                              limit: Int, phase: FileIndexQueryPhase,
                              usingFTS: Bool) throws -> FileIndexQueryResult {
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
        filter.merge(termFilter(query, skipping: nil, usingFTS: usingFTS))
        let rows = try select(filter, order: order, limit: limit + 1)
        let exhausted = rows.count <= limit
        return try makeResult(rows, limit: limit,
                              filter: fullFilter(query, usingFTS: usingFTS),
                              exhausted: exhausted, phase: phase)
    }

    /// 三段排序子句：`name_folded` 上的等值、前缀、包含。
    /// 前缀改用 `GLOB`：`LIKE 'x%' ESCAPE` 在 SQLite 里会退化成全索引 `SCAN`，
    /// `GLOB` 才能让规划器走 `name_folded` 的区间；含 `[` / `]` 的名字由 `globPrefix` 转义。
    /// 包含段有 FTS 时换成 `id IN (SELECT rowid … MATCH ?)`：只取命中 id，再按名字索引回表。
    private static func rankingGroups(folded: String, phase: FileIndexQueryPhase,
                                      ftsQuery: String?) -> [(clause: String, values: [SQLValue])] {
        let contains: (String, [SQLValue])
        if let ftsQuery {
            contains = ("id IN (SELECT rowid FROM \(Self.ftsTable) WHERE \(Self.ftsTable) MATCH ?)",
                        [.text(ftsQuery)])
        } else {
            contains = ("instr(name_folded, ?) > 0", [.text(folded)])
        }
        let groups: [(clause: String, values: [SQLValue])] = [
            ("name_folded = ?", [.text(folded)]),
            ("name_folded GLOB ?", [.text(FileIndexText.globPrefix(folded))]),
            contains,
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

    /// 分类 / 范围 / `in:` / `folder:` `file:` / `ext:` 这些与词无关的过滤。
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
            var values: [String] = []
            for directory in directories {
                let path = Self.cleanPath(directory.path)
                // 子树判定用 path 区间而不是 LIKE：`path` 上有 UNIQUE 索引，
                // 区间能顺着索引走，LIKE 'x/%' 只能逐行比对。
                scopes.append("(path = ? OR (path >= ? AND path < ?))")
                values.append(path)
                values.append(path + "/")
                values.append(path + "0")
            }
            filter.append("(" + scopes.joined(separator: " OR ") + ")",
                          values.map { SQLValue.text($0) })
        }

        // `in:~/Downloads` / `in:"/Volumes/Work"`：目录限定，多个取并集。
        if !query.syntax.scopes.isEmpty {
            var clauses: [String] = []
            var values: [String] = []
            for raw in query.syntax.scopes {
                guard let url = Self.resolveScope(raw) else { continue }
                let path = Self.cleanPath(url.path)
                clauses.append("(path = ? OR (path >= ? AND path < ?))")
                values.append(path)
                values.append(path + "/")
                values.append(path + "0")
            }
            if !clauses.isEmpty {
                filter.append("(" + clauses.joined(separator: " OR ") + ")",
                              values.map { SQLValue.text($0) })
            }
        }
        return filter
    }

    /// 全部词的过滤；`skipping` 用于分段取时把排序那一个词换成段子句。
    private func termFilter(_ query: FileIndexQuery, skipping: Int?,
                            usingFTS: Bool) -> Filter {
        var filter = Filter()
        for (index, term) in query.syntax.terms.enumerated() where index != skipping {
            if term.isNegated {
                let folded = FileIndexText.fold(term.text)
                if term.kind == .wildcard {
                    filter.append("name_folded NOT LIKE ? ESCAPE '\\'",
                                  [.text(FileSearchSyntax.likePattern(for: term))])
                } else {
                    filter.append("instr(name_folded, ?) = 0", [.text(folded)])
                }
                continue
            }
            if term.kind == .wildcard {
                filter.append("name_folded LIKE ? ESCAPE '\\'",
                              [.text(FileSearchSyntax.likePattern(for: term))])
                continue
            }
            if term.kind == .fuzzy {
                // 子序列匹配没法走索引；这是显式 `~` 模式，接受一次全表扫描。
                filter.append("name_folded LIKE ? ESCAPE '\\'",
                              [.text(FileSearchSyntax.fuzzyPattern(for: term))])
                continue
            }
            let folded = FileIndexText.fold(term.text)
            if query.pathSearch || query.syntax.pathOnly {
                // 路径回退/显式 path: 只看完整路径。LIKE 的 ASCII 大小写不敏感，
                // 折叠后的查询词可直接用；CJK 本来就大小写无关。
                filter.append("path LIKE ? ESCAPE '\\'",
                              [.text("%" + FileIndexText.escapeLike(folded) + "%")])
                continue
            }
            // 2 个字符的短词 FTS trigram 给不出结果（会静默变成 0 条），必须回退 instr。
            if usingFTS, folded.count >= 3, let ftsQuery = ftsMatch(folded) {
                filter.append("id IN (SELECT rowid FROM \(Self.ftsTable) WHERE \(Self.ftsTable) MATCH ?)",
                              [.text(ftsQuery)])
                continue
            }
            filter.append("instr(name_folded, ?) > 0", [.text(folded)])
        }
        return filter
    }

    /// 文件名的 FTS 查询串：ASCII 词同时命中拼音全拼与首字母。
    private func ftsMatch(_ folded: String) -> String? {
        guard folded.count >= 3 else { return nil }
        let escaped = folded.replacingOccurrences(of: "\"", with: "\"\"")
        let isASCIIWord = folded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if isASCIIWord {
            return "name:\"\(escaped)\" OR initials:\"\(escaped)\" OR pinyin:\"\(escaped)\""
        }
        return "name:\"\(escaped)\""
    }

    private func fullFilter(_ query: FileIndexQuery, usingFTS: Bool) -> Filter {
        var filter = baseFilter(query)
        filter.merge(termFilter(query, skipping: nil, usingFTS: usingFTS))
        return filter
    }

    /// 正则模式的候选集预筛：用模式里最长的一段字面文本走 FTS/instr，
    /// 再把候选交给调用方用 NSRegularExpression 精筛。没有字面锚点时返回 nil。
    func regexCandidates(_ query: FileIndexQuery, literal: String,
                         cap: Int, usingFTS: Bool) throws -> [FileIndexEntry] {
        var filter = baseFilter(query)
        let folded = FileIndexText.fold(literal)
        if usingFTS, folded.count >= 3 {
            let escaped = folded.replacingOccurrences(of: "\"", with: "\"\"")
            filter.append("id IN (SELECT rowid FROM \(Self.ftsTable) WHERE \(Self.ftsTable) MATCH ?)",
                          [.text("name:\"\(escaped)\"")])
        } else {
            filter.append("instr(name_folded, ?) > 0", [.text(folded)])
        }
        return try select(filter, order: "name_folded ASC, id ASC", limit: cap)
    }

    private func select(_ filter: Filter, order: String, limit: Int) throws -> [FileIndexEntry] {
        let sql = """
        SELECT path, name, name_folded, name_pinyin, name_initials, is_directory,
               ext, kind, size, modified, created, last_used
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

    /// 数命中，但最多数到 `countCap + 1` 就停：索引扫到第 301 个命中即收手。
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
        let size = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 8)
        let modified = sqlite3_column_type(statement, 9) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
        let created = sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        let lastUsed = sqlite3_column_type(statement, 11) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        return FileIndexEntry(rowPath: columnText(statement, 0),
                              name: columnText(statement, 1),
                              nameFolded: columnText(statement, 2),
                              pinyin: columnText(statement, 3),
                              initials: columnText(statement, 4),
                              isDirectory: sqlite3_column_int(statement, 5) != 0,
                              ext: columnText(statement, 6),
                              kind: columnText(statement, 7),
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

    /// `in:` / `path:` 里的作用域写法：`~/x`、`x`（相对主目录）、`/abs`。
    static func resolveScope(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if value == "~" { return home }
        if value.hasPrefix("~/") {
            return home.appendingPathComponent(String(value.dropFirst(2)))
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return home.appendingPathComponent(value)
    }

    private static let schemaVersion: Int32 = 2
}

nonisolated(unsafe) private let fileIndexSQLiteTransient =
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
