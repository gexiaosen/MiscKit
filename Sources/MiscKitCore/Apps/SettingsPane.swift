import Foundation

public struct SettingsPane: Codable, Hashable, Identifiable, Sendable {
    /// CFBundleIdentifier，打开 URL 也用它拼。
    public let id: String
    public let name: String
    /// Apple 索引词文件里的第一个 title（显示语言），如「蓝牙设备」。
    public let subtitle: String?
    public let matchTerms: [String]
    public let url: URL
    /// `.appex` 包的路径。系统设置里那个彩色图标就长在包里，结果行直接复用它。
    public let appexPath: String?
    /// 包里自带图标是坏的（占位图）时，改用这个 SF Symbol。
    public let iconSymbol: String?

    public init(id: String, name: String, subtitle: String?, matchTerms: [String],
                url: URL, appexPath: String? = nil, iconSymbol: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.matchTerms = matchTerms
        self.url = url
        self.appexPath = appexPath
        self.iconSymbol = iconSymbol
    }
}

public protocol SettingsPaneCaching: Sendable {
    func load(key: String) -> [SettingsPane]?
    func save(_ panes: [SettingsPane], key: String)
}

public struct SettingsPaneFileCache: SettingsPaneCaching {
    private struct Snapshot: Codable {
        let key: String
        let panes: [SettingsPane]
    }

    private let fileURL: URL

    public init(fileURL: URL = SettingsPaneFileCache.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        AppStoragePaths.file("settings-panes.json")
    }

    public func load(key: String) -> [SettingsPane]? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.key == key
        else { return nil }
        return snapshot.panes
    }

    public func save(_ panes: [SettingsPane], key: String) {
        guard let data = try? JSONEncoder().encode(Snapshot(key: key, panes: panes)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}