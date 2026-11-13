import Foundation
import Observation

/// 一次动作键按下的结果。
public struct HotkeyOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 真的做了事
        case done
        /// 不需要做（本来就是这个状态）——不报错，也不白弹一次授权窗
        case skipped
        /// 想做但没做成
        case failed
    }

    public let key: String
    public let status: Status
    /// 给用户看的一句话。`nil` 表示安静成功。
    public let message: String?

    public init(key: String, status: Status, message: String?) {
        self.key = key
        self.status = status
        self.message = message
    }

    public var isFailure: Bool { status == .failed }
}

/// 键名 → 该做的事。所有动作键只走这一个入口，视图和 App 都不许自己解释键名。
///
/// 两条原则：
/// - 同步。唤起键的响应路径不能因为分发多一次调度，所以判定与选择都在这里做完，
///   真正耗时的写盘交给 `handlers`，完成后再用 `report` 补一条结果。
/// - 决策留在 Core、副作用注入出去，才能在单测里覆盖「目标已被删 / 本来就是这个
///   状态 / 剪贴板写不进去」这些分支，而不必真的启动 App、改 hosts、动用户剪贴板。
@MainActor
@Observable
public final class HotkeyDispatcher {
    public static let shared = HotkeyDispatcher()

    /// 副作用出口。默认值一律是"什么都没做"，忘了接线时表现为没有反应而不是崩。
    public struct Handlers {
        public var summon: () -> Void = {}
        /// 启动应用。失败由实现方 `report`，这里不阻塞。
        public var launch: (String) -> Void = { _ in }
        /// 把当前选择写进 hosts（可能触发系统授权）。写盘是异步的，结果由实现方
        /// 用 `report` 补一条——所以这里只表示"已经交给它了"。
        public var writeHosts: (UUID) -> Void = { _ in }
        /// 返回 false 表示没写进剪贴板。
        public var copySecret: (String) -> Bool = { _ in false }

        public init() {}
    }

    public var handlers = Handlers()
    public var hosts: HostsStore = .shared
    public var otp: OTPStore = .shared
    public var appLookup: (String) -> InstalledApp? = { AppIndex.shared.app(withID: $0) }
    /// 功能开关的取数口，指注册表那一处闸口。
    /// 关掉的功能，它绑的动作键也不能执行 —— 动作键是在看不见界面的情况下按的，
    /// 界面已经没了而键还灵，用户只会以为开关是假的。
    public var isFeatureOn: (ToolID) -> Bool = { ToolRegistry.shared.isEnabled($0) }

    /// 设置页显示"最后一次动作"用；只留最新一条，不做历史。
    public private(set) var lastOutcome: HotkeyOutcome?

    /// 生产用 `.shared`；测试用独立实例，免得互相踩 handlers。
    public init() {}

    public func dispatch(key: String) -> HotkeyOutcome {
        report(route(key))
    }

    /// 异步副作用完成后补记结果（启动 App、写 hosts）。
    @discardableResult
    public func report(_ outcome: HotkeyOutcome) -> HotkeyOutcome {
        lastOutcome = outcome
        return outcome
    }

    private func route(_ key: String) -> HotkeyOutcome {
        switch HotkeyKeys.target(for: key) {
        case .summon:
            handlers.summon()
            return HotkeyOutcome(key: key, status: .done, message: nil)

        case .app(let bundleID):
            guard isFeatureOn(.apps) else { return failure(key, L10n.Hotkey.Dispatch.appDisabled) }
            guard let app = appLookup(bundleID) else {
                return failure(key, L10n.Hotkey.Dispatch.appMissing(bundleID))
            }
            handlers.launch(bundleID)
            return HotkeyOutcome(key: key, status: .done, message: L10n.Hotkey.Dispatch.launching(app.name))

        case .hostsSection(let id):
            guard isFeatureOn(.hosts) else { return failure(key, L10n.Hotkey.Dispatch.hostsDisabled) }
            return selectHostsSection(id, key: key)

        case .otpIssuer(let issuer):
            guard isFeatureOn(.otp) else { return failure(key, L10n.Hotkey.Dispatch.otpDisabled) }
            return copyOTPCode(issuer: issuer, key: key)

        case nil:
            return failure(key, L10n.Hotkey.Dispatch.unknownTarget(key))
        }
    }

    private func selectHostsSection(_ id: UUID, key: String) -> HotkeyOutcome {
        let store = hosts
        if !store.hasLoaded { store.ensureLoaded() }
        guard let section = store.sections.first(where: { $0.id == id }) else {
            return failure(key, L10n.Hotkey.Dispatch.hostsMissing)
        }
        guard !store.isApplying else {
            return failure(key, L10n.Hotkey.Dispatch.hostsBusy)
        }
        // 本来就是这个状态就什么都不做：写了也是同样的内容，却会白弹一次授权窗。
        guard store.selectSectionExclusive(id) else {
            return HotkeyOutcome(key: key, status: .skipped,
                                 message: L10n.Hotkey.Dispatch.hostsAlreadyActive(section.name))
        }
        handlers.writeHosts(id)
        return HotkeyOutcome(key: key, status: .done, message: L10n.Hotkey.Dispatch.hostsSelected(section.name))
    }

    private func copyOTPCode(issuer: String, key: String) -> HotkeyOutcome {
        let matches = otp.accounts.filter {
            $0.issuer.compare(issuer, options: .caseInsensitive) == .orderedSame
        }
        guard let account = matches.first else {
            return failure(key, L10n.Hotkey.Dispatch.otpMissing(issuer))
        }
        guard let code = otp.code(for: account) else {
            return failure(key, L10n.Hotkey.Dispatch.otpSecretMissing(account.displayName))
        }
        guard handlers.copySecret(code) else {
            return failure(key, L10n.Hotkey.Dispatch.clipboardFailed)
        }
        if account.kind == .hotp { otp.advanceCounter(account) }
        // 只说复制了哪个账户，绝不把码本身写进任何提示里。
        return HotkeyOutcome(key: key, status: .done, message: L10n.Hotkey.Dispatch.otpCopied(account.displayName))
    }

    private func failure(_ key: String, _ message: String) -> HotkeyOutcome {
        HotkeyOutcome(key: key, status: .failed, message: message)
    }
}
