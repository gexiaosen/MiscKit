import Foundation

public struct SettingsPaneScanner: Sendable {
    public static let extensionsRoot = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
    private static let pointIdentifier = "com.apple.Settings.extension.ui"
    // 实测 PowerPreferences.appex（电池）的 loctable 每种语言都只有版权串，没有任何显示名，只能手工补。
    private static func localizedOverrideName(for bundleID: String, preferredLanguages: [String]) -> String? {
        guard bundleID == "com.apple.Battery-Settings.extension" else { return nil }
        for lang in preferredLanguages {
            let lower = lang.lowercased()
            if lower.hasPrefix("en") { return "Battery" }
            if lower.hasPrefix("zh") { return "电池" }
        }
        return L10n.Tools.Settings.batteryName
    }

    public static func preferredLanguages(for language: AppLanguage) -> [String] {
        switch language {
        case .system: return Locale.preferredLanguages
        case .en: return ["en"]
        case .zhHans: return ["zh-Hans", "zh_CN"]
        }
    }
    // 电池包里的 icon.icns 是一张占位的白纸，NSWorkspace 取到的就是它。
    // 包里其实声明了 ISSymbolName = bolt.fill（挂在 UTExportedTypeDeclarations 下），用它画。
    private static let iconOverrides = ["com.apple.Battery-Settings.extension": "battery.100"]

    private let root: URL
    private let cache: any SettingsPaneCaching
    private let preferredLanguages: [String]

    public init(root: URL = SettingsPaneScanner.extensionsRoot,
                cache: any SettingsPaneCaching = SettingsPaneFileCache(),
                preferredLanguages: [String] = Locale.preferredLanguages) {
        self.root = root
        self.cache = cache
        self.preferredLanguages = preferredLanguages
    }

    public func scan() -> [SettingsPane] {
        let key = cacheKey()
        if let key, let cached = cache.load(key: key) { return cached }
        let panes = scanDisk()
        if let key { cache.save(panes, key: key) }
        return panes
    }

    // 语言偏好拼进缓存键：切换系统语言不会动目录 mtime，但显示名与索引词要跟着换。
    // 必须走 attributesOfItem：`URL.resourceValues` 会把 mtime 缓存在 URL 对象上，
    // 常驻的 scanner 因此永远拿到第一次的键，系统更新后设置列表再也不刷新（实测复现）。
    // 前缀是缓存结构版本：`SettingsPane` 加了字段就得换它，否则旧 JSON 解出来是缺字段的。
    private static let cacheSchema = "v3"

    private func cacheKey() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(Self.cacheSchema)|\(modified.timeIntervalSince1970)|\(preferredLanguages.joined(separator: ","))"
    }

    private func scanDisk() -> [SettingsPane] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var panes: [SettingsPane] = []
        for name in names.sorted() where name.hasSuffix(".appex") {
            let url = root.appendingPathComponent(name)
            if let pane = autoreleasepool(invoking: { Self.makePane(at: url, preferredLanguages: preferredLanguages) }) {
                panes.append(pane)
            }
        }
        return panes.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private static func makePane(at url: URL, preferredLanguages: [String]) -> SettingsPane? {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        guard let info = plist(at: contents.appendingPathComponent("Info.plist")) else { return nil }
        let ex = info["EXAppExtensionAttributes"] as? [String: Any] ?? [:]
        let ns = info["NSExtension"] as? [String: Any] ?? [:]
        guard (ex["EXExtensionPointIdentifier"] as? String) == pointIdentifier
                || (ns["NSExtensionPointIdentifier"] as? String) == pointIdentifier
        else { return nil }
        guard let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
              let openURL = URL(string: "x-apple.systempreferences:" + id)
        else { return nil }

        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let loctable = plist(at: resources.appendingPathComponent("InfoPlist.loctable")) ?? [:]
        guard let resolved = resolveName(loctable: loctable, bundleID: id,
                                         preferredLanguages: preferredLanguages)
        else { return nil }

        // searchTermsFileName 不在 Info.plist 顶层，实测藏在 EXAppExtensionAttributes.SettingsExtensionAttributes 里。
        let attributes = ex["SettingsExtensionAttributes"] as? [String: Any] ?? [:]
        let terms = searchTerms(resources: resources,
                                fileName: attributes["searchTermsFileName"] as? String,
                                language: resolved.language)
        // 52/53 面板自己声明了 allowsXAppleSystemPreferencesURLScheme，但 URL 路由没实机点击核实过。
        return SettingsPane(id: id, name: resolved.name, subtitle: terms.subtitle,
                            matchTerms: terms.words, url: openURL, appexPath: url.path,
                            iconSymbol: iconOverrides[id])
    }

    // 实测：中文名在 InfoPlist.loctable 的 zh_CN 键下，zh_CN.lproj/InfoPlist.strings 不存在，Info.plist 的名是内部代号。
    private static func resolveName(loctable: [String: Any], bundleID: String,
                                    preferredLanguages: [String]) -> (name: String, language: String?)? {
        var candidates: [String: String] = [:]
        for (key, value) in loctable {
            guard let strings = value as? [String: Any] else { continue }
            let name = (strings["CFBundleDisplayName"] as? String) ?? (strings["CFBundleName"] as? String)
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            candidates[key] = name
        }
        // 链尾追加 en：用户语言没匹配上时退英文；loctable 常只有 en_GB 等变体，Bundle 会自己挑。
        let matched = Bundle.preferredLocalizations(from: candidates.keys.sorted(),
                                                    forPreferences: preferredLanguages + ["en"])
        for language in matched {
            if let name = candidates[language] { return (name, language) }
        }
        if let override = localizedOverrideName(for: bundleID, preferredLanguages: preferredLanguages) {
            return (override, nil)
        }
        return nil
    }

    // 文件顶层是 { 分区键: { localizableStrings: [ {title, index} ] } }，分区键由各面板自取
    // （Main / volume / Network / Password …）。只认 Main 会让 24 个带索引词的面板里 22 个变成空词。
    // 收显示语言 + zh_CN + en 三份并集：zh_CN 文件里本来就混着英文词，系统语言非中文时「耳机」也要能命中蓝牙。
    private static func searchTerms(resources: URL, fileName: String?,
                                    language: String?) -> (words: [String], subtitle: String?) {
        guard let fileName, !fileName.isEmpty else { return ([], nil) }
        var languages: [String] = []
        for candidate in [language, "zh_CN", "en"] {
            if let candidate, !languages.contains(candidate) { languages.append(candidate) }
        }
        var words: [String] = []
        var seen = Set<String>()
        var subtitle: String?
        for lang in languages {
            let url = resources.appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("\(fileName).searchTerms")
            guard let dict = plist(at: url) else { continue }
            // 子标题只认 Main：别的分区名是「提醒和声音效果」这类小节标题，当面板副标题会误导。
            if subtitle == nil, let main = dict["Main"] as? [String: Any],
               let entries = main["localizableStrings"] as? [[String: Any]] {
                subtitle = entries.first { entry in
                    guard let title = entry["title"] as? String else { return false }
                    return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }?["title"] as? String
            }
            for section in dict.keys.sorted() {
                guard let entries = (dict[section] as? [String: Any])?["localizableStrings"] as? [[String: Any]]
                else { continue }
                for entry in entries {
                    guard let index = entry["index"] as? String else { continue }
                    for word in index.split(separator: ",") {
                        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
                        words.append(term)
                    }
                }
            }
        }
        return (words, subtitle)
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return value as? [String: Any]
    }
}