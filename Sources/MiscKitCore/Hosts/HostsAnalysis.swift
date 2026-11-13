import Darwin
import Foundation

// MARK: - 逐行校验

public struct HostsIssue: Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case warning = 0
        case error = 1

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let severity: Severity
    public let message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct HostsLineInfo: Equatable, Sendable {
    /// 只有合法 IP 才会填在这里。
    public var ip: String?
    public var domains: [String]
    public var issues: [HostsIssue]
    public var isBlank = false
    public var isComment = false
    /// 至少有两列，说明这是一条映射（无论是否合法）。
    public var isMapping = false

    public var hasError: Bool { issues.contains { $0.severity == .error } }
    public var isValidMapping: Bool {
        ip != nil && !domains.isEmpty && !hasError
    }
}

public enum HostsLineParser {
    public static func parse(_ rawLine: String) -> HostsLineInfo {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var info = HostsLineInfo(ip: nil, domains: [], issues: [])

        guard !trimmed.isEmpty else {
            info.isBlank = true
            return info
        }
        guard !trimmed.hasPrefix("#") else {
            info.isComment = true
            return info
        }

        // 行尾注释不参与解析；Tab/空格混用只在有效内容里判定。
        let content: Substring
        if let hash = trimmed.firstIndex(of: "#") {
            content = trimmed[..<hash]
        } else {
            content = trimmed[...]
        }
        let body = content.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else {
            info.isComment = true
            return info
        }

        if body.contains("\t") && body.contains(" ") {
            info.issues.append(HostsIssue(severity: .warning, message: L10n.Hosts.Analysis.mixedWhitespace))
        }

        let tokens = body.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first else {
            info.isComment = true
            return info
        }

        if tokens.count == 1 {
            if isValidIP(String(first)) {
                info.issues.append(HostsIssue(severity: .error, message: L10n.Hosts.Analysis.missingDomain))
            } else {
                info.issues.append(HostsIssue(severity: .error, message: L10n.Hosts.Analysis.invalidIPFirstCol))
            }
            return info
        }

        info.isMapping = true
        let ipText = String(first)
        if isValidIP(ipText) {
            info.ip = ipText
        } else {
            info.issues.append(HostsIssue(severity: .error,
                                          message: L10n.Hosts.Analysis.invalidIP(ipText)))
        }

        for token in tokens.dropFirst() {
            let domain = String(token)
            info.domains.append(domain)
            if !isValidDomain(domain) {
                info.issues.append(HostsIssue(severity: .error,
                                              message: L10n.Hosts.Analysis.invalidDomain(domain)))
            }
        }
        return info
    }

    public static func isValidIP(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, text, &v6) == 1
    }

    public static func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        if domain == "localhost" { return true }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            for character in label {
                if character.isASCII {
                    guard character.isLetter || character.isNumber
                            || character == "-" || character == "_" else { return false }
                } else {
                    guard character.isLetter || character.isNumber else { return false }
                }
            }
        }
        return true
    }
}

// MARK: - 报告

public struct HostsLineIssue: Identifiable, Equatable, Sendable {
    public let sectionID: UUID
    public let sectionName: String
    public let lineIndex: Int
    public let lineText: String
    public let severity: HostsIssue.Severity
    public let message: String

    public var id: String { "\(sectionID.uuidString)-\(lineIndex)-\(message)" }
    public var lineNumber: Int { lineIndex + 1 }
}

public struct HostsMapping: Identifiable, Equatable, Sendable {
    public let domain: String
    public let ip: String
    public let sectionID: UUID
    public let sectionName: String
    public let lineIndex: Int

    public var id: String { "\(sectionID.uuidString)-\(lineIndex)-\(domain)" }
}

public struct HostsConflict: Identifiable, Equatable, Sendable {
    public let domain: String
    public let entries: [HostsMapping]

    public var id: String { domain }
    public var summary: String {
        entries.map { "\($0.sectionName) → \($0.ip)" }.joined(separator: "；")
    }
}

public struct HostsDiffItem: Identifiable, Equatable, Sendable {
    public let domain: String
    public let oldIP: String?
    public let newIP: String?

    public var id: String { domain }
}

public struct HostsDiff: Equatable, Sendable {
    public var added: [HostsDiffItem]
    public var removed: [HostsDiffItem]
    public var changed: [HostsDiffItem]

    public static let empty = HostsDiff(added: [], removed: [], changed: [])

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    public var changeCount: Int { added.count + removed.count + changed.count }

    public var summary: String {
        guard !isEmpty else { return L10n.Hosts.Diff.matches }
        return L10n.Hosts.Diff.summary(added.count, removed.count, changed.count)
    }
}

public struct HostsReport: Sendable {
    public var issues: [HostsLineIssue]
    public var conflicts: [HostsConflict]
    /// 按拼接顺序、后者覆盖前者后的生效域名。
    public var effective: [HostsMapping]
    public var diff: HostsDiff
    public var enabledSectionCount: Int
    public var blockingIssues: [HostsLineIssue]
    public var warningCount: Int

    public static let empty = HostsReport(issues: [], conflicts: [], effective: [],
                                          diff: .empty, enabledSectionCount: 0,
                                          blockingIssues: [], warningCount: 0)

    public var canApply: Bool { blockingIssues.isEmpty }

    public static func build(document: HostsDocument, currentText: String) -> HostsReport {
        let preambleID = preambleSectionID
        var issues: [HostsLineIssue] = []
        var blocking: [HostsLineIssue] = []
        var warnings = 0
        var target: [HostsMapping] = []

        func inspect(_ rawLines: [String], sectionID: UUID, sectionName: String,
                     isActive: Bool, allowsDisabled: Bool, disabled: Set<Int>) {
            for (index, line) in rawLines.enumerated() {
                guard isActive, !(allowsDisabled && disabled.contains(index)) else { continue }
                let info = HostsLineParser.parse(line)
                guard info.isMapping || !info.issues.isEmpty else { continue }
                for issue in info.issues {
                    let row = HostsLineIssue(sectionID: sectionID, sectionName: sectionName,
                                             lineIndex: index, lineText: line,
                                             severity: issue.severity, message: issue.message)
                    issues.append(row)
                    if issue.severity == .error {
                        blocking.append(row)
                    } else {
                        warnings += 1
                    }
                }
                guard info.isValidMapping, let ip = info.ip else { continue }
                for domain in info.domains {
                    target.append(HostsMapping(domain: domain, ip: ip, sectionID: sectionID,
                                               sectionName: sectionName, lineIndex: index))
                }
            }
        }

        // 文件头始终生效。
        inspect(document.preamble, sectionID: preambleID, sectionName: L10n.Hosts.Analysis.header,
                isActive: true, allowsDisabled: false, disabled: [])

        for section in document.orderedSections where section.isEnabled {
            inspect(section.lines, sectionID: section.id, sectionName: section.name,
                    isActive: true, allowsDisabled: true, disabled: section.disabledLines)
        }

        let enabledCount = document.sections.filter(\.isEnabled).count
        let conflicts = conflicts(in: target)
        let effective = lastWins(target)
        let current = currentMappings(from: currentText)
        let diff = diff(current: current, target: effective)

        return HostsReport(issues: issues, conflicts: conflicts, effective: effective,
                           diff: diff, enabledSectionCount: enabledCount,
                           blockingIssues: blocking, warningCount: warnings)
    }

    static let preambleSectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// 当前磁盘上的生效映射（按文件顺序，后者覆盖前者）。
    public static func currentMappings(from text: String) -> [HostsMapping] {
        let document = HostsDocument.parse(text)
        var mappings: [HostsMapping] = []
        func collect(_ lines: [String], sectionID: UUID, name: String) {
            for (index, line) in lines.enumerated() {
                let info = HostsLineParser.parse(line)
                guard info.isValidMapping, let ip = info.ip else { continue }
                for domain in info.domains {
                    mappings.append(HostsMapping(domain: domain, ip: ip, sectionID: sectionID,
                                                 sectionName: name, lineIndex: index))
                }
            }
        }
        collect(document.preamble, sectionID: preambleSectionID, name: L10n.Hosts.Analysis.header)
        for section in document.sections {
            collect(section.lines, sectionID: section.id, name: section.name)
        }
        return lastWins(mappings)
    }

    static func conflicts(in mappings: [HostsMapping]) -> [HostsConflict] {
        var order: [String] = []
        var grouped: [String: [HostsMapping]] = [:]
        for mapping in mappings {
            if grouped[mapping.domain] == nil { order.append(mapping.domain) }
            grouped[mapping.domain, default: []].append(mapping)
        }
        return order.compactMap { domain in
            let entries = grouped[domain] ?? []
            let ips = Set(entries.map(\.ip))
            let sections = Set(entries.map(\.sectionID))
            guard ips.count > 1, sections.count > 1 else { return nil }
            return HostsConflict(domain: domain, entries: entries)
        }
    }

    static func lastWins(_ mappings: [HostsMapping]) -> [HostsMapping] {
        var order: [String] = []
        var byDomain: [String: HostsMapping] = [:]
        for mapping in mappings {
            if byDomain[mapping.domain] == nil { order.append(mapping.domain) }
            byDomain[mapping.domain] = mapping
        }
        return order.compactMap { byDomain[$0] }
    }

    static func diff(current: [HostsMapping], target: [HostsMapping]) -> HostsDiff {
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.domain, $0.ip) })
        let targetMap = Dictionary(uniqueKeysWithValues: target.map { ($0.domain, $0.ip) })

        var added: [HostsDiffItem] = []
        var removed: [HostsDiffItem] = []
        var changed: [HostsDiffItem] = []

        for (domain, ip) in targetMap where currentMap[domain] == nil {
            added.append(HostsDiffItem(domain: domain, oldIP: nil, newIP: ip))
        }
        for (domain, ip) in currentMap where targetMap[domain] == nil {
            removed.append(HostsDiffItem(domain: domain, oldIP: ip, newIP: nil))
        }
        for (domain, ip) in targetMap {
            guard let old = currentMap[domain], old != ip else { continue }
            changed.append(HostsDiffItem(domain: domain, oldIP: old, newIP: ip))
        }

        return HostsDiff(added: added.sorted { $0.domain < $1.domain },
                         removed: removed.sorted { $0.domain < $1.domain },
                         changed: changed.sorted { $0.domain < $1.domain })
    }
}
