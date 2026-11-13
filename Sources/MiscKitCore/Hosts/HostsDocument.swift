import Foundation

/// hosts 里的一段。`headerLine` 保留原始文本（含 CRLF 的 `\r`），
/// 首次导入后按原样写回；新建段才用统一格式生成标题行。
public struct HostsSection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var headerLine: String?
    public var lines: [String]
    public var isBase: Bool
    public var isEnabled: Bool
    /// 行级临时禁用只存在工具侧，不写进 hosts。
    public var disabledLines: Set<Int>

    public init(id: UUID = UUID(), name: String, headerLine: String? = nil,
                lines: [String] = [], isBase: Bool = false,
                isEnabled: Bool = true, disabledLines: Set<Int> = []) {
        self.id = id
        self.name = name
        self.headerLine = headerLine
        self.lines = lines
        self.isBase = isBase
        self.isEnabled = isEnabled
        self.disabledLines = disabledLines
    }

    public var mappingLineCount: Int {
        lines.filter { HostsLineParser.parse($0).isMapping }.count
    }

    public var disabledMappingCount: Int {
        lines.enumerated()
            .filter { disabledLines.contains($0.offset) && HostsLineParser.parse($0.element).isMapping }
            .count
    }
}

/// hosts 文件的无损模型。`serialized()` 逐字节还原原文，`rendered()` 产出应用目标。
public struct HostsDocument: Codable, Equatable, Sendable {
    /// 第一个段标题之前的内容：始终写入，不参与勾选。
    public var preamble: [String]
    public var sections: [HostsSection]
    /// 新建标题行使用的换行符（原文件是 CRLF 时跟随）。
    public var lineEnding: String
    public var endsWithNewline: Bool

    public init(preamble: [String] = [], sections: [HostsSection] = [],
                lineEnding: String = "\n", endsWithNewline: Bool = true) {
        self.preamble = preamble
        self.sections = sections
        self.lineEnding = lineEnding
        self.endsWithNewline = endsWithNewline
    }

    public static let empty = HostsDocument()

    public var orderedSections: [HostsSection] {
        sections.filter(\.isBase) + sections.filter { !$0.isBase }
    }

    // MARK: 解析

    public static func parse(_ text: String) -> HostsDocument {
        let lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        guard !text.isEmpty else {
            return HostsDocument(preamble: [], sections: [], lineEnding: lineEnding,
                                 endsWithNewline: false)
        }

        var parts = text.components(separatedBy: "\n")
        let endsWithNewline = parts.last == ""
        if endsWithNewline {
            parts.removeLast()
        }

        var preamble: [String] = []
        var sections: [HostsSection] = []
        var current: Int?

        for line in parts {
            if let name = sectionName(in: line) {
                sections.append(HostsSection(name: name, headerLine: line))
                current = sections.count - 1
            } else if let current {
                sections[current].lines.append(line)
            } else {
                preamble.append(line)
            }
        }

        if sections.isEmpty {
            // 没有段标题的旧文件：整体作为「共用」基座，仍可逐行禁用。
            guard !parts.isEmpty else {
                return HostsDocument(preamble: [], sections: [], lineEnding: lineEnding,
                                     endsWithNewline: endsWithNewline)
            }
            sections = [HostsSection(name: "共用", lines: parts, isBase: true)]
            preamble = []
        } else if let base = sections.firstIndex(where: { $0.name == "共用" }) {
            sections[base].isBase = true
        } else {
            // 没有「共用」时把第一段当基座，保证模型里始终有且只有一个基座。
            sections[0].isBase = true
        }

        return HostsDocument(preamble: preamble, sections: sections,
                             lineEnding: lineEnding, endsWithNewline: endsWithNewline)
    }

    /// `#-------- 段名 --------`：两侧各至少两个短横线，中间名字非空。
    static func sectionName(in rawLine: String) -> String? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("--") else { return nil }

        var leading = 0
        while body.hasPrefix("-") {
            body.removeFirst()
            leading += 1
        }
        guard leading >= 2 else { return nil }
        body = body.trimmingCharacters(in: .whitespaces)

        var trailing = 0
        while body.hasSuffix("-") {
            body.removeLast()
            trailing += 1
        }
        guard trailing >= 2 else { return nil }

        let name = body.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: 输出

    /// 原文往返：包含全部段和行，忽略勾选/禁用状态。
    public func serialized() -> String {
        var lines = preamble
        for section in sections {
            if let header = section.headerLine { lines.append(header) }
            lines.append(contentsOf: section.lines)
        }
        let text = lines.joined(separator: "\n")
        guard endsWithNewline, !text.isEmpty else { return text }
        return text + "\n"
    }

    /// 应用目标：基座在前，仅写入启用的段和未禁用的行。
    public func rendered() -> String {
        var lines = preamble
        for section in orderedSections where section.isEnabled {
            lines.append(section.headerLine ?? generatedHeader(for: section))
            for (index, line) in section.lines.enumerated()
            where !section.disabledLines.contains(index) {
                lines.append(line)
            }
        }
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// 新建段/无标题段的统一标题行。
    func generatedHeader(for section: HostsSection) -> String {
        var header = "#-------- \(section.name) --------"
        if lineEnding == "\r\n" { header += "\r" }
        return header
    }
}

// MARK: - 段与行的编辑
//
// 全部放在 `HostsDocument` 而不是 store 里，是因为这几个操作的正确性只依赖文档自身的
// 不变量（标题行与名字一致、disabledLines 的下标必须跟着行增删走），
// 与"文件在磁盘上""要不要提权"无关 —— 放这里才测得动。
public extension HostsDocument {
    /// 段名合法性检查。返回错误说明；`nil` 表示可用。
    ///
    /// 为什么这么严：段名会被拼进 `#-------- 名 --------`，而 `sectionName(in:)` 解析时
    /// 会**吃掉首尾的短横线与空白**。所以名字带 `-` 收尾的话，写进去再读回来就不是同一个名字了。
    static func nameProblem(_ raw: String, in sections: [HostsSection], ignoring selfID: UUID?) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return L10n.Hosts.Doc.nameEmpty }
        if name.contains("\n") || name.contains("\r") { return L10n.Hosts.Doc.nameNewline }
        if name.hasPrefix("-") || name.hasSuffix("-") {
            return L10n.Hosts.Doc.nameEdgeHyphen
        }
        if name.count > 40 { return L10n.Hosts.Doc.nameTooLong }
        let clash = sections.first { $0.id != selfID
            && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        if let clash {
            return L10n.Hosts.Doc.nameDuplicate(clash.name)
        }
        return nil
    }

    /// 新建一个叠加段。名字不合法就返回 nil，调用方不必自己校验。
    mutating func addSection(named rawName: String) -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard Self.nameProblem(name, in: sections, ignoring: nil) == nil else { return nil }
        let section = HostsSection(name: name, headerLine: nil, lines: [])
        sections.append(section)
        return section.id
    }

    /// 改名。**必须连 `headerLine` 一起改写**：否则工具里是新名、文件里还是旧名，
    /// 下次「重新导入」会按旧名建出一个新 UUID 的段，勾选与逐行禁用状态全部丢失。
    mutating func renameSection(id: UUID, to rawName: String) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return false }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard Self.nameProblem(name, in: sections, ignoring: id) == nil else { return false }
        sections[index].name = name
        // 原来带 CRLF 的标题行要保住行尾风格：generatedHeader 已经按 lineEnding 处理
        if sections[index].headerLine != nil {
            sections[index].headerLine = generatedHeader(for: sections[index])
        }
        return true
    }

    /// 删段。基座不许删（它是常驻解析，删掉等于把本机基础 DNS 抹了）。
    mutating func removeSection(id: UUID) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return false }
        guard !sections[index].isBase else { return false }
        sections.remove(at: index)
        return true
    }

    /// 就地改一行。下标不变，所以 `disabledLines` 原样有效 —— 这正是"改文本不该顺手解禁"。
    mutating func updateLine(in id: UUID, at lineIndex: Int, to line: String) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }),
              sections[index].lines.indices.contains(lineIndex) else { return false }
        sections[index].lines[lineIndex] = line
        return true
    }

    /// 整段替换正文。旧下标在批量编辑后没有意义，逐行禁用标记必须清空，
    /// 否则会随机落到新内容的某一行上；UI 会提前告知用户。
    mutating func replaceLines(in id: UUID, with lines: [String]) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return false }
        sections[index].lines = lines
        sections[index].disabledLines.removeAll()
        return true
    }

    /// 插入一行。`at` 省略就加到段尾。插入点及其后的禁用标记整体后移一位。
    mutating func insertLine(_ line: String, in id: UUID, at index: Int? = nil) -> Bool {
        guard let position = sections.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(index ?? sections[position].lines.count, 0),
                         sections[position].lines.count)
        sections[position].lines.insert(line, at: target)
        sections[position].disabledLines = Set(sections[position].disabledLines
            .map { $0 >= target ? $0 + 1 : $0 })
        return true
    }

    /// 删一行。**必须重映射 `disabledLines`**：不处理的话，删掉第 2 行会让原本禁用在
    /// 第 5 行上的标记跑到新的第 4 行 —— 用户会说"我今天不想让这条生效"的，悄悄变成另一条。
    mutating func deleteLine(in id: UUID, at lineIndex: Int) -> Bool {
        guard let position = sections.firstIndex(where: { $0.id == id }),
              sections[position].lines.indices.contains(lineIndex) else { return false }
        sections[position].lines.remove(at: lineIndex)
        sections[position].disabledLines = Set(sections[position].disabledLines.compactMap { offset in
            if offset == lineIndex { return nil }
            return offset > lineIndex ? offset - 1 : offset
        })
        return true
    }

    func section(id: UUID) -> HostsSection? { sections.first { $0.id == id } }
}
