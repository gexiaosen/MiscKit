import AppKit
import Foundation

/// 结果行上的一个动作。右键菜单与输入框「对象 动作词」匹配读同一份声明 ——
/// 两处各写一遍，新加的动作就只会出现在其中一个入口。
public struct RowAction: Sendable {
    public let code: String
    private let staticTitle: String
    private let titleKey: String?
    public var title: String {
        if let titleKey { return L10n.tr(titleKey) }
        return staticTitle
    }
    /// 输入框里打什么能命中它：中文、拼音、英文都收。
    public let words: [String]
    public let isDestructive: Bool
    /// 右键菜单里给、输入框「对象 动作词」里不给。拷贝路径就是这种：右键本来就有，打字是重复入口。
    public let matchesInInput: Bool

    public init(code: String, title: String, titleKey: String? = nil, words: [String],
                isDestructive: Bool = false, matchesInInput: Bool = true) {
        self.code = code
        self.staticTitle = title
        self.titleKey = titleKey
        self.words = words
        self.isDestructive = isDestructive
        self.matchesInInput = matchesInInput
    }
}

public enum RowActionCatalog {
    /// 数组顺序即右键菜单里的顺序。
    public static let app: [RowAction] = [
        RowAction(code: "open", title: "打开", titleKey: "rowaction.open",
                  words: ["打开", "open", "dakai", "dk"]),
        RowAction(code: "reveal", title: "在访达中显示", titleKey: "rowaction.reveal",
                  words: ["访达", "显示", "finder", "reveal", "fangda", "xs"]),
        RowAction(code: "copyPath", title: "拷贝路径", titleKey: "rowaction.copyPath",
                  words: ["拷贝路径", "路径", "copy", "path", "lujing", "lj"],
                  matchesInInput: false),
        RowAction(code: "terminal", title: "在终端打开", titleKey: "rowaction.terminal",
                  words: ["终端", "terminal", "zhongduan", "zd"]),
        RowAction(code: "alias", title: "设置别名", titleKey: "rowaction.alias",
                  words: ["别名", "alias", "bieming", "bm"]),
        RowAction(code: "quit", title: "退出", titleKey: "rowaction.quit",
                  words: ["退出", "quit", "tuichu", "tc"]),
        RowAction(code: "relaunch", title: "重启", titleKey: "rowaction.relaunch",
                  words: ["重启", "relaunch", "restart", "chongqi", "cq"]),
        RowAction(code: "forceQuit", title: "强制退出", titleKey: "rowaction.forceQuit",
                  words: ["强制退出", "强制", "force", "qiangzhi", "qz"],
                  isDestructive: true),
    ]

    /// 「chrome 拷」→ (chrome, 拷)。只切最后一刀：对象名自己可能带空格
    /// （`Adobe Photoshop 拷`），动作词则永远是一段。
    public static func split(_ query: String) -> (object: String, action: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = trimmed.lastIndex(where: \.isWhitespace) else { return nil }
        let object = String(trimmed[..<cut]).trimmingCharacters(in: .whitespaces)
        let action = String(trimmed[trimmed.index(after: cut)...])
            .trimmingCharacters(in: .whitespaces)
        guard !object.isEmpty, !action.isEmpty else { return nil }
        return (object, action)
    }

    /// 前缀优于包含，档位与 `TriggerDescriptor` 的关键词一致，两个入口手感不许分叉。
    /// 同分保持声明顺序：`sort` 不稳定，拿声明位次当末位判据。
    public static func match(_ term: String, in actions: [RowAction] = app) -> [RowAction] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(rank: Int, index: Int, action: RowAction)] = []
        for (index, action) in actions.enumerated() where action.matchesInInput {
            let rank = score(of: action, for: q)
            if rank > 0 { scored.append((rank, index, action)) }
        }
        scored.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            return lhs.index < rhs.index
        }
        return scored.map(\.action)
    }

    private static func score(of action: RowAction, for q: String) -> Int {
        var best = 0
        for word in action.words {
            let w = word.lowercased()
            if w == q { best = max(best, 100) }
            else if w.hasPrefix(q) { best = max(best, 80) }
            else if w.contains(q) { best = max(best, 60) }
        }
        return best
    }

    /// 一次查询里所有行共用一份快照：`runningApplications` 每次都要问一趟窗口服务器，
    /// 逐行去问等于每敲一个字问八遍。
    public struct RunningSnapshot {
        private let bundleIDs: Set<String>
        private let paths: Set<String>

        public init() {
            var ids = Set<String>()
            var paths = Set<String>()
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                if let id = app.bundleIdentifier { ids.insert(id) }
                if let url = app.bundleURL { paths.insert(url.standardizedFileURL.path) }
            }
            bundleIDs = ids
            self.paths = paths
        }

        /// appID 的两种形态（bundle id / 包路径）沿用 `ActionDispatcher.matchesAppID` 那一条约定。
        public func contains(_ app: InstalledApp) -> Bool {
            if let id = app.bundleID, bundleIDs.contains(id) { return true }
            return paths.contains(app.url.standardizedFileURL.path)
        }
    }

    /// 退出/重启只对正在运行的应用成立，两个入口都从这里取可用动作。
    public static func available(isRunning: Bool) -> [RowAction] {
        guard isRunning else {
            return self.app.filter { !["quit", "relaunch", "forceQuit"].contains($0.code) }
        }
        return self.app
    }

    /// 动作 → 可执行动作。右键与输入框两条路都从这里取，执行语义只有一处。
    /// `alias` 要开面板内的编辑框，由视图拦下（与 `openTool` 同一条路）。
    public static func toolAction(_ code: String, for app: InstalledApp) -> ToolAction {
        switch code {
        case "open": return .launchApp(url: app.url, appID: app.id)
        case "reveal": return .reveal(app.url)
        case "copyPath": return .copy(app.url.path)
        // .app 本身是目录，直接交给 openInTerminal 会 cd 进包里面；要的是它所在的文件夹。
        case "terminal": return .openInTerminal(app.url.deletingLastPathComponent())
        case "alias": return .editAppAlias(appID: app.id)
        case "quit": return .quitApp(appID: app.id)
        case "relaunch": return .relaunchApp(url: app.url, appID: app.id)
        case "forceQuit": return .forceQuitApp(appID: app.id)
        default: return .none
        }
    }
}