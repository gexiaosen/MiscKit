import Foundation

// MARK: - 查询解析

public enum FileQuery: Equatable, Sendable {
    case none
    /// 只输入了 `file` / `文件`，等待用户继续输入
    case browse
    case search(term: String)
    case path(PathQuery)
}

public struct PathQuery: Equatable, Sendable {
    public let url: URL
    /// 尾斜杠：列出目录子项而不是只返回目录本身
    public let listsChildren: Bool
    public let exists: Bool

    public init(url: URL, listsChildren: Bool, exists: Bool) {
        self.url = url
        self.listsChildren = listsChildren
        self.exists = exists
    }
}

/// 关键词触发 + 路径直达的纯解析器。路径永远优先于模糊搜索。
public struct FileQueryParser: Sendable {
    private static let keywords: Set<String> = ["file", "文件", "wenjian"]
    private let home: URL
    private let volumes: [URL]
    private let aliases: [String: URL]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                volumes: [URL]? = nil,
                aliases: [String: URL] = [:]) {
        self.home = home.standardizedFileURL
        self.volumes = volumes ?? Self.defaultVolumes()
        self.aliases = aliases
    }

    public func parse(_ raw: String) -> FileQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        var body = trimmed
        var usedKeyword = false
        if let rest = Self.stripKeyword(trimmed) {
            usedKeyword = true
            body = rest
        }
        guard !body.isEmpty else { return usedKeyword ? .browse : .none }

        if let aliasURL = alias(matching: body) {
            return .path(PathQuery(url: clean(aliasURL), listsChildren: false,
                                   exists: fileExists(aliasURL)))
        }
        if let query = volumePath(body) { return .path(query) }
        if isPathLike(body) {
            let url = expand(body)
            return .path(PathQuery(url: clean(url), listsChildren: body.hasSuffix("/"),
                                   exists: fileExists(url)))
        }
        return .search(term: body)
    }

    /// 面板据此决定是否切到文件搜索布局；普通应用查询不应被当成文件搜索。
    public func isFileMode(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if Self.stripKeyword(trimmed) != nil { return true }
        if case .path = parse(trimmed) { return true }
        return false
    }

    /// `file 报价` → `报价`；`文件` → 空串；普通查询返回 nil。
    private static func stripKeyword(_ text: String) -> String? {
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let head = parts.first, keywords.contains(head.lowercased()) else { return nil }
        return parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    }

    private func alias(matching term: String) -> URL? {
        let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for (name, url) in aliases where
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key {
            return url
        }
        return nil
    }

    private func volumePath(_ body: String) -> PathQuery? {
        for volume in volumes.sorted(by: { $0.path.count > $1.path.count }) {
            let name = volume.lastPathComponent
            guard !name.isEmpty else { continue }
            if body.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return PathQuery(url: clean(volume), listsChildren: false, exists: true)
            }
            let prefix = name + "/"
            guard body.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let tail = String(body.dropFirst(prefix.count))
            let url = tail.isEmpty ? volume : volume.appendingPathComponent(tail)
            return PathQuery(url: clean(url), listsChildren: tail.isEmpty || body.hasSuffix("/"),
                             exists: fileExists(url))
        }
        return nil
    }

    private func isPathLike(_ body: String) -> Bool {
        body == "~" || body.hasPrefix("~/") || body.hasPrefix("/") || body.contains("/")
    }

    private func expand(_ body: String) -> URL {
        if body == "~" { return home }
        if body.hasPrefix("~/") {
            return home.appendingPathComponent(String(body.dropFirst(2)))
        }
        if body.hasPrefix("/") {
            return URL(fileURLWithPath: body)
        }
        // 相对路径按用户主目录解析，避免误走 Spotlight
        return home.appendingPathComponent(body)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 去掉尾斜杠，路径等价比较更稳定；是否需要列子项由 `listsChildren` 单独表达。
    private func clean(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    private static func defaultVolumes() -> [URL] {
        var result: [URL] = []
        let root = URL(fileURLWithPath: "/")
        if let name = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName,
           !name.isEmpty {
            result.append(root)
        }
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsLocalKey],
            options: [.skipHiddenVolumes]) ?? []
        for url in mounted where url.path != "/" {
            guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey]),
                  values.volumeIsLocal == true, values.volumeIsBrowsable == true
            else { continue }
            result.append(url)
        }
        return result
    }
}

// MARK: - 类型筛选

public enum FileCategory: String, CaseIterable, Identifiable, Sendable {
    case all, image, audio, video, pdf, word, excel, ppt, folder

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return L10n.Files.Category.all
        case .image: return L10n.Files.Category.image
        case .audio: return L10n.Files.Category.audio
        case .video: return L10n.Files.Category.video
        case .pdf: return "PDF"
        case .word: return "WORD"
        case .excel: return "EXCEL"
        case .ppt: return "PPT"
        case .folder: return L10n.Files.Category.folder
        }
    }

    /// `folder` 不是类型树判断，单独走 isDirectory。
    public var contentTypeTree: [String] {
        switch self {
        case .all, .folder: return []
        case .image: return ["public.image"]
        case .audio: return ["public.audio"]
        case .video: return ["public.movie", "public.video"]
        case .pdf: return ["com.adobe.pdf"]
        case .word:
            return ["org.openxmlformats.wordprocessingml.document",
                    "com.microsoft.word.doc",
                    "public.word-processing-document"]
        case .excel:
            return ["org.openxmlformats.spreadsheetml.sheet",
                    "com.microsoft.excel.xls",
                    "public.spreadsheet"]
        case .ppt:
            return ["org.openxmlformats.presentationml.presentation",
                    "com.microsoft.powerpoint.ppt",
                    "public.presentation"]
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .all, .folder, .image, .audio, .video, .pdf: return []
        case .word: return ["doc", "docx", "docm", "dot", "dotx"]
        case .excel: return ["xls", "xlsx", "xlsm", "xlsb"]
        case .ppt: return ["ppt", "pptx", "pptm", "pps", "ppsx"]
        }
    }

    public func matches(_ item: FileItem) -> Bool {
        switch self {
        case .all: return true
        case .folder: return item.isDirectory
        default:
            if item.contentTypeTree.contains(where: { contentTypeTree.contains($0) }) { return true }
            let ext = item.url.pathExtension.lowercased()
            return !ext.isEmpty && fileExtensions.contains(ext)
        }
    }
}

// MARK: - 排序与范围

public enum FileSort: String, CaseIterable, Identifiable, Sendable {
    case relevance, modified, created, name, size

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .relevance: return L10n.Files.Sort.relevance
        case .modified: return L10n.Files.Sort.modified
        case .created: return L10n.Files.Sort.created
        case .name: return L10n.Files.Sort.name
        case .size: return L10n.Files.Sort.size
        }
    }
}

public enum FileScope: String, CaseIterable, Identifiable, Sendable {
    case mac, folders

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mac: return L10n.Files.Scope.mac
        case .folders: return L10n.Files.Scope.specifiedFolders
        }
    }
}

// MARK: - 结果模型

public enum FileOrigin: String, Sendable {
    case spotlight, index, path, hidden, pinned, recent, alias
}

public struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let contentType: String?
    public let contentTypeTree: [String]
    public let creationDate: Date?
    public let modificationDate: Date?
    public let lastUsedDate: Date?
    public let fileSize: Int64?
    public let isUbiquitous: Bool
    public let isDownloaded: Bool
    public let origin: FileOrigin

    public var id: String { url.standardizedFileURL.path }
    public var name: String { url.lastPathComponent }
    public var needsDownload: Bool { isUbiquitous && !isDownloaded }

    public init(url: URL, isDirectory: Bool, contentType: String? = nil,
                contentTypeTree: [String] = [], creationDate: Date? = nil,
                modificationDate: Date? = nil, lastUsedDate: Date? = nil,
                fileSize: Int64? = nil, isUbiquitous: Bool = false,
                isDownloaded: Bool = true, origin: FileOrigin = .spotlight) {
        self.url = url
        self.isDirectory = isDirectory
        self.contentType = contentType
        self.contentTypeTree = contentTypeTree
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.lastUsedDate = lastUsedDate
        self.fileSize = fileSize
        self.isUbiquitous = isUbiquitous
        self.isDownloaded = isDownloaded
        self.origin = origin
    }
}

/// 计数语义：`total` 是实际命中总数，`displayed` 是渲染出的行数。
public struct FileSearchResponse: Sendable {
    public let items: [FileItem]
    public let total: Int
    public let isTruncated: Bool
    /// 命中数超过计数上限时 `total` 只是下界，界面显示「1000+」而不是一个精确数字。
    public let totalIsExact: Bool
    public let notice: String?
    public let isSpotlightAvailable: Bool

    public init(items: [FileItem], total: Int, isTruncated: Bool,
                totalIsExact: Bool = true,
                notice: String? = nil, isSpotlightAvailable: Bool = true) {
        self.items = items
        self.total = total
        self.isTruncated = isTruncated
        self.totalIsExact = totalIsExact
        self.notice = notice
        self.isSpotlightAvailable = isSpotlightAvailable
    }

    public var countText: String {
        if isTruncated {
            return totalIsExact
                ? L10n.Files.Count.truncated(total, items.count)
                : L10n.Files.Count.many(total, items.count)
        }
        return L10n.Files.Count.exact(total)
    }
}

public enum FilePathDisplay {
    /// 展示用路径：主目录归一化成 `~`，其余保持绝对路径。
    public static func abbreviated(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }
}
