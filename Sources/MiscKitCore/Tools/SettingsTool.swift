import Foundation

@MainActor
public struct SettingsTool: Tool {
    public init() {}
    public let id = ToolID.settings
    public var title: String { L10n.Tools.Settings.title }
    public let symbol = "gearshape"
    public let capabilities: Set<Capability> = []
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "settings", title: L10n.Tools.Settings.title,
                              kind: .keyword(["设置", "settings", "shezhi", "sz"])),
            TriggerDescriptor(code: "settings-any", title: L10n.Tools.Settings.paneLabel,
                              kind: .text(label: L10n.Tools.Settings.paneLabel, minLength: 1)),
        ]
    }

    public static var openQuery: String { L10n.effectiveLanguage == .en ? "settings" : "设置" }
    private static let keywords: Set<String> = ["设置", "settings", "shezhi", "sz"]

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        let raw = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return [] }
        let index = SettingsPaneIndex.shared

        if let term = ToolQuery.strip(Self.keywords, from: raw) {
            guard !term.isEmpty else {
                return index.all.enumerated().map { offset, pane in
                    row(pane, score: 95 - offset / 4, highlight: "")
                }
            }
            return index.search(term).map { row($0.pane, score: $0.score, highlight: term) }
        }

        // 不带关键词时先比名字、再比索引词：打「蓝牙」直达，打「设备」这种泛词不铺一屏。
        return index.directMatches(raw).map { row($0.pane, score: $0.score, highlight: raw) }
    }

    private func row(_ pane: SettingsPane, score: Int, highlight: String) -> ToolResult {
        ToolResult(toolID: id, title: pane.name, subtitle: pane.subtitle ?? L10n.Tools.Settings.systemSubtitle,
                   symbol: pane.iconSymbol ?? symbol, score: score, action: .openURL(pane.url),
                   source: title,
                   highlight: pane.name.localizedCaseInsensitiveContains(highlight) ? highlight : "",
                   iconURL: pane.iconSymbol == nil
                       ? pane.appexPath.map { URL(fileURLWithPath: $0) }
                       : nil,
                   sortPriority: 7, key: "settings:\(pane.id)")
    }
}
