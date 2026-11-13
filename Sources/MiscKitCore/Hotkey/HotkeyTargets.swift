import Foundation
import Observation

/// 一行可绑键的目标：设置页只认这个结构，不认它来自哪个功能。
public struct HotkeyTarget: Identifiable, Equatable, Sendable {
    public let key: String
    public var id: String { key }
    public let title: String
    public let detail: String
    public let symbol: String

    public init(key: String, title: String, detail: String = "", symbol: String) {
        self.key = key
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

public enum HotkeyGroupKind: String, CaseIterable, Identifiable, Sendable {
    case panel
    case app
    case hosts
    case otp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .panel: return L10n.Hotkey.Group.panel
        case .app: return L10n.Hotkey.Group.app
        case .hosts: return L10n.Hotkey.Group.hosts
        case .otp: return L10n.Hotkey.Group.otp
        }
    }

    /// 应用有几百个，只列已经绑过的；其余分组本来就少，全列出来才有的选。
    public var listsEveryTarget: Bool { self != .app }

    /// 需要「添加」入口的只有应用：段和账户是在各自面板里建的，不在这里造。
    public var canAddTarget: Bool { self == .app }
}

public struct HotkeyTargetGroup: Identifiable, Equatable, Sendable {
    public let kind: HotkeyGroupKind
    public let targets: [HotkeyTarget]

    public var id: String { kind.id }
    public var title: String { kind.title }

    public init(kind: HotkeyGroupKind, targets: [HotkeyTarget]) {
        self.kind = kind
        self.targets = targets
    }
}

/// 谁可以绑键，由各个功能自己报，设置页不硬编码功能清单。
@MainActor
public enum HotkeyTargets {
    /// 已绑键但目标已经不在清单里的（应用被删、段被改名、issuer 被清空）。
    /// 这些必须看得见，否则用户会以为键还有效。
    public struct Orphan {
        public let key: String
        public let combo: HotkeyCombo
    }

    /// 唤起面板这一行是固定的，不来自任何索引。
    public static var panelTarget: HotkeyTarget {
        HotkeyTarget(key: HotkeyKeys.summon, title: L10n.Hotkey.Target.panel, symbol: "space")
    }

    /// 四组恒定出现：空组也要看得见，否则用户不知道"为什么没有 Hosts 段可绑"。
    /// hosts 段需要 store 已载入，调用方（设置页）负责先 `ensureLoaded()`。
    /// 三个列表都能注入：设置页用默认值（三个 singleton），单测传自己的仓。
    public static func groups(apps: [InstalledApp] = AppIndex.shared.apps,
                              sections: [HostsSection] = HostsStore.shared.sections,
                              accounts: [OTPAccount] = OTPStore.shared.accounts) -> [HotkeyTargetGroup] {
        [
            HotkeyTargetGroup(kind: .panel, targets: [panelTarget]),
            HotkeyTargetGroup(kind: .app, targets: apps
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { HotkeyTarget(key: HotkeyKeys.app($0.id), title: $0.name,
                                    detail: $0.url.path, symbol: "app") }),
            HotkeyTargetGroup(kind: .hosts, targets: sections.map { section in
                HotkeyTarget(key: HotkeyKeys.hostsSection(section.id), title: section.name,
                             detail: section.isBase ? L10n.Hotkey.Target.hostsBase : L10n.Hotkey.Target.hostsOverlay,
                             symbol: "network")
            }),
            HotkeyTargetGroup(kind: .otp, targets: otpIssuers(accounts).map { issuer, count in
                HotkeyTarget(key: HotkeyKeys.otpIssuer(issuer), title: issuer,
                             detail: count > 1 ? L10n.Hotkey.Target.otpMultiple(count) : L10n.Hotkey.Target.otpSingle,
                             symbol: "key.fill")
            }),
        ]
    }

    private static func otpIssuers(_ accounts: [OTPAccount]) -> [(issuer: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for account in accounts {
            let issuer = account.issuer.trimmingCharacters(in: .whitespaces)
            guard !issuer.isEmpty else { continue }
            if counts[issuer] == nil { order.append(issuer) }
            counts[issuer, default: 0] += 1
        }
        return order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { (issuer: $0, count: counts[$0] ?? 1) }
    }

    public static func orphans(settings: AppSettings) -> [Orphan] {
        let known = Set(groups().flatMap(\.targets).map(\.key))
        let indexReady = AppIndex.shared.hasLoaded
        return settings.hotkeys.compactMap { key, combo in
            if known.contains(key) { return nil }
            // 索引还没扫完时不能报"应用已经不在了"——它只是还没被列出来。
            if !indexReady, key.hasPrefix(HotkeyKeys.appPrefix) { return nil }
            return Orphan(key: key, combo: combo)
        }.sorted { $0.key < $1.key }
    }

    /// 这个组合键是不是已经被我们自己占用；返回占用者的名字。
    ///
    /// macOS 没有公开接口能列出**别的 App** 占了哪些键，所以这里只管自己人。
    /// 外部占用只能在注册失败时才发现，那条原因由 HotkeyCenter 记。
    public static func conflict(settings: AppSettings, combo: HotkeyCombo, excluding key: String) -> String? {
        if key != HotkeyKeys.summon, settings.summonCombo == combo {
            return panelTarget.title
        }
        guard let taken = settings.hotkeys.first(where: { $0.key != key && $0.value == combo }) else {
            return nil
        }
        return title(of: taken.key)
    }

    public static func title(of key: String) -> String {
        for group in groups() {
            if let target = group.targets.first(where: { $0.key == key }) { return target.title }
        }
        switch HotkeyKeys.target(for: key) {
        case .app(let bundleID): return bundleID
        case .hostsSection(let id): return HostsStore.shared.sections.first { $0.id == id }?.name ?? L10n.Hotkey.Orphan.section
        case .otpIssuer(let issuer): return issuer
        case .summon, .none: return key
        }
    }
}
