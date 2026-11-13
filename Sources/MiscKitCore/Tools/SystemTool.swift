import Foundation

@MainActor
public struct SystemTool: Tool {
    public init() {}
    public let id = ToolID.system
    public var title: String { L10n.Tools.System.title }
    public let symbol = "gearshape.2"
    public let capabilities: Set<Capability> = []
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "system", title: L10n.Tools.System.title, kind: .keyword(["系统", "sys", "xitong"])),
            TriggerDescriptor(code: "system-any", title: L10n.Tools.System.actionTrigger,
                              kind: .text(label: L10n.Tools.System.actionTrigger, minLength: 2)),
        ]
    }

    public static var openQuery: String { L10n.effectiveLanguage == .en ? "sys" : "系统" }
    private static let browseQueries: Set<String> = ["系统", "sys", "xitong"]
    /// 与应用名同分档时排后面：打「睡眠」不该输给某个叫睡眠的 App，但打 App 名时 App 仍优先。
    private static let actionScore = 95

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        let raw = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return [] }

        if let percent = Self.volumePercent(from: raw) {
            let current = SystemControl.currentVolume().map { "\($0)%" } ?? L10n.Tools.System.volumeUnavailable
            return [ToolResult(toolID: id, title: L10n.Tools.System.volumeTitle(percent),
                               subtitle: L10n.Tools.System.volumeSubtitle(current),
                               symbol: "speaker.wave.2.fill", score: 99,
                               action: .systemAction("volume:\(percent)"),
                               source: title, highlight: "", sortPriority: 4,
                               key: "system:volume:\(percent)")]
        }

        if Self.browseQueries.contains(raw.lowercased()) {
            // 每个分组一个档位：注册表同分按标题字母序，逐条递减会把分组切碎。
            return SystemActionCatalog.all.map { action in
                let order = SystemActionGroup.allCases.firstIndex(of: action.group) ?? 0
                return row(action, score: Self.actionScore - order, highlight: "")
            }
        }

        let matched = SystemActionCatalog.match(raw)
        guard !matched.isEmpty, raw.count >= 2 else { return [] }
        // 注册表同分再按标题字母序，全给一个分等于把 match 的排序扔掉；逐行递减保住它。
        return matched.prefix(6).enumerated().map { offset, action in
            row(action, score: Self.actionScore - offset, highlight: raw)
        }
    }

    private func row(_ action: SystemAction, score: Int, highlight: String) -> ToolResult {
        // 「设定音量…」不设一个猜测值：把 prefix 塞回输入框，接着打数字就行。
        let toolAction: ToolAction = action.id == "volume-set"
            ? .prefillQuery(L10n.Tools.System.volumePrefill)
            : .systemAction(action.id)
        return ToolResult(toolID: id, title: action.title, subtitle: action.group.label,
                          symbol: action.symbol, score: score,
                          action: toolAction, source: title,
                          highlight: action.title.localizedCaseInsensitiveContains(highlight) ? highlight : "",
                          sortPriority: 4, key: "system:\(action.id)")
    }

    /// `音量 30` / `音量30` / `volume 30`。
    nonisolated static func volumePercent(from raw: String) -> Int? {
        let lowered = raw.lowercased()
        for prefix in ["音量", "volume"] where lowered.hasPrefix(prefix.lowercased()) {
            let rest = lowered.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "%", with: "")
            guard let value = Int(rest), (0...100).contains(value) else { continue }
            return value
        }
        return nil
    }
}
