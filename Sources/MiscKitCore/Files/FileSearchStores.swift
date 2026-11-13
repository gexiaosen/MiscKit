import Foundation
import Observation

public enum FileViewMode: String, CaseIterable, Sendable {
    case list, split
}

/// 文件搜索的持久化偏好：范围与排序必须记忆。
@MainActor
@Observable
public final class FileSearchSettings {
    public static let shared = FileSearchSettings()

    public var scope: FileScope {
        didSet { defaults.set(scope.rawValue, forKey: Key.scope) }
    }
    public var sort: FileSort {
        didSet { defaults.set(sort.rawValue, forKey: Key.sort) }
    }
    public var directories: [URL] {
        didSet { persistPaths(directories, key: Key.directories) }
    }
    public var viewMode: FileViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scope = FileScope(rawValue: defaults.string(forKey: Key.scope) ?? "") ?? .mac
        sort = FileSort(rawValue: defaults.string(forKey: Key.sort) ?? "") ?? .relevance
        directories = Self.paths(forKey: Key.directories, defaults: defaults)
        viewMode = FileViewMode(rawValue: defaults.string(forKey: Key.viewMode) ?? "") ?? .split
    }

    public func addDirectory(_ url: URL) {
        guard !directories.contains(where: { $0.path == url.path }) else { return }
        directories.append(url)
    }

    public func removeDirectory(_ url: URL) {
        directories.removeAll { $0.path == url.path }
        if directories.isEmpty { scope = .mac }
    }

    private func persistPaths(_ urls: [URL], key: String) {
        defaults.set(urls.map(\.path), forKey: key)
    }

    private static func paths(forKey key: String, defaults: UserDefaults) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    private enum Key {
        static let scope = "file.scope.v1"
        static let sort = "file.sort.v1"
        static let directories = "file.directories.v1"
        static let viewMode = "file.viewMode.v1"
    }
}

/// 固定与最近打开：固定优先，最近按时间倒序且去重。
@MainActor
@Observable
public final class FileHistoryStore {
    public static let shared = FileHistoryStore()
    public private(set) var pins: [URL]
    public private(set) var recents: [URL]

    private let defaults: UserDefaults
    private let maxRecents = 9

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = Self.load(key: Key.pins, defaults: defaults)
        recents = Self.load(key: Key.recents, defaults: defaults)
        pruneMissing()
    }

    public func recordOpen(_ url: URL) {
        let clean = URL(fileURLWithPath: url.standardizedFileURL.path)
        recents.removeAll { $0.path == clean.path }
        recents.insert(clean, at: 0)
        if recents.count > maxRecents { recents.removeLast(recents.count - maxRecents) }
        save()
    }

    public func togglePin(_ url: URL) {
        let clean = URL(fileURLWithPath: url.standardizedFileURL.path)
        if let index = pins.firstIndex(where: { $0.path == clean.path }) {
            pins.remove(at: index)
        } else {
            pins.insert(clean, at: 0)
        }
        save()
    }

    public func isPinned(_ url: URL) -> Bool {
        pins.contains { $0.path == url.standardizedFileURL.path }
    }

    /// 空查询时的候选：固定 + 最近，路径去重。
    public func candidates() -> [(url: URL, origin: FileOrigin)] {
        var seen = Set<String>()
        var out: [(URL, FileOrigin)] = []
        for url in pins where seen.insert(url.path).inserted { out.append((url, .pinned)) }
        for url in recents where seen.insert(url.path).inserted { out.append((url, .recent)) }
        return out
    }

    private func pruneMissing() {
        let fm = FileManager.default
        pins.removeAll { !fm.fileExists(atPath: $0.path) }
        recents.removeAll { !fm.fileExists(atPath: $0.path) }
        save()
    }

    private func save() {
        defaults.set(pins.map(\.path), forKey: Key.pins)
        defaults.set(recents.map(\.path), forKey: Key.recents)
    }

    private static func load(key: String, defaults: UserDefaults) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    private enum Key {
        static let pins = "file.pins.v1"
        static let recents = "file.recents.v1"
    }
}

/// 目录别名：`报价` → 指定目录。别名精确命中时优先于 Spotlight。
@MainActor
@Observable
public final class FileAliasStore {
    public static let shared = FileAliasStore()
    public private(set) var aliases: [String: URL]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: URL] = [:]
        for (name, path) in defaults.dictionary(forKey: Key.aliases) as? [String: String] ?? [:] {
            loaded[name] = URL(fileURLWithPath: path)
        }
        aliases = loaded
    }

    public func set(_ name: String, for url: URL) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        aliases[clean] = URL(fileURLWithPath: url.standardizedFileURL.path)
        save()
    }

    public func remove(_ name: String) {
        aliases[name] = nil
        save()
    }

    public func alias(for url: URL) -> String? {
        aliases.first { $0.value.path == url.standardizedFileURL.path }?.key
    }

    private func save() {
        defaults.set(aliases.mapValues(\.path), forKey: Key.aliases)
    }

    private enum Key {
        static let aliases = "file.aliases.v1"
    }
}
