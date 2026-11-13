import Foundation

public struct AppScanner: Sendable {
    public init() {}

    public static func applicationRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]

        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey],
                                           options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard volume.path != "/" else { continue }
            guard let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey]),
                  values.volumeIsLocal == true, values.volumeIsBrowsable == true
            else { continue }
            candidates.append(volume.appendingPathComponent("Applications"))
        }

        var seen = Set<String>()
        return candidates.filter { url in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return false }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    public func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var found: [InstalledApp] = []
        var seenPaths = Set<String>()

        for root in Self.applicationRoots() {
            // enumerator 与 URL 版 contentsOfDirectory 都会静默丢掉"指向目录的符号链接"
            // （实测：/Applications 103 项里只有字符串版能看见 Safari.app，它指向 Cryptexes）。
            // 根目录这一层用字符串版单独扫一遍，符号链接形式的系统应用才不会整只漏掉。
            let directNames = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for name in directNames where name.lowercased().hasSuffix(".app") {
                let url = root.appendingPathComponent(name)
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                if let app = autoreleasepool(invoking: { Self.makeApp(at: url) }) {
                    found.append(app)
                }
            }

            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                // Bundle / InfoPlist.strings 会产生大量 autoreleased 对象，逐个回收避免常驻。
                if let app = autoreleasepool(invoking: { Self.makeApp(at: url) }) {
                    found.append(app)
                }
            }
        }

        return Self.dedupe(found, home: fm.homeDirectoryForCurrentUser.path)
    }

    /// 同 bundleId 多副本（外置盘、备份目录）只保留一份；系统位次见 `pathRank`。
    public static func dedupe(_ apps: [InstalledApp], home: String) -> [InstalledApp] {
        var best: [String: InstalledApp] = [:]
        for app in apps {
            let key = app.bundleID.map { "id:\($0)" } ?? "path:\(app.url.standardizedFileURL.path)"
            guard let existing = best[key] else {
                best[key] = app
                continue
            }
            let newRank = pathRank(app.url.path, home: home)
            let oldRank = pathRank(existing.url.path, home: home)
            if newRank < oldRank || (newRank == oldRank && app.url.path.count < existing.url.path.count) {
                best[key] = app
            }
        }
        return best.values.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }
    }

    public static func pathRank(_ path: String, home: String) -> Int {
        let homeApps = home.hasSuffix("/") ? home + "Applications/" : home + "/Applications/"
        if path.hasPrefix("/Applications/") { return 0 }
        if path.hasPrefix(homeApps) { return 1 }
        if path.hasPrefix("/System/") { return 2 }
        if path.hasPrefix("/Volumes/") { return 3 }
        return 4
    }

    // MARK: 单个应用

    /// 不构造 `Bundle`：CFBundle 会按 URL 全局缓存，181 个应用常驻约 18 MB。
    /// 直接读 Info.plist 与 `<lang>.lproj/InfoPlist.strings`，退出后内存可完全回收。
    private static func makeApp(at url: URL) -> InstalledApp? {
        guard let layout = layout(at: url) else { return nil }
        let info = layout.info
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let names = candidateNames(url: url, resources: layout.resources, info: info)
        guard let displayName = names.first else { return nil }

        return InstalledApp(id: bundleID ?? url.standardizedFileURL.path,
                            bundleID: bundleID,
                            url: url.standardizedFileURL,
                            name: displayName,
                            searchNames: Array(names.dropFirst()),
                            isSystem: url.path.hasPrefix("/System/"))
    }

    private struct Layout {
        let info: [String: Any]
        let resources: URL
    }

    /// 三种布局：标准 macOS（`Contents/Info.plist`）、包装内层、扁平包（iOS 应用，Info.plist 在包根）。
    private static func layout(at url: URL) -> Layout? {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        if let info = infoPlist(at: contents) {
            return Layout(info: info, resources: contents.appendingPathComponent("Resources", isDirectory: true))
        }
        if let inner = wrappedBundle(at: url) {
            let innerContents = inner.appendingPathComponent("Contents", isDirectory: true)
            if let info = infoPlist(at: innerContents) {
                return Layout(info: info, resources: innerContents.appendingPathComponent("Resources", isDirectory: true))
            }
            if let info = infoPlist(at: inner) {
                return Layout(info: info, resources: inner)
            }
        }
        if let info = infoPlist(at: url) {
            return Layout(info: info, resources: url)
        }
        return nil
    }

    /// iOS 应用经 App Store 装到 Apple Silicon 时是原位包装：外层 `X.app/WrappedBundle` 指向内层真实包，
    /// 外层没有 `Contents/Info.plist`。`Bundle(url:)` 会自动穿透，直接读 plist 则必须手动跟进。
    private static func wrappedBundle(at url: URL) -> URL? {
        let link = url.appendingPathComponent("WrappedBundle")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory) else { return nil }
        let resolved = link.resolvingSymlinksInPath()
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        return resolved
    }

    private static func infoPlist(at contents: URL) -> [String: Any]? {
        let url = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    /// 腾讯会议的 `CFBundleDisplayName` 是 `TencentMeeting`，中文名在 `zh-Hans/InfoPlist.strings`。
    /// 所以必须按当前语言偏好读本地化包，不能只看 Info.plist。
    ///
    /// 系统自带应用又是另一种情况：名字根本不在包里（Notes.app 的 `zh_CN.lproj` 只有一份
    /// 声明 RTF，没有 InfoPlist.strings），Finder 与 Spotlight 显示名「备忘录」来自系统索引。
    /// 所以优先取 Spotlight 的 `kMDItemDisplayName`，它才是用户认得的名字；
    /// 索引没开/未收录时返回 nil，回落到包内本地化与文件名。
    private static func spotlightName(for url: URL) -> String? {
        guard let value = NSMetadataItem(url: url)?
            .value(forAttribute: "kMDItemDisplayName") as? String else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 元数据里的显示名不该带扩展名；带了的当没取到，别把 "X.app" 拼进候选
        return name.isEmpty || name.hasSuffix(".app") ? nil : name
    }

    private static func candidateNames(url: URL, resources: URL, info: [String: Any]) -> [String] {
        var raw: [String] = []
        if let spotlight = spotlightName(for: url) { raw.append(spotlight) }
        let available = localizations(in: resources, info: info)
        let preferred = Bundle.preferredLocalizations(from: available,
                                                      forPreferences: Locale.preferredLanguages)
        if let language = preferred.first,
           let name = localizedName(resources: resources, localization: language) {
            raw.append(name)
        }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info[key] as? String { raw.append(name) }
        }
        if !preferred.contains("en"), let name = localizedName(resources: resources, localization: "en") {
            raw.append(name)
        }

        raw.append(url.deletingPathExtension().lastPathComponent)

        var seen = Set<String>()
        return raw.compactMap { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    private static func localizations(in resources: URL, info: [String: Any]) -> [String] {
        var names = Set(info["CFBundleLocalizations"] as? [String] ?? [])
        if let entries = try? FileManager.default.contentsOfDirectory(at: resources,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles]) {
            for entry in entries where entry.pathExtension == "lproj" {
                names.insert(entry.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted()
    }

    private static func localizedName(resources: URL, localization: String) -> String? {
        let url = resources
            .appendingPathComponent("\(localization).lproj", isDirectory: true)
            .appendingPathComponent("InfoPlist.strings")
        guard let data = try? Data(contentsOf: url),
              let strings = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                  as? [String: Any]
        else { return nil }

        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = strings[key] as? String, !name.isEmpty { return name }
        }
        return nil
    }
}
