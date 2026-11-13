import Foundation

@MainActor
public struct QuicklinkTool: Tool {
    public init() {}
    public let id = ToolID.quicklink
    public var title: String { L10n.Tools.Quicklink.title }
    public let symbol = "link"
    public let capabilities: Set<Capability> = []
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "quicklink", title: L10n.Tools.Quicklink.label,
                              kind: .keyword(["quicklink", "ql", "网址", "wangzhi"])),
            TriggerDescriptor(code: "quicklink-any", title: L10n.Tools.Quicklink.label,
                              kind: .text(label: L10n.Tools.Quicklink.label, minLength: 1)),
        ]
    }

    public static var openQuery: String { L10n.effectiveLanguage == .en ? "quicklink" : "网址" }
    private static let browseQueries: Set<String> = ["quicklink", "ql", "网址", "wangzhi"]

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        let raw = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return [] }
        let store = QuicklinkStore.shared

        if Self.browseQueries.contains(raw.lowercased()) {
            return store.browse().enumerated().map { offset, link in
                row(link, query: nil, score: 95 - offset / 4, highlight: "")
            }
        }

        let parts = raw.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let head = parts.first, let link = store.link(keyword: String(head)) else { return [] }
        let term = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        if link.takesQuery, term.isEmpty {
            return [ToolResult(toolID: id, title: link.title, subtitle: L10n.Tools.Quicklink.enterQuery,
                               symbol: symbol, score: 97,
                               action: .prefillQuery("\(link.keyword) "),
                               source: title, highlight: "", sortPriority: 3,
                               key: "quicklink:\(link.id.uuidString)")]
        }
        return [row(link, query: term, score: 97, highlight: String(head))]
    }

    private func row(_ link: Quicklink, query: String?, score: Int, highlight: String) -> ToolResult {
        let url = query.map { link.url(query: $0) } ?? nil
        let action: ToolAction
        let subtitle: String
        if let url {
            action = .openURL(url)
            subtitle = url.host() ?? link.template
        } else if query == nil, !link.takesQuery, let url = link.url(query: "") {
            action = .openURL(url)
            subtitle = url.host() ?? link.template
        } else {
            action = .prefillQuery("\(link.keyword) ")
            subtitle = L10n.Tools.Quicklink.enterQuery
        }
        return ToolResult(toolID: id, title: link.title, subtitle: subtitle,
                          symbol: symbol, score: score, action: action, source: title,
                          highlight: link.title.localizedCaseInsensitiveContains(highlight) ? highlight : "",
                          sortPriority: 3, key: "quicklink:\(link.id.uuidString)")
    }
}
