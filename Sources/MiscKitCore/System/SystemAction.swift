import Foundation

public enum SystemActionGroup: String, CaseIterable, Sendable {
    case power, media, volume, desktop, finder

    public var label: String {
        L10n.System.group(rawValue)
    }
}

/// 一条系统动作。`id` 是稳定 code，落进 `ToolAction` 里跨层传递；
/// 标题与别名只用于展示和输入框匹配，改文案不会动执行语义。
public struct SystemAction: Sendable, Identifiable, Hashable {
    public let id: String
    private let staticTitle: String
    private let usesLocalizedTitle: Bool
    public var title: String {
        usesLocalizedTitle ? L10n.System.action(id) : staticTitle
    }
    public let words: [String]
    public let group: SystemActionGroup
    public let symbol: String

    public init(id: String, title: String, words: [String],
                group: SystemActionGroup, symbol: String, usesLocalizedTitle: Bool = false) {
        self.id = id
        self.staticTitle = title
        self.usesLocalizedTitle = usesLocalizedTitle
        self.words = words
        self.group = group
        self.symbol = symbol
    }
}

public enum SystemActionCatalog {
    /// 声明顺序 = 列表顺序。全部零 TCC 授权：不弹任何权限框，装完即用。
    public static let all: [SystemAction] = [
        SystemAction(id: "lock-screen", title: "锁定屏幕",
                     words: ["锁屏", "锁定屏幕", "lock", "suoping", "sp"],
                     group: .power, symbol: "lock.fill", usesLocalizedTitle: true),
        SystemAction(id: "sleep", title: "睡眠",
                     words: ["睡眠", "休眠", "sleep", "shuimian", "sm"],
                     group: .power, symbol: "moon.zzz.fill", usesLocalizedTitle: true),
        SystemAction(id: "display-sleep", title: "关闭显示器",
                     words: ["息屏", "关闭显示器", "关屏", "display sleep", "xiping", "xp"],
                     group: .power, symbol: "display", usesLocalizedTitle: true),
        SystemAction(id: "screen-saver", title: "屏幕保护",
                     words: ["屏保", "屏幕保护", "screensaver", "pingbao", "pb"],
                     group: .power, symbol: "sparkles", usesLocalizedTitle: true),

        SystemAction(id: "play-pause", title: "播放 / 暂停",
                     words: ["播放", "暂停", "play", "pause", "bofang", "zanting", "bf"],
                     group: .media, symbol: "playpause.fill", usesLocalizedTitle: true),
        SystemAction(id: "previous-track", title: "上一曲",
                     words: ["上一曲", "上一首", "previous", "prev", "shangyiqu", "syq"],
                     group: .media, symbol: "backward.fill", usesLocalizedTitle: true),
        SystemAction(id: "next-track", title: "下一曲",
                     words: ["下一曲", "下一首", "next", "xiayiqu", "xyq"],
                     group: .media, symbol: "forward.fill", usesLocalizedTitle: true),

        SystemAction(id: "mute", title: "静音 / 取消静音",
                     words: ["静音", "取消静音", "mute", "unmute", "jingyin", "jy"],
                     group: .volume, symbol: "speaker.slash.fill", usesLocalizedTitle: true),
        SystemAction(id: "mic-mute", title: "麦克风静音",
                     words: ["麦克风静音", "麦克风", "microphone", "maikefeng", "mkf"],
                     group: .volume, symbol: "mic.slash.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-up", title: "音量 +",
                     words: ["音量加", "大声", "volume up", "yinliangjia"],
                     group: .volume, symbol: "speaker.plus.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-down", title: "音量 −",
                     words: ["音量减", "小声", "volume down", "yinliangjian"],
                     group: .volume, symbol: "speaker.minus.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-0", title: "音量 0%",
                     words: ["音量0", "音量 0", "volume 0"],
                     group: .volume, symbol: "speaker.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-25", title: "音量 25%",
                     words: ["音量25", "音量 25", "volume 25"],
                     group: .volume, symbol: "speaker.wave.1.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-50", title: "音量 50%",
                     words: ["音量50", "音量 50", "volume 50"],
                     group: .volume, symbol: "speaker.wave.2.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-75", title: "音量 75%",
                     words: ["音量75", "音量 75", "volume 75"],
                     group: .volume, symbol: "speaker.wave.3.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-100", title: "音量 100%",
                     words: ["音量100", "音量 100", "volume 100"],
                     group: .volume, symbol: "speaker.wave.3.fill", usesLocalizedTitle: true),
        SystemAction(id: "volume-set", title: "设定音量…",
                     words: ["设定音量", "音量设置", "set volume"],
                     group: .volume, symbol: "slider.horizontal.3", usesLocalizedTitle: true),

        SystemAction(id: "show-desktop", title: "显示桌面",
                     words: ["显示桌面", "桌面", "show desktop", "xianshizhuomian"],
                     group: .desktop, symbol: "desktopcomputer", usesLocalizedTitle: true),
        SystemAction(id: "hide-others", title: "隐藏其他 App",
                     words: ["隐藏其他", "隐藏其他app", "hide others", "yincangqita"],
                     group: .desktop, symbol: "eye.slash.fill", usesLocalizedTitle: true),
        SystemAction(id: "unhide-all", title: "取消隐藏全部",
                     words: ["取消隐藏", "显示全部", "unhide all", "quxiaoyincang"],
                     group: .desktop, symbol: "eye.fill", usesLocalizedTitle: true),

        SystemAction(id: "open-trash", title: "打开废纸篓",
                     words: ["废纸篓", "垃圾篓", "trash", "feizhilou", "fzl"],
                     group: .finder, symbol: "trash", usesLocalizedTitle: true),
        SystemAction(id: "eject-volumes", title: "推出所有磁盘",
                     words: ["推出磁盘", "推出所有磁盘", "eject", "tuichucipan"],
                     group: .finder, symbol: "eject.fill", usesLocalizedTitle: true),
    ]

    public static func action(id: String) -> SystemAction? {
        all.first { $0.id == id }
    }

    /// 档位与 `TriggerDescriptor` 的关键词一致：整词 100、前缀 80、包含 60。
    /// 同分保持声明顺序（`sort` 不稳定，拿声明位次当末位判据）。
    public static func match(_ term: String) -> [SystemAction] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(rank: Int, index: Int, action: SystemAction)] = []
        for (index, action) in all.enumerated() {
            var best = 0
            for word in action.words {
                let w = word.lowercased()
                if w == q { best = max(best, 100) }
                else if w.hasPrefix(q) { best = max(best, 80) }
                else if w.contains(q) { best = max(best, 60) }
            }
            if best > 0 { scored.append((best, index, action)) }
        }
        scored.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank > rhs.rank
        }
        return scored.map(\.action)
    }
}
