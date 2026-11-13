import Foundation

public struct ToolID: RawRepresentable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: ToolID, rhs: ToolID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public extension ToolID {
    /// 内建工具的 id。工具声明、面板路由、动作键判定、设置页都点名同一个 id，
    /// 不许各处自己拼字符串 —— 两处拼法不一样，关掉的就不是同一件功能。
    static let apps = ToolID("apps")
    static let files = ToolID("files")
    static let meeting = ToolID("meeting")
    static let otp = ToolID("otp")
    static let calc = ToolID("calc")
    static let reminder = ToolID("reminder")
    static let hosts = ToolID("hosts")
    static let system = ToolID("system")
    static let settings = ToolID("settings")
    static let quicklink = ToolID("quicklink")
    static let dictionary = ToolID("dictionary")
}

/// 工具向注册表声明的宿主能力。未声明即拿不到（由 CapabilityGrant 执行）。
public enum Capability: String, CaseIterable, Sendable {
    case clipboardRead
    case clipboardWrite
    case fileRead
    case fileWrite
    case network
    case screenshot
    case accessibility
    case keychain
}

public enum FileTypeFilter: String, Sendable {
    case any
    case file
    case directory
}

public struct MatchInput: Sendable {
    public var text: String?
    public var fileURLs: [URL]
    public var imageURL: URL?

    public init(text: String? = nil, fileURLs: [URL] = [], imageURL: URL? = nil) {
        self.text = text
        self.fileURLs = fileURLs
        self.imageURL = imageURL
    }

    public static let empty = MatchInput()
}

/// 触发语义，沿用 ZTools `cmds` 的五种类型。
public enum TriggerKind: Equatable, Sendable {
    case keyword([String])
    case regex(pattern: String, label: String)
    case text(label: String, minLength: Int)
    case image(label: String)
    case files(label: String, fileType: FileTypeFilter, extensions: [String])
}

public struct MatchHit: Equatable, Sendable {
    public let score: Int
    public let highlight: String?

    public init(score: Int, highlight: String? = nil) {
        self.score = score
        self.highlight = highlight
    }
}

public enum ToolAction: Sendable {
    case none
    case openTool(ToolID)
    case copy(String)
    case reveal(URL?)
    case launchApp(url: URL, appID: String)
    case openFile(URL)
    case openInTerminal(URL)
    /// 把文件/文件夹本身放进剪贴板（写的是文件引用，不是文字），到访达、微信、Word 里 ⌘V 就是复制这些项目。
    case copyItems([URL])
    /// 用 scheme 拉起腾讯会议入会。号码只在内存里流转，不落任何历史。
    case joinMeeting(code: String)
    /// 复制验证码：写完 60 秒后自动清出剪贴板
    case copySecret(String)
    /// 启动器里直接复制 OTP 账户的当前码；执行时才出码，避免结果列表里的码过期
    case copyOTP(UUID)
    case quitApp(appID: String)
    case forceQuitApp(appID: String)
    case relaunchApp(url: URL, appID: String)
    /// 开面板内的别名编辑框，不离开面板；由视图拦下，派发器不处理。
    case editAppAlias(appID: String)
    /// 系统动作，`id` 见 `SystemActionCatalog`。
    case systemAction(String)
    /// 打开任意网址：设置面板的 `x-apple.systempreferences:` 与 Quicklink 的 http(s) 都走这里。
    case openURL(URL)
    /// 跳到词典.app 查这个词。
    case openDictionary(word: String)
    /// 把一段文字塞回输入框接着打，不离开面板（「设定音量…」用它）。
    case prefillQuery(String)

    /// 执行成功后是否收起面板：拷贝类动作要留在原地。
    public var dismissesPanel: Bool {
        switch self {
        case .copy, .copyItems, .copySecret, .editAppAlias, .prefillQuery: return false
        default: return true
        }
    }
}

public struct ToolResult: Identifiable, Sendable {
    public let id: UUID
    public let toolID: ToolID
    public let title: String
    public let subtitle: String
    public let symbol: String
    public var score: Int
    public let action: ToolAction
    /// 行右侧的来源标签，由注册表统一填，工具自己不用管
    public var source: String = ""
    /// 需要在标题里高亮的命中片段
    public var highlight: String?
    /// 有真实图标的结果（目前是应用）用它替换左侧序号方块
    public var iconURL: URL?
    /// 同分时的排序位次：应用 > 文件 > 工具。改顺序只需动这里的数值。
    public var sortPriority: Int = 0
    /// 稳定的行标识。每次查询都会重建 ToolResult，UUID 不能跨渲染保持行状态（图标会闪）。
    public var key: String
    /// 应用行：这个 App 此刻正在运行。退出/重启动作与行上那个点都读它。
    public var isRunning: Bool = false
    /// 多行正文（词典释义）。有值时这一行拉高，正文排在标题下面。
    public var detail: String?

    public init(toolID: ToolID, title: String, subtitle: String = "", symbol: String = "app",
                score: Int = 0, action: ToolAction = .none, id: UUID = UUID(),
                source: String = "", highlight: String? = nil,
                iconURL: URL? = nil, sortPriority: Int = 0, key: String? = nil,
                isRunning: Bool = false, detail: String? = nil) {
        self.id = id
        self.toolID = toolID
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.score = score
        self.action = action
        self.source = source
        self.highlight = highlight
        self.iconURL = iconURL
        self.sortPriority = sortPriority
        self.key = key ?? id.uuidString
        self.isRunning = isRunning
        self.detail = detail
    }
}

public struct TriggerDescriptor: Equatable, Sendable {
    public let code: String
    public let title: String
    public let kind: TriggerKind

    public init(code: String, title: String, kind: TriggerKind) {
        self.code = code
        self.title = title
        self.kind = kind
    }

    /// 纯函数，可单测。返回 nil 表示不命中。
    public func match(_ input: MatchInput) -> MatchHit? {
        switch kind {
        case .keyword(let words):
            guard let query = input.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else { return nil }
            let q = query.lowercased()
            let parts = q.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let head = parts.first.map(String.init)
            let hasArg = parts.count == 2
            var best: Int?
            for word in words {
                let w = word.lowercased()
                guard !w.isEmpty else { continue }
                let score: Int
                if w == q { score = 100 }
                else if hasArg, head == w { score = 90 }
                else if w.hasPrefix(q) { score = 80 }
                else if w.contains(q) { score = 60 }
                else { continue }
                best = max(best ?? 0, score)
            }
            return best.map { MatchHit(score: $0, highlight: hasArg ? head : query) }

        case .regex(pattern: let pattern, label: _):
            guard let text = input.text, !text.isEmpty,
                  let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let found = regex.firstMatch(in: text, range: range),
                  let swift = Range(found.range, in: text) else { return nil }
            return MatchHit(score: 70, highlight: String(text[swift]))

        case .text(_, let minLength):
            guard let text = input.text, text.count >= minLength else { return nil }
            return MatchHit(score: 40, highlight: text)

        case .image(_):
            guard input.imageURL != nil else { return nil }
            return MatchHit(score: 55)

        case .files(label: _, fileType: let fileType, extensions: let extensions):
            guard !input.fileURLs.isEmpty else { return nil }
            if !extensions.isEmpty {
                let allowed = Set(extensions.map { $0.lowercased() })
                let hit = input.fileURLs.contains { allowed.contains($0.pathExtension.lowercased()) }
                guard hit else { return nil }
            }
            switch fileType {
            case .any: return MatchHit(score: 55)
            case .file:
                return input.fileURLs.allSatisfy { !$0.hasDirectoryPath } ? MatchHit(score: 55) : nil
            case .directory:
                return input.fileURLs.allSatisfy(\.hasDirectoryPath) ? MatchHit(score: 55) : nil
            }
        }
    }
}

@MainActor
public protocol Tool {
    var id: ToolID { get }
    var title: String { get }
    var symbol: String { get }
    var capabilities: Set<Capability> { get }
    var triggers: [TriggerDescriptor] { get }
    var isAvailable: Bool { get }
    /// 唤醒词之外的入口（⌘R、拖文件）。设置「功能」页照原样列出来，
    /// 关掉的正是这些入口，所以不能只在文档里写一遍。
    var entries: [String] { get }

    func results(for input: MatchInput, hit: MatchHit) -> [ToolResult]
}

public extension Tool {
    var isAvailable: Bool { true }
    var entries: [String] { [] }
}

public extension TriggerDescriptor {
    /// keyword 触发的逐个词；其余触发类型不产词。
    var keywordWords: [String] {
        if case .keyword(let words) = kind { return words }
        return []
    }

    /// 非关键词触发的一句话：设置「功能」页把它排在真词后面（虚线档）。
    var weakHint: String? {
        switch kind {
        case .keyword: return nil
        case .regex(_, let label): return label
        case .text(let label, let minLength):
            return minLength <= 1
                ? L10n.Tools.Trigger.anyText(label)
                : L10n.Tools.Trigger.minLengthText(minLength, label)
        case .image(let label): return label
        case .files(let label, _, _): return label
        }
    }
}
