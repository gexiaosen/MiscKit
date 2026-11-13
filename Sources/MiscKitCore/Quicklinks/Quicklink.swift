import Foundation

/// 一条自己存的网址模板。`{q}` 是占位符，回车时把输入框里的词 percent-encode 后填进去。
public struct Quicklink: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var keyword: String
    public var title: String
    public var template: String

    public init(id: UUID = UUID(), keyword: String, title: String, template: String) {
        self.id = id
        self.keyword = keyword
        self.title = title
        self.template = template
    }

    public var takesQuery: Bool { template.contains("{q}") }

    /// 模板只准 http / https：别的 scheme（javascript:、data:、file:）在回车那一刻就是执行或读盘。
    public func url(query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? ""
        let filled = template.replacingOccurrences(of: "{q}", with: encoded)
        guard let url = URL(string: filled),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    /// `urlQueryAllowed` 里还留着 `&` `=` `?` `+` `#` `/` —— 搜 `a&b=c` 会被当成多一个参数，
    /// 所以把它们从“可以原样出现”里摘掉，让上面的 percent-encode 接管。
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+#/;,")
        return set
    }()
}

public enum QuicklinkValidationError: Error, LocalizedError, Equatable {
    case emptyKeyword
    case keywordHasWhitespace
    case duplicateKeyword(String)
    case emptyTitle
    case invalidTemplate(String)

    public var errorDescription: String? {
        switch self {
        case .emptyKeyword: return L10n.Quicklink.Error.emptyKeyword
        case .keywordHasWhitespace: return L10n.Quicklink.Error.keywordWhitespace
        case .duplicateKeyword(let keyword): return L10n.Quicklink.Error.duplicateKeyword(keyword)
        case .emptyTitle: return L10n.Quicklink.Error.emptyTitle
        case .invalidTemplate(let reason): return L10n.Quicklink.Error.invalidTemplate(reason)
        }
    }
}
