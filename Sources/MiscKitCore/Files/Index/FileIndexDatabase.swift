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
        self.path = path
        self.name = name
        self.nameFolded = FileIndexText.fold(name)
        self.ext = ext
        self.kind = kind
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.lastUsed = lastUsed
    }
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
actor FileIndexDatabase {
    private let url: URL
    // 连接只在 actor 内使用；deinit 需要关闭它，而 deinit 是非隔离的。
    nonisolated(unsafe) private var db: OpaquePointer?

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw FileIndexError.open(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 4000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA temp_store=MEMORY")
        try migrate()
    }

    func close() {
        guard let db else { return }
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

    func query(_ query: FileIndexQuery) throws -> (entries: [FileIndexEntry], total: Int) {
        var clauses: [String] = []
        var values: [SQLValue] = []

        if query.syntax.folderOnly {
            clauses.append("is_directory = 1")
        }
        if query.syntax.fileOnly {
            clauses.append("is_directory = 0")
        }
        if !query.syntax.extensions.isEmpty {
            let placeholders = Array(repeating: "?", count: query.syntax.extensions.count)
                .joined(separator: ",")
            clauses.append("ext IN (\(placeholders))")
            values.append(contentsOf: query.syntax.extensions.map { .text($0) })
        }

        switch query.category {
        case .all:
            break
        case .folder:
            clauses.append("is_directory = 1")
        default:
            clauses.append("kind = ?")
            values.append(.text(query.category.rawValue))
        }

        switch query.scope {
        case .mac:
            break
        case .folders:
            let directories = query.directories.isEmpty
                ? [FileManager.default.homeDirectoryForCurrentUser]
                : query.directories
            var scopes: [String] = []
            for directory in directories {
                let path = Self.cleanPath(directory.path)
                scopes.append("(path = ? OR path LIKE ? ESCAPE '\\')")
                values.append(.text(path))
                values.append(.text(FileIndexText.escapeLike(path) + "/%"))
            }
            clauses.append("(" + scopes.joined(separator: " OR ") + ")")
        }

        for term in query.syntax.terms {
            let pattern = FileSearchSyntax.likePattern(for: term)
            clauses.append(term.isNegated
                ? "name_folded NOT LIKE ? ESCAPE '\\'"
                : "name_folded LIKE ? ESCAPE '\\'")
            values.append(.text(pattern))
        }

        let whereSQL = clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")

        var orderSQL = "name_folded ASC"
        var orderValues: [SQLValue] = []
        // CASE 排序（相关度）没有对应的表达式索引；其余排序都与索引同式。
        var sortCanUseIndex = true
        switch query.sort {
        case .relevance:
            if let first = query.syntax.positiveTerms.first, !first.text.isEmpty {
                if first.hasWildcard {
                    orderSQL = "name_folded ASC"
                } else {
                    let folded = FileIndexText.fold(first.text)
                    orderSQL = """
                    CASE
                        WHEN name_folded = ? THEN 0
                        WHEN name_folded LIKE ? ESCAPE '\\' THEN 1
                        ELSE 2
                    END, name_folded ASC
                    """
                    orderValues.append(.text(folded))
                    orderValues.append(.text(FileIndexText.escapeLike(folded) + "%"))
                    sortCanUseIndex = false
                }
            }
        case .modified:
            orderSQL = "COALESCE(modified, 0) DESC, name_folded ASC"
        case .created:
            orderSQL = "COALESCE(created, 0) DESC, name_folded ASC"
        case .name:
            orderSQL = "name_folded ASC"
        case .size:
            orderSQL = "COALESCE(size, 0) DESC, name_folded ASC"
        }

        let limit = max(query.limit, 0)
        // 排序能走索引时，总数交给标量子查询（覆盖索引），结果按索引顺序取前 N 条：
        // 实测 38.5 万行空查询 293ms→5ms、宽词 138ms→21ms。不能走索引的 relevance CASE
        // 仍用窗口函数，避免两次全扫。
        let sql: String
        if sortCanUseIndex {
            sql = """
            SELECT path, name, is_directory, ext, kind, size, modified, created, last_used,
                   (SELECT COUNT(*) FROM entries WHERE \(whereSQL)) AS total
            FROM entries
            WHERE \(whereSQL)
            ORDER BY \(orderSQL)
            LIMIT ?
            """
        } else {
            sql = """
            SELECT path, name, is_directory, ext, kind, size, modified, created, last_used,
                   COUNT(*) OVER ()
            FROM entries
            WHERE \(whereSQL)
            ORDER BY \(orderSQL)
            LIMIT ?
            """
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        // 标量子查询在 SELECT 列表里，它的 WHERE 占位符排在外部 WHERE 之前。
        let bindValues = sortCanUseIndex ? values + values + orderValues : values + orderValues
        for value in bindValues {
            try bind(value, to: statement, at: bindIndex)
            bindIndex += 1
        }
        sqlite3_bind_int64(statement, bindIndex, Int64(limit))

        var entries: [FileIndexEntry] = []
        entries.reserveCapacity(limit)
        var total = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = columnText(statement, 0)
            let name = columnText(statement, 1)
            let isDirectory = sqlite3_column_int(statement, 2) != 0
            let ext = columnText(statement, 3)
            let kind = columnText(statement, 4)
            let size = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 5)
            let modified = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let created = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let lastUsed = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            total = Int(sqlite3_column_int64(statement, 9))
            entries.append(FileIndexEntry(path: path, name: name, isDirectory: isDirectory,
                                          ext: ext, kind: kind, size: size,
                                          modified: modified, created: created,
                                          lastUsed: lastUsed))
        }
        return (entries, total)
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
