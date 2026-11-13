import Foundation
import Observation

@MainActor
@Observable
public final class QuicklinkStore {
    public static let shared = QuicklinkStore()

    public static var defaultFileURL: URL {
        AppStoragePaths.file("quicklinks.json")
    }

    public private(set) var links: [Quicklink] = []

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL = QuicklinkStore.defaultFileURL) {
        self.fileURL = fileURL
        links = Self.load(from: fileURL)
    }

    public func link(keyword: String) -> Quicklink? {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return links.first { $0.keyword.lowercased() == key }
    }

    public func browse() -> [Quicklink] { links }

    /// 前缀命中排在包含命中前面；同分保持存储顺序（新加的在后面）。
    public func search(_ term: String) -> [Quicklink] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return links }
        var scored: [(rank: Int, index: Int, link: Quicklink)] = []
        for (index, link) in links.enumerated() {
            var best = 0
            for word in [link.keyword, link.title] {
                let w = word.lowercased()
                if w == q { best = max(best, 100) }
                else if w.hasPrefix(q) { best = max(best, 80) }
                else if w.contains(q) { best = max(best, 60) }
            }
            if best > 0 { scored.append((best, index, link)) }
        }
        scored.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank > rhs.rank
        }
        return scored.map(\.link)
    }

    public func add(_ link: Quicklink) throws {
        var normalized = link
        normalized.keyword = link.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.template = link.template.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(normalized, editing: nil)
        links.append(normalized)
        persist()
    }

    public func update(_ link: Quicklink) throws {
        var normalized = link
        normalized.keyword = link.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.template = link.template.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(normalized, editing: link.id)
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index] = normalized
        persist()
    }

    public func remove(id: UUID) {
        links.removeAll { $0.id == id }
        persist()
    }

    public func validate(_ link: Quicklink, editing: UUID?) throws {
        let keyword = link.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw QuicklinkValidationError.emptyKeyword }
        guard !keyword.contains(where: \.isWhitespace) else {
            throw QuicklinkValidationError.keywordHasWhitespace
        }
        if let other = self.link(keyword: keyword), other.id != editing {
            throw QuicklinkValidationError.duplicateKeyword(other.keyword)
        }
        guard !link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuicklinkValidationError.emptyTitle
        }
        let template = link.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            throw QuicklinkValidationError.invalidTemplate(L10n.Quicklink.Error.templateEmpty)
        }
        guard let url = Quicklink(keyword: keyword, title: link.title, template: template).url(query: "x"),
              let scheme = url.scheme?.lowercased()
        else {
            throw QuicklinkValidationError.invalidTemplate(L10n.Quicklink.Error.templateScheme)
        }
        guard scheme == "http" || scheme == "https" else {
            throw QuicklinkValidationError.invalidTemplate(L10n.Quicklink.Error.templateScheme)
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(links)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MiscKit 网址别名保存失败: %@", error.localizedDescription)
        }
    }

    /// 解不开的 JSON 先留一份 .broken 再当空列表跑：下一次 add 会用新内容覆盖原文件，
    /// 不留备份等于把用户手写的模板直接抹掉。
    private static func load(from url: URL) -> [Quicklink] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let links = try? JSONDecoder().decode([Quicklink].self, from: data) { return links }
        let backup = url.deletingPathExtension().appendingPathExtension("broken.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
        NSLog("MiscKit 网址别名 JSON 解不开，已备份到 %@", backup.path)
        return []
    }
}
