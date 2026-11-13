import Foundation

/// Application Support 的单一路径真源：按 bundle identity 分目录，
/// 让 Release (`MiscKit`)、Dev (`MiscKit-Dev`) 与 CLI (`MiscKit-CLI`) 的单例锁、
/// 应用快照、文件索引、设置缓存、hosts 状态/备份与网址别名互不踩踏。
public enum AppStoragePaths {
    public static func directoryName(forBundleID id: String?) -> String {
        guard let id, !id.isEmpty else { return "MiscKit-CLI" }
        if id == "com.apple.dt.xctest.tool" { return "MiscKit-CLI" }
        return id.hasSuffix(".dev") ? "MiscKit-Dev" : "MiscKit"
    }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(directoryName(forBundleID: Bundle.main.bundleIdentifier),
                                           isDirectory: true)
    }

    public static func file(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name, isDirectory: false)
    }

    public static func subdirectory(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name, isDirectory: true)
    }
}
