import Foundation

@MainActor
public struct AppsTool: Tool {
    public init() {}
    public let id = ToolID.apps
    public var title: String { L10n.Tools.Apps.title }
    public let symbol = "square.grid.2x2"
    public let capabilities: Set<Capability> = []
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "app", title: L10n.Tools.Apps.trigger, kind: .keyword(["app", "apps", "应用", "yingyong"])),
            TriggerDescriptor(code: "app-any", title: L10n.Tools.Apps.anyTitle,
                              kind: .text(label: L10n.Tools.Apps.anyLabel, minLength: 1)),
        ]
    }

    private static let browseQueries: Set<String> = ["app", "apps", "应用", "yingyong"]

    /// 动作行压过普通应用行，也压过「搜索文件」那条 82 分的兜底。
    private static let actionScore = 94
    private static let actionLimit = 6

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        guard let raw = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }
        let running = RowActionCatalog.RunningSnapshot()
        if let rows = actionRows(for: raw, running: running), !rows.isEmpty { return rows }

        let isBrowse = Self.browseQueries.contains(raw.lowercased())
        let index = AppIndex.shared
        let hits = isBrowse ? index.topApps(limit: 8) : index.search(raw, limit: 8)

        return hits.map { hit in
            let fragment = isBrowse ? nil : hit.highlight
            let highlight = fragment?.caseInsensitiveCompare(hit.app.name) == .orderedSame ? nil : fragment
            return ToolResult(toolID: id,
                       title: hit.app.name,
                       subtitle: hit.app.abbreviatedPath,
                       symbol: symbol,
                       score: hit.score,
                       action: .launchApp(url: hit.app.url, appID: hit.app.id),
                       source: title,
                       highlight: highlight,
                       iconURL: hit.app.url,
                       sortPriority: 10,
                       key: "app:\(hit.app.id)",
                       isRunning: running.contains(hit.app))
        }
    }

    /// 「chrome 拷」→ Chrome 的所有带「拷」的动作，一个动作一行，回车直接执行。
    /// 动作词模糊匹配，所以打半个词就看见了全部候选 —— 不需要再按键切一层动作菜单。
    private func actionRows(for raw: String,
                            running: RowActionCatalog.RunningSnapshot) -> [ToolResult]? {
        guard let (object, term) = RowActionCatalog.split(raw),
              let app = AppIndex.shared.search(object, limit: 1).first?.app else { return nil }
        let matched = RowActionCatalog.match(term)
        guard !matched.isEmpty else { return nil }
        let available = Set(RowActionCatalog.available(isRunning: running.contains(app)).map(\.code))
        let rows = matched.filter { available.contains($0.code) }.prefix(Self.actionLimit)
        // 注册表同分再按标题字母序，逐行递减才保得住动作表自己的顺序。
        return rows.enumerated().map { offset, action in
            ToolResult(toolID: id,
                       title: action.title,
                       subtitle: app.name,
                       symbol: symbol,
                       score: Self.actionScore - offset,
                       action: RowActionCatalog.toolAction(action.code, for: app),
                       source: title,
                       highlight: action.title.localizedCaseInsensitiveContains(term) ? term : "",
                       iconURL: app.url,
                       sortPriority: 11,
                       key: "app-action:\(app.id):\(action.code)",
                       isRunning: running.contains(app))
        }
    }
}