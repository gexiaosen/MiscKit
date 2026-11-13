import Foundation

public struct InstalledApp: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let bundleID: String?
    public let url: URL
    public let name: String
    /// 其它可搜索名字（英文名、文件 stem 等）；显示名单独用 `name`。
    public let searchNames: [String]
    public let compactName: String
    public let compactSearchNames: [String]
    public let pinyin: String
    public let initials: String
    public let isSystem: Bool

    public init(id: String, bundleID: String?, url: URL, name: String, searchNames: [String],
                compactName: String, compactSearchNames: [String], pinyin: String,
                initials: String, isSystem: Bool) {
        self.id = id
        self.bundleID = bundleID
        self.url = url
        self.name = name
        self.searchNames = searchNames
        self.compactName = compactName
        self.compactSearchNames = compactSearchNames
        self.pinyin = pinyin
        self.initials = initials
        self.isSystem = isSystem
    }

    public init(id: String, bundleID: String?, url: URL, name: String,
                searchNames: [String] = [], isSystem: Bool = false) {
        let romanized = AppTextNormalizer.pinyin(for: name)
        var seen = Set<String>()
        let compactName = AppTextNormalizer.compact(name)
        let compactSearchNames = searchNames
            .map(AppTextNormalizer.compact)
            .filter { !$0.isEmpty && $0 != compactName && seen.insert($0).inserted }
        self.init(id: id, bundleID: bundleID, url: url, name: name, searchNames: searchNames,
                  compactName: compactName, compactSearchNames: compactSearchNames,
                  pinyin: romanized.full, initials: romanized.initials, isSystem: isSystem)
    }

    /// 显示用路径：home 下走 `~`，避免每行都顶着一长串 `/Users/...`。
    public var abbreviatedPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

public enum AppTextNormalizer {
    /// 统一大小写与分隔符：`Tencent Meeting`、`tencent-meeting`、`TencentMeeting` 三者可互相命中。
    public static func compact(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    /// 系统自带的普通话拉丁化，省掉一份几千字的拼音表和多音字维护。
    public static func pinyin(for name: String) -> (full: String, initials: String) {
        guard !name.isEmpty else { return ("", "") }
        let transformed = NSMutableString(string: name) as CFMutableString
        CFStringTransform(transformed, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(transformed, nil, kCFStringTransformStripDiacritics, false)
        let tokens = (transformed as String).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var initials = ""
        for token in tokens {
            if let first = token.first { initials.append(first) }
        }
        return (tokens.joined(), initials)
    }
}

public struct AppMatch: Equatable, Sendable {
    public enum Basis: String, Sendable {
        case alias, name, keyword, pinyin, initials
    }

    public let score: Int
    public let highlight: String?
    public let basis: Basis

    public init(score: Int, highlight: String?, basis: Basis) {
        self.score = score
        self.highlight = highlight
        self.basis = basis
    }
}

public enum AppMatcher {
    /// 纯函数，便于单测。别名 > 本地化名称 > 英文名/文件 stem > 拼音 > 首字母。
    public static func match(query: String, app: InstalledApp, aliases: [String],
                             usageBoost: Int = 0) -> AppMatch? {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let q = AppTextNormalizer.compact(raw)
        guard !q.isEmpty else { return nil }

        var bestScore = 0
        var bestBasis: AppMatch.Basis?
        var bestHighlight: String?

        func consider(_ score: Int, _ basis: AppMatch.Basis, highlight: String? = nil) {
            guard score > bestScore else { return }
            bestScore = score
            bestBasis = basis
            bestHighlight = highlight
        }

        for alias in aliases {
            let normalized = AppTextNormalizer.compact(alias)
            guard !normalized.isEmpty else { continue }
            if normalized == q { consider(100, .alias) }
            else if normalized.hasPrefix(q) { consider(88, .alias) }
        }

        let nameHighlight = highlightRange(query: raw, in: app.name)
        if app.compactName == q {
            consider(98, .name, highlight: nameHighlight)
        } else if app.compactName.hasPrefix(q) {
            consider(94, .name, highlight: nameHighlight)
        } else if app.compactName.contains(q) {
            consider(86, .name, highlight: nameHighlight)
        }

        for keyword in app.compactSearchNames where !keyword.isEmpty {
            if keyword == q { consider(96, .keyword) }
            else if keyword.hasPrefix(q) { consider(90, .keyword) }
            else if keyword.contains(q) { consider(80, .keyword) }
        }

        if !app.pinyin.isEmpty {
            if app.pinyin == q { consider(92, .pinyin) }
            else if app.pinyin.hasPrefix(q) { consider(84, .pinyin) }
            else if app.pinyin.contains(q) { consider(78, .pinyin) }
        }

        // 单字母首字母命中会把几乎所有应用都拉进来，至少两个字才算。
        if q.count >= 2, !app.initials.isEmpty {
            if app.initials == q { consider(90, .initials) }
            else if app.initials.hasPrefix(q) { consider(82, .initials) }
        }

        guard let basis = bestBasis else { return nil }
        let boost = min(6, max(0, usageBoost))
        return AppMatch(score: min(100, bestScore + boost), highlight: bestHighlight, basis: basis)
    }

    private static func highlightRange(query: String, in title: String) -> String? {
        guard let range = title.range(of: query,
                                      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
        else { return nil }
        return String(title[range])
    }
}
