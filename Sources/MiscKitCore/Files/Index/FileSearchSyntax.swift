import Foundation

// MARK: - 查询语法

/// 索引搜索的查询语法：
/// - 空格分词，所有词都要命中；`-词` 排除；`"短语"` 保持完整。
/// - `folder:` / `dir:` / `文件夹:` 只看文件夹，`file:` / `文件:` 只看文件。
/// - `ext:pdf,docx` 按扩展名过滤；`in:~/Downloads` 限定目录；`path:src/main` 搜路径。
/// - `*` / `?` 通配；`~词` 子序列模糊；`re:/正则/i` 正则模式。
/// - 不带通配符时按“包含”匹配。
public struct FileSearchSyntax: Equatable, Sendable {
    /// 单个词的匹配方式。默认包含；带通配符的走 LIKE；`~` 前缀走子序列模糊。
    public enum Match: String, Equatable, Sendable {
        case substring
        case wildcard
        case fuzzy
    }

    public struct Term: Equatable, Sendable {
        public let text: String
        public let isNegated: Bool
        public let isQuoted: Bool
        public let kind: Match

        public init(text: String, isNegated: Bool = false,
                    isQuoted: Bool = false, kind: Match = .substring) {
            self.text = text
            self.isNegated = isNegated
            self.isQuoted = isQuoted
            self.kind = kind
        }

        /// 兼容旧调用点：通配词就是 `kind == .wildcard`。
        public var hasWildcard: Bool { kind == .wildcard }
    }

    /// `/pattern/flags` 解析结果。`caseInsensitive` 默认 true，`c` 标记区分大小写。
    public struct RegexSpec: Equatable, Sendable {
        public let pattern: String
        public let caseInsensitive: Bool
        public let source: String

        public init(pattern: String, caseInsensitive: Bool = true, source: String = "") {
            self.pattern = pattern
            self.caseInsensitive = caseInsensitive
            self.source = source
        }
    }

    public private(set) var terms: [Term] = []
    public private(set) var folderOnly = false
    public private(set) var fileOnly = false
    public private(set) var extensions: [String] = []
    /// `in:` 作用域：原样保存，解析成绝对目录由查询层完成（那里才知道 home）。
    public private(set) var scopes: [String] = []
    /// `path:` 只搜路径，不搜文件名。
    public private(set) var pathOnly = false
    public private(set) var regex: RegexSpec?
    public private(set) var highlightTerm: String?

    public init() {}

    public var isEmpty: Bool {
        terms.isEmpty && extensions.isEmpty && scopes.isEmpty && regex == nil
            && !folderOnly && !fileOnly && !pathOnly
    }

    public var positiveTerms: [Term] {
        terms.filter { !$0.isNegated }
    }

    public static func parse(_ raw: String) -> FileSearchSyntax {
        var syntax = FileSearchSyntax()
        if let regex = parseRegex(raw) {
            syntax.regex = regex
            return syntax
        }

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
            var fuzzy = false
            if !token.quoted, !negated, text.hasPrefix("~"), text.count > 1 {
                fuzzy = true
                text.removeFirst()
            }

            if !token.quoted, !negated, let (filter, value) = splitFilter(text) {
                switch filter {
                case "folder", "dir", "文件夹":
                    syntax.folderOnly = true
                    if !value.isEmpty {
                        syntax.append(text: value, quoted: false, negated: false, kind: .substring)
                    }
                case "file", "文件":
                    syntax.fileOnly = true
                    if !value.isEmpty {
                        syntax.append(text: value, quoted: false, negated: false, kind: .substring)
                    }
                case "ext", "类型":
                    let list = value
                        .split(whereSeparator: { $0 == "," || $0 == ";" })
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
                        .filter { !$0.isEmpty }
                    for item in list where !syntax.extensions.contains(item) {
                        syntax.extensions.append(item)
                    }
                case "in", "在":
                    let scope = value.trimmingCharacters(in: .whitespaces)
                    if !scope.isEmpty, !syntax.scopes.contains(scope) {
                        syntax.scopes.append(scope)
                    }
                case "path", "路径":
                    syntax.pathOnly = true
                    if !value.isEmpty {
                        syntax.append(text: value, quoted: false, negated: false, kind: .substring)
                    }
                default:
                    syntax.append(text: text, quoted: token.quoted, negated: negated,
                                  kind: fuzzy ? .fuzzy : .substring)
                }
                continue
            }

            syntax.append(text: text, quoted: token.quoted, negated: negated,
                          kind: fuzzy ? .fuzzy : .substring)
        }

        if syntax.folderOnly && syntax.fileOnly {
            // 两种互斥过滤同时出现时，按用户最后写下的方向太依赖顺序；退回只看名称。
            syntax.folderOnly = false
            syntax.fileOnly = false
        }
        return syntax
    }

    private mutating func append(text: String, quoted: Bool, negated: Bool, kind: Match) {
        guard !text.isEmpty else { return }
        let resolved: Match
        if kind == .substring, !quoted, text.contains("*") || text.contains("?") {
            resolved = .wildcard
        } else {
            resolved = kind
        }
        let term = Term(text: text, isNegated: negated, isQuoted: quoted, kind: resolved)
        terms.append(term)
        if highlightTerm == nil && !negated && resolved != .wildcard && resolved != .fuzzy {
            highlightTerm = text
        }
    }

    private static func splitFilter(_ text: String) -> (filter: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).lowercased()
        guard key == "folder" || key == "dir" || key == "file"
                || key == "ext" || key == "in" || key == "path"
                || key == "文件夹" || key == "文件" || key == "类型"
                || key == "在" || key == "路径"
        else { return nil }
        return (key, String(text[text.index(after: colon)...]))
    }

    // MARK: 正则

    /// `/pattern/i`、`re:/pattern/i` 或 `regex:pattern`。
    /// 裸 `/.../` 只在模式里出现正则元字符时才认，避免把 `/tmp/` 这类路径当成正则。
    public static func parseRegex(_ raw: String) -> RegexSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let prefixed = lower.hasPrefix("re:") || lower.hasPrefix("regex:")
        var body: String
        if lower.hasPrefix("regex:") {
            body = String(trimmed.dropFirst(6))
        } else if lower.hasPrefix("re:") {
            body = String(trimmed.dropFirst(3))
        } else {
            body = trimmed
        }
        body = body.trimmingCharacters(in: .whitespaces)

        var caseInsensitive = true
        if body.hasPrefix("/"), body.count >= 2, let last = body.lastIndex(of: "/"),
           last > body.startIndex {
            let patternStart = body.index(after: body.startIndex)
            let pattern = String(body[patternStart..<last])
            let flags = String(body[body.index(after: last)...]).lowercased()
            if flags.isEmpty || flags.allSatisfy({ "ic".contains($0) }) {
                if flags.contains("c") { caseInsensitive = false }
                body = pattern
            } else if prefixed {
                return nil
            }
        } else if !prefixed {
            return nil
        }

        guard !body.isEmpty else { return nil }
        // 裸 `/a/b/` 更像路径：模式里再带斜杠就不按正则解释，交给路径直达。
        if !prefixed, body.contains("/") { return nil }
        if !prefixed, !containsMeta(body) { return nil }
        return RegexSpec(pattern: body, caseInsensitive: caseInsensitive, source: trimmed)
    }

    private static func containsMeta(_ text: String) -> Bool {
        let metas = CharacterSet(charactersIn: ".^$*+?()[]{}|\\")
        return text.unicodeScalars.contains { metas.contains($0) }
    }

    // MARK: 模式

    /// 把词转换成针对 `name_folded` 的 LIKE 模式（调用方仍需 `ESCAPE '\'`）。
    public static func likePattern(for term: Term) -> String {
        let folded = FileIndexText.fold(term.text)
        if term.isQuoted {
            return "%" + FileIndexText.escapeLike(folded) + "%"
        }
        if term.kind == .wildcard {
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

    /// 子序列模糊：`~abc` → `%a%b%c%`。顺序必须成立，允许中间穿插任意字符。
    public static func fuzzyPattern(for term: Term) -> String {
        let folded = FileIndexText.fold(term.text)
        var pattern = "%"
        for character in folded {
            pattern.append(FileIndexText.escapeLike(String(character)))
            pattern.append("%")
        }
        return pattern
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

    /// SQLite `GLOB` 没有 `ESCAPE` 子句；把通配元字符放进单字符类里转义。
    /// `[` / `]` 也必须转义，否则用户搜 `[` 会从“有结果”变成“0 条”。
    public static func globPrefix(_ text: String) -> String {
        var pattern = ""
        for character in text {
            switch character {
            case "*", "?", "[", "]":
                pattern.append("[")
                pattern.append(character)
                pattern.append("]")
            default:
                pattern.append(character)
            }
        }
        return pattern + "*"
    }
}
