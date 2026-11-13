import Foundation
import Observation
import os

public struct AppSearchHit: Identifiable, Sendable {
    public var id: String { app.id }
    public let app: InstalledApp
    public let score: Int
    public let highlight: String?

    public init(app: InstalledApp, score: Int, highlight: String?) {
        self.app = app
        self.score = score
        self.highlight = highlight
    }
}

public struct AppUsageRecord: Codable, Sendable {
    public var launches: Int
    public var lastLaunch: Date

    public init(launches: Int, lastLaunch: Date) {
        self.launches = launches
        self.lastLaunch = lastLaunch
    }
}

@MainActor
@Observable
public final class AppIndex {
    public static let shared = AppIndex()

    public private(set) var apps: [InstalledApp] = []
    public private(set) var isIndexing = false
    public private(set) var hasLoaded = false

    private var aliases: [String: [String]] = [:]
    private var usage: [String: AppUsageRecord] = [:]

    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var startupRescanTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FSEventsDirectoryWatcher?
    @ObservationIgnored private let log = Logger(subsystem: "app.misckit.launcher", category: "appindex")

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        aliases = Self.loadAliases()
        usage = Self.loadUsage()

        if let snapshot = AppSnapshot.load(), !snapshot.isEmpty {
            apps = snapshot
            hasLoaded = true
            debugLog("apps snapshot=\(snapshot.count) deferred-rescan=30s")
            scheduleStartupRescan()
        } else {
            // 没有快照才让界面等首扫；有快照时先放行，别在启动路径上再扫一遍。
            rescan()
        }

        let paths = AppScanner.applicationRoots().map(\.path)
        watcher = FSEventsDirectoryWatcher(paths: paths) { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
    }

    // MARK: 查询

    public func search(_ query: String, limit: Int = 8) -> [AppSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let now = Date()
        var hits: [AppSearchHit] = []

        for app in apps {
            guard let match = AppMatcher.match(query: trimmed, app: app,
                                               aliases: aliases[app.id] ?? [],
                                               usageBoost: usageBoost(for: app.id, now: now))
            else { continue }
            hits.append(AppSearchHit(app: app, score: match.score, highlight: match.highlight))
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let order = lhs.app.name.localizedStandardCompare(rhs.app.name)
            return order == .orderedSame ? lhs.app.url.path < rhs.app.url.path : order == .orderedAscending
        }
        return Array(hits.prefix(limit))
    }

    /// 输入 `app` / `应用` 时给一张常用度排序的入口表。
    public func topApps(limit: Int = 8) -> [AppSearchHit] {
        let now = Date()
        let sorted = apps.sorted { lhs, rhs in
            let leftBoost = usageBoost(for: lhs.id, now: now)
            let rightBoost = usageBoost(for: rhs.id, now: now)
            if leftBoost != rightBoost { return leftBoost > rightBoost }
            let leftCount = usage[lhs.id]?.launches ?? 0
            let rightCount = usage[rhs.id]?.launches ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }
        return sorted.prefix(limit).enumerated().map { offset, app in
            AppSearchHit(app: app, score: max(60, 100 - offset), highlight: nil)
        }
    }

    public func app(withID id: String) -> InstalledApp? {
        apps.first { $0.id == id }
    }

    // MARK: 别名

    public func aliases(for appID: String) -> [String] {
        aliases[appID] ?? []
    }

    public func setAliases(_ values: [String], for appID: String) {
        var seen = Set<String>()
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        aliases[appID] = cleaned.isEmpty ? nil : Array(cleaned.prefix(5))
        Self.saveAliases(aliases)
    }

    // MARK: 常用度

    public func recordLaunch(_ appID: String) {
        var record = usage[appID] ?? AppUsageRecord(launches: 0, lastLaunch: .distantPast)
        record.launches += 1
        record.lastLaunch = Date()
        usage[appID] = record
        Self.saveUsage(usage)
    }

    public func usageBoost(for appID: String, now: Date = Date()) -> Int {
        guard let record = usage[appID], record.launches > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(record.lastLaunch) / 86_400)
        let decayed = Double(record.launches) * exp(-days / 30)
        return min(6, Int(decayed.squareRoot().rounded()))
    }

    // MARK: 索引刷新

    /// 有快照时先放行，启动 30 秒后再在背后补扫一次；期间 FSEvents 先来会取消这次补扫。
    private func scheduleStartupRescan() {
        startupRescanTask?.cancel()
        startupRescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.startupRescanTask = nil
            self.rescan()
        }
    }

    private func rescan() {
        startupRescanTask?.cancel()
        startupRescanTask = nil
        scanTask?.cancel()
        isIndexing = true
        let startedAt = ContinuousClock.now
        scanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                autoreleasepool { AppScanner().scan() }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apps = scanned
            self.hasLoaded = true
            self.isIndexing = false
            self.debugLog("apps indexed=\(scanned.count) elapsed=\(ContinuousClock.now - startedAt)")
            Task.detached(priority: .utility) {
                autoreleasepool { AppSnapshot.save(scanned) }
            }
        }
    }

    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil else { return }
        log.info("\(message, privacy: .public)")
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        #endif
    }

    // MARK: 持久化

    private enum StoreKey {
        static let aliases = "apps.aliases.v1"
        static let usage = "apps.usage.v1"
    }

    private static func loadAliases() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: StoreKey.aliases) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private static func saveAliases(_ value: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: StoreKey.aliases)
    }

    private static func loadUsage() -> [String: AppUsageRecord] {
        guard let data = UserDefaults.standard.data(forKey: StoreKey.usage) else { return [:] }
        return (try? JSONDecoder().decode([String: AppUsageRecord].self, from: data)) ?? [:]
    }

    private static func saveUsage(_ value: [String: AppUsageRecord]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: StoreKey.usage)
    }
}

enum AppSnapshot {
    private static let logger = Logger(subsystem: "app.misckit.launcher", category: "appindex")

    static var fileURL: URL {
        AppStoragePaths.file("apps.json")
    }

    static func load() -> [InstalledApp]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode([InstalledApp].self, from: data)
        } catch {
            logger.info("snapshot decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ apps: [InstalledApp]) {
        do {
            let url = fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(apps)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("snapshot save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
