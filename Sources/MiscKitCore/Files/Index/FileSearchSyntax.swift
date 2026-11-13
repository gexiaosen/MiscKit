import Foundation

// MARK: - 查询语法

/// 索引搜索的查询语法：
/// - 空格分词，所有词都要命中；`-词` 排除；`"短语"` 保持完整。
/// - `folder:` / `dir:` / `文件夹:` 只看文件夹，`file:` / `文件:` 只看文件。
/// - `ext:pdf,docx` 按扩展名过滤。
/// - `*` / `?` 通配；不带通配符时按“包含”匹配。
public struct FileSearchSyntax: Equatable, Sendable {
    public struct Term: Equatable, Sendable {
        public let text: String
        public let isNegated: Bool
        public let isQuoted: Bool
        public let hasWildcard: Bool

        public init(text: String, isNegated: Bool = false,
                    isQuoted: Bool = false, hasWildcard: Bool = false) {
            self.text = text
            self.isNegated = isNegated
            self.isQuoted = isQuoted
            self.hasWildcard = hasWildcard
        }
    }

    public private(set) var terms: [Term] = []
    public private(set) var folderOnly = false
    public private(set) var fileOnly = false
    public private(set) var extensions: [String] = []
    public private(set) var highlightTerm: String?

    public init() {}

    public var isEmpty: Bool {
        terms.isEmpty && extensions.isEmpty && !folderOnly && !fileOnly
    }

    public var positiveTerms: [Term] {
        terms.filter { !$0.isNegated }
    }

    public static func parse(_ raw: String) -> FileSearchSyntax {
        var syntax = FileSearchSyntax()
        var buffer = ""
        var inQuotes = false
        var wasQuoted = false
        var parsed: [(text: String, quoted: Bool)] = []

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || wasQuoted {
                parsed.append((text, wasQuoted))
            }
            buffer = ""
            wasQuoted = false
        }

        for character in raw {
            if character == "\"" {
                if inQuotes {
                    inQuotes = false
                    flush()
                } else {
                    inQuotes = true
                }
                continue
            }
            if character.isWhitespace && !inQuotes {
                flush()
                continue
            }
            buffer.append(character)
            if inQuotes { wasQuoted = true }
        }
        flush()

        for token in parsed {
            var text = token.text
            var negated = false
            if !token.quoted, text.hasPrefix("-"), text.count > 1 {
                negated = true
                text.removeFirst()
            }

            if !token.quoted, !negated, let (filter, value) = splitFilter(text) {
                switch filter {
                case "folder", "dir", "文件夹":
                    syntax.folderOnly = true
                    if !value.isEmpty {
                        syntax.append(text: value, quoted: false, negated: false)
                    }
                case "file", "文件":
                    syntax.fileOnly = true
                    if !value.isEmpty {
                        syntax.append(text: value, quoted: false, negated: false)
                    }
                case "ext", "类型":
                    let list = value
                        .split(whereSeparator: { $0 == "," || $0 == ";" })
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
                        .filter { !$0.isEmpty }
                    for item in list where !syntax.extensions.contains(item) {
                        syntax.extensions.append(item)
                    }
                default:
                    syntax.append(text: text, quoted: token.quoted, negated: negated)
                }
                continue
            }

            syntax.append(text: text, quoted: token.quoted, negated: negated)
        }

        if syntax.folderOnly && syntax.fileOnly {
            // 两种互斥过滤同时出现时，按用户最后写下的方向太依赖顺序；退回只看名称。
            syntax.folderOnly = false
            syntax.fileOnly = false
        }
        return syntax
    }

    private mutating func append(text: String, quoted: Bool, negated: Bool) {
        guard !text.isEmpty else { return }
        let wildcard = !quoted && (text.contains("*") || text.contains("?"))
        let term = Term(text: text, isNegated: negated, isQuoted: quoted, hasWildcard: wildcard)
        terms.append(term)
        if highlightTerm == nil && !negated && !wildcard {
            highlightTerm = text
        }
    }

    private static func splitFilter(_ text: String) -> (filter: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).lowercased()
        guard key == "folder" || key == "dir" || key == "file"
                || key == "ext" || key == "文件夹" || key == "文件" || key == "类型"
        else { return nil }
        return (key, String(text[text.index(after: colon)...]))
    }

    /// 把词转换成针对 `name_folded` 的 LIKE 模式（调用方仍需 `ESCAPE '\'`）。
    public static func likePattern(for term: Term) -> String {
        let folded = FileIndexText.fold(term.text)
        if term.isQuoted {
            return "%" + FileIndexText.escapeLike(folded) + "%"
        }
        if term.hasWildcard {
            var pattern = ""
            for character in folded {
                switch character {
                case "*": pattern.append("%")
                case "?": pattern.append("_")
                default: pattern.append(FileIndexText.escapeLike(String(character)))
                }
            }
            return pattern
        }
        return "%" + FileIndexText.escapeLike(folded) + "%"
    }
}

public enum FileIndexText {
    /// 文件名和查询都走同一套折叠：大小写、变音不敏感，组合字符预组合。
    public static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .lowercased()
    }

    public static func escapeLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
