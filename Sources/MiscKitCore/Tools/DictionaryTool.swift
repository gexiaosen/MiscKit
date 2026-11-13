import Foundation

@MainActor
public struct DictionaryTool: Tool {
    public init() {}
    public let id = ToolID.dictionary
    public var title: String { L10n.Tools.Dictionary.title }
    public let symbol = "text.book.closed"
    public let capabilities: Set<Capability> = []
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "dict", title: L10n.Tools.Dictionary.title,
                              kind: .keyword(["dict", "词典", "字典", "cidian", "cd"])),
        ]
    }

    public static var openQuery: String { L10n.effectiveLanguage == .en ? "dict" : "词典" }
    private static let keywords: Set<String> = ["dict", "词典", "字典", "cidian", "cd"]

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        guard DictionaryLookup.isAvailable else { return [] }
        let raw = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return [] }
        guard let term = ToolQuery.strip(Self.keywords, from: raw) else { return [] }

        guard !term.isEmpty else {
            let names = DictionaryLookup.availableDictionaryNames
            guard !names.isEmpty else { return [] }
            return [ToolResult(toolID: id, title: L10n.Tools.Dictionary.systemTitle, subtitle: names.joined(separator: " · "),
                               symbol: symbol, score: 70, action: .none, source: title,
                               highlight: "", sortPriority: 9, key: "dict:info")]
        }

        return DictionaryLookup.define(term, max: 3).map { entry in
            ToolResult(toolID: id, title: entry.headword, subtitle: entry.dictionaryName,
                       symbol: symbol, score: 97, action: .openDictionary(word: entry.headword),
                       source: title,
                       highlight: entry.headword.localizedCaseInsensitiveContains(term) ? term : "",
                       sortPriority: 2, key: "dict:\(entry.id)", detail: entry.body)
        }
    }
}
