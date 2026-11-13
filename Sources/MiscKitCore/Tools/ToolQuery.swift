import Foundation

enum ToolQuery {
    /// `词典 apple` → `apple`；只打了关键词 → 空串；没打关键词 → nil。
    /// 只切第一个空白：词本身可以带空格。
    static func strip(_ keywords: Set<String>, from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let head = parts.first, keywords.contains(head.lowercased()) else { return nil }
        return parts.count == 2
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
    }
}
