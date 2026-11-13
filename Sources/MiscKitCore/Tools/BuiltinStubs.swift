import Foundation

private func keywords(_ words: String...) -> [TriggerDescriptor] {
    [TriggerDescriptor(code: words.first ?? "", title: words.joined(separator: " / "),
                       kind: .keyword(words))]
}

/// 内置工具：声明触发语义、所需能力与结果行，由 `BuiltinTools.registerAll` 统一注册。
@MainActor
public struct FilesTool: Tool {
    public init() {}
    public let id = ToolID.files
    public var title: String { L10n.Tools.Files.title }
    public let symbol = "folder"
    public let capabilities: Set<Capability> = [.fileRead]
    /// 关键词直达文件模式；任意文本再给一行"搜索文件"，由启动器与其它结果按分数混排。
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "file", title: L10n.Tools.Files.trigger, kind: .keyword(["file", "文件", "wenjian"])),
            TriggerDescriptor(code: "file-any", title: L10n.Tools.Files.search,
                              kind: .text(label: L10n.Tools.Files.search, minLength: 1)),
        ]
    }

    /// 低于应用的前缀/拼音命中，高于弱命中；用户点这一行原地切到文件搜索。
    static let searchRowScore = 82

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        var rows: [ToolResult] = []
        let term = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !term.isEmpty {
            rows.append(ToolResult(toolID: id,
                                   title: L10n.Tools.Files.search,
                                   symbol: "doc.text.magnifyingglass",
                                   score: Self.searchRowScore,
                                   action: .openTool(id),
                                   source: title,
                                   // 动作行的标题不是命中内容，不染强调色
                                   highlight: "",
                                   sortPriority: 5,
                                   key: "file-search:\(term)"))
        }
        return rows
    }
}

@MainActor
public struct MeetingTool: Tool {
    public init() {}
    public let id = ToolID.meeting
    public var title: String { L10n.Tools.Meeting.title }
    public let symbol = "video.fill"
    public let capabilities: Set<Capability> = []
    /// 触发只负责"值得再看一眼"，是不是会议号交给 `MeetingCodeRecognizer` 判：
    /// 锚点、入会链接、纯号码三条路各自有拒绝规则，比一条正则可靠。
    public var triggers: [TriggerDescriptor] {
        [
            TriggerDescriptor(code: "meeting-code", title: L10n.Tools.Meeting.triggerTitle,
                              kind: .text(label: L10n.Tools.Meeting.triggerLabel,
                                          minLength: MeetingCodeRecognizer.lengthRange.lowerBound)),
        ]
    }

    /// 命中依据决定置信度：链接参数 > 锚点词 > 裸号码，都高于普通文本弱命中。
    private func score(for anchor: MeetingAnchor) -> Int {
        switch anchor {
        case .inviteURL: return 96
        case .keyword: return 92
        case .bare: return 88
        }
    }

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        guard let text = input.text,
              let candidate = MeetingCodeRecognizer.recognize(text) else { return [] }
        let rowTitle = L10n.Tools.Meeting.rowTitle(candidate.formatted)
        let reason: String
        switch candidate.anchor {
        case .inviteURL: reason = L10n.Tools.Meeting.reasonInvite
        case .keyword(let word): reason = L10n.Tools.Meeting.reasonKeyword(word)
        case .bare: reason = L10n.Tools.Meeting.reasonBare
        }
        return [ToolResult(toolID: id,
                           title: rowTitle,
                           subtitle: reason,
                           symbol: symbol,
                           score: score(for: candidate.anchor),
                           action: .joinMeeting(code: candidate.code),
                           source: title,
                           highlight: "",
                           sortPriority: 6,
                           key: "meeting:join")]
    }
}

@MainActor
public struct OTPTool: Tool {
    public init() {}
    public let id = ToolID.otp
    public let title = "OTP"
    public let symbol = "key.fill"
    public let capabilities: Set<Capability> = [.keychain, .clipboardWrite]
    /// 点行进入工作区时用的查询词，也要能被自己的关键词命中。
    public static var openQuery: String { L10n.effectiveLanguage == .en ? "otp" : "验证码" }
    public var triggers: [TriggerDescriptor] {
        keywords("otp", "验证码", "yanzhengma", "totp") + [
            TriggerDescriptor(code: "otp.account", title: L10n.Tools.OTP.triggerAccount,
                              kind: .text(label: L10n.Tools.OTP.triggerAccount, minLength: 2)),
        ]
    }

    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        let store = OTPStore.shared
        let term = (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [ToolResult] = []

        if term.count >= 2 {
            let matches = store.accounts
                .compactMap { account -> (OTPAccount, Int)? in
                    let score = account.matchScore(term)
                    return score > 0 ? (account, score) : nil
                }
                .sorted { lhs, rhs in
                    lhs.1 == rhs.1 ? lhs.0.displayName < rhs.0.displayName : lhs.1 > rhs.1
                }

            rows = matches.prefix(5).map { account, score in
                ToolResult(toolID: id,
                           title: account.displayName,
                           symbol: symbol,
                           score: score,
                           action: .copyOTP(account.id),
                           source: "OTP",
                           highlight: term,
                           sortPriority: 8,
                           key: "otp:account:\(account.id.uuidString)")
            }

            if matches.count > 5 {
                rows.append(ToolResult(toolID: id,
                                       title: L10n.Tools.OTP.openWorkspace,
                                       subtitle: L10n.Tools.OTP.manyMatches(matches.count),
                                       symbol: symbol,
                                       score: 86,
                                       action: .openTool(id),
                                       source: title,
                                       key: "otp:open"))
            }
        }

        // 关键词命中时才保留“进工作区”入口；文本搜索没有账户命中就什么都不出，
        // 否则每个两个字的查询都会顶一条无用的 OTP 行。
        let keywordHit = hit.score >= 60
        if rows.isEmpty ? keywordHit : (keywordHit && rows.count <= 5) {
            let count = store.accounts.count
            let subtitle = count == 0
                ? L10n.Tools.OTP.emptySubtitle
                : L10n.Tools.OTP.accountCount(count)
            rows.append(ToolResult(toolID: id, title: L10n.Tools.OTP.titleRow, subtitle: subtitle,
                                   symbol: symbol, score: keywordHit ? hit.score : 86,
                                   action: .openTool(id), source: title,
                                   highlight: "", key: "otp:open"))
        }
        return rows
    }
}

@MainActor
public struct CalcTool: Tool {
    public init() {}
    public let id = ToolID.calc
    public var title: String { L10n.Tools.Calc.title }
    public let symbol = "plus.forwardslash.minus"
    public let capabilities: Set<Capability> = []
    public static var openQuery: String { L10n.effectiveLanguage == .en ? "calc" : "稿纸" }
    public let triggers = keywords("calc", "js", "算", "稿纸", "gaozhi")
    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        let store = CalcStore.shared
        let sheets = store.activeSheets.count
        let subtitle = sheets == 0 ? "" : L10n.Tools.Calc.sheetsCount(sheets)
        return [ToolResult(toolID: id, title: L10n.Tools.Calc.titleRow, subtitle: subtitle,
                           symbol: symbol, score: hit.score, action: .openTool(id),
                           source: title, highlight: "", key: "calc:open")]
    }
}

@MainActor
public struct ReminderTool: Tool {
    public init() {}
    public let id = ToolID.reminder
    public var title: String { L10n.Tools.Reminder.title }
    public let symbol = "drop.halffull"
    public let capabilities: Set<Capability> = []
    /// 进入提醒页时用的查询词，也要能被自己的关键词命中。
    public static var openQuery: String { L10n.effectiveLanguage == .en ? "remind" : "提醒" }
    public let triggers = keywords("remind", "提醒", "tixing", "喝水", "站立", "heshui")
    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        [ToolResult(toolID: id, title: L10n.Tools.Reminder.titleRow,
                    symbol: symbol, score: hit.score, action: .openTool(id),
                    source: title, highlight: "", key: "reminder:open")]
    }
}

@MainActor
public struct HostsTool: Tool {
    public init() {}
    public let id = ToolID.hosts
    public let title = "Hosts"
    public let symbol = "network"
    public let capabilities: Set<Capability> = [.fileWrite]
    public let triggers = keywords("hosts", "host")
    public func results(for input: MatchInput, hit: MatchHit) -> [ToolResult] {
        [ToolResult(toolID: id, title: L10n.Tools.Hosts.titleRow,
                    symbol: symbol, score: hit.score, action: .openTool(id),
                    source: title, highlight: "", key: "hosts:open")]
    }
}

@MainActor
public enum BuiltinTools {
    /// 注册顺序即同分时的展示顺序（应用 > 文件 > 工具）。
    public static let ordered: [any Tool] = [
        AppsTool(), FilesTool(), MeetingTool(), OTPTool(), CalcTool(),
        ReminderTool(), HostsTool(), SystemTool(), SettingsTool(),
        QuicklinkTool(), DictionaryTool(),
    ]

    public static func registerAll(into registry: ToolRegistry = .shared) {
        for tool in ordered { registry.register(tool) }
        // 设置面板要读 294 个 appex，放到后台先扫好；否则第一次按键要等它。
        SettingsPaneIndex.shared.prime()
    }
}
