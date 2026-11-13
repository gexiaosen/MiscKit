import Foundation
import Observation

/// OTP 账户的唯一真相：元数据在 UserDefaults，密钥在 `SecretStoring`。
/// 两者必须同生共死，所以所有写入都走这里，视图不许自己碰钥匙串。
@MainActor
@Observable
public final class OTPStore {
    private let defaults: UserDefaults
    private let secrets: SecretStoring
    private let metadataKey = "otp.accounts.v1"
    private let offsetKey = "otp.driftOffset.v1"

    public private(set) var accounts: [OTPAccount] = []
    /// 用户手动校准的时间偏移（秒）。正数=本机时钟慢了，需要往前拨。
    public var driftOffset: TimeInterval {
        didSet { defaults.set(driftOffset, forKey: offsetKey) }
    }
    public var lastError: String?

    /// iCloud 钥匙串没开时为 false：码照样能出，但不会同步到其他设备。
    public var synchronizesToCloud: Bool { secrets.synchronizesToCloud }

    public static let shared = OTPStore(defaults: .standard,
                                        secrets: KeychainSecretStore(
                                            service: KeychainSecretStore.serviceForCurrentBundle))

    /// 测试用注入点。
    public init(defaults: UserDefaults, secrets: SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
        self.driftOffset = defaults.object(forKey: offsetKey) as? Double ?? 0
        reload()
    }

    public func reload() {
        guard let data = defaults.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([OTPAccount].self, from: data) else {
            accounts = []
            return
        }
        accounts = decoded.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.addedAt < $1.addedAt
        }
    }

    // MARK: 写入

    /// 先落密钥再落元数据：反过来会留下"列表里有名字但密钥没了"的坏条目。
    @discardableResult
    public func add(_ entry: OTPEntry) -> Bool {
        guard secrets.setSecret(entry.secret, for: entry.account.keychainAccount) else {
            lastError = secrets.lastError ?? L10n.OTP.Keychain.writeFailed
            return false
        }
        var account = entry.account
        account.sortIndex = (accounts.map(\.sortIndex).max() ?? -1) + 1
        accounts.append(account)
        persist()
        lastError = nil
        return true
    }

    /// 批量导入。返回成功数与失败原因（只有账户名 + 为什么，绝不含密钥），调用方一次报清。
    public func importEntries(_ entries: [OTPEntry]) -> (added: Int, failures: [OTPFailure]) {
        var added = 0
        var failures: [OTPFailure] = []
        for entry in entries {
            if add(entry) { added += 1 }
            else {
                failures.append(OTPFailure(label: entry.account.displayName,
                                           reason: lastError ?? L10n.OTP.Keychain.writeFailed))
            }
        }
        return (added, failures)
    }

    public func importText(_ text: String) -> (added: Int, failures: [OTPFailure]) {
        let (entries, bad) = OtpAuthURI.parseBatch(text)
        let result = importEntries(entries)
        return (result.added, result.failures + bad)
    }

    public enum DeleteOutcome: Equatable, Sendable {
        case deleted
        case secretMissing
        case failed
    }

    /// 删除：先区分"删掉了 / 本来就没找到 / 真的删失败"，只在删掉时立即动元数据。
    /// "本来就没找到"交给调用方决定要不要进一步从列表清理。
    @discardableResult
    public func deleteWithStatus(_ account: OTPAccount) -> DeleteOutcome {
        switch secrets.removeSecretWithStatus(for: account.keychainAccount) {
        case .removed:
            accounts.removeAll { $0.id == account.id }
            renumber()
            persist()
            lastError = nil
            return .deleted
        case .notFound:
            lastError = L10n.OTP.Keychain.deleteFailed
            return .secretMissing
        case .failed:
            lastError = secrets.lastError ?? L10n.OTP.Keychain.deleteFailed
            return .failed
        }
    }

    /// 删除：密钥删干净才动元数据，避免留下没人引用的孤儿密钥。
    public func delete(_ account: OTPAccount) -> Bool {
        deleteWithStatus(account) == .deleted
    }

    /// 仅当密钥已确认不在钥匙串时，由用户二次确认后从列表中移除坏元数据。
    public func removeFromListIfSecretMissing(_ account: OTPAccount) {
        accounts.removeAll { $0.id == account.id }
        renumber()
        persist()
        lastError = nil
    }

    public func move(_ id: UUID, to index: Int) {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(index, 0), accounts.count - 1)
        accounts.insert(accounts.remove(at: from), at: clamped)
        renumber()
        persist()
    }

    /// 把某条挪到另一条前面（拖拽落点用这个，视图不必自己算下标）。
    /// 搜索态下别调：可见列表是过滤后的，下标对不上全量顺序。
    public func move(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = accounts.firstIndex(where: { $0.id == id }),
              let target = accounts.firstIndex(where: { $0.id == targetID }) else { return }
        var next = accounts
        let moved = next.remove(at: from)
        let insertAt = from < target ? target - 1 : target
        next.insert(moved, at: min(max(insertAt, 0), next.count))
        accounts = next
        renumber()
        persist()
    }

    /// 只动元数据，不碰钥匙串。空白归一成 nil，避免 "" 与 nil 两种"没备注"。
    public func updateNote(_ text: String?, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].note = OTPManualEntry.normalizedNote(text)
        persist()
    }

    private func renumber() {
        for index in accounts.indices { accounts[index].sortIndex = index }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(accounts) { defaults.set(data, forKey: metadataKey) }
    }

    // MARK: 出码

    public func secret(for account: OTPAccount) -> Data? {
        secrets.secret(for: account.keychainAccount)
    }

    /// 面板每次打开时调一次：只在上一轮读取被授权挡下时清缓存，给一次重试机会。
    /// 无条件清会让每次打开都重敲一遍所有门；在每秒重算里清就是授权框雪崩。
    public func refreshSecrets() {
        guard secrets.authorizationDenied else { return }
        secrets.invalidateSecretCache()
    }

    /// TOTP 出码。密钥拿不到时返回 nil（同步未到位 / 被外部删除），不崩也不猜。
    public func code(for account: OTPAccount, date: Date = Date()) -> String? {
        guard let secret = secret(for: account) else { return nil }
        switch account.kind {
        case .totp:
            return TOTP.code(secret: secret, date: date, period: account.period,
                             digits: account.digits, algorithm: account.algorithm,
                             offset: driftOffset)
        case .hotp:
            return HOTP.code(secret: secret, counter: account.counter,
                             digits: account.digits, algorithm: account.algorithm)
        }
    }

    public func secondsRemaining(for account: OTPAccount, date: Date = Date()) -> Int? {
        guard account.kind == .totp, account.period > 0 else { return nil }
        return TOTP.secondsRemaining(date: date, period: account.period, offset: driftOffset)
    }

    /// HOTP 用一次推进一次计数器并落盘，重启后不会重复出同一个码。
    public func advanceCounter(_ account: OTPAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }),
        accounts[index].kind == .hotp else { return }
        accounts[index].counter += 1
        persist()
    }

    // MARK: 展示

    /// 清掉钥匙串里没人引用的密钥（历次验收 seed 留下的残渣）。
    /// 元数据为空时**拒绝执行**：宁可留几条孤儿，也不能把真密钥当孤儿删掉。
    @discardableResult
    public func purgeOrphanSecrets() -> KeychainSecretStore.SecretPurge? {
        guard !accounts.isEmpty, let store = secrets as? KeychainSecretStore else { return nil }
        let result = store.purgeUnreferenced(keeping: Set(accounts.map(\.keychainAccount)))
        if !result.refused.isEmpty {
            lastError = L10n.OTP.Keychain.orphanRefused(result.refused.count)
        }
        return result
    }

    /// 按 issuer 分组，组内保持手动顺序。⌘1..9 的位次就按这个扁平顺序数。
    public var grouped: [(issuer: String, accounts: [OTPAccount])] {
        var order: [String] = []
        var buckets: [String: [OTPAccount]] = [:]
        for account in accounts {
            let key = account.issuer.isEmpty ? L10n.OTP.unnamed : account.issuer
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(account)
        }
        return order.map { (issuer: $0, accounts: buckets[$0] ?? []) }
    }

    /// 搜索命中的扁平列表（跨组），⌘1..9 与它一一对应。
    public func visibleAccounts(matching term: String) -> [OTPAccount] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return accounts }
        return accounts.filter { $0.matches(needle) }
    }

    /// 面板里给的一行摘要：能不能同步、有没有拿不到密钥的条目。
    public var healthNotice: String? {
        let missing = accounts.filter { secret(for: $0) == nil }
        if !missing.isEmpty {
            // 授权被拒和"条目还没同步过来"在界面上长得一样，指出的出路却完全不同
            if secrets.authorizationDenied {
                return L10n.OTP.Health.denied(missing.count)
            }
            return L10n.OTP.Health.missing(missing.count)
        }
        // iCloud 同步与否是签名能力，不是当前账户的健康问题；常驻橙色横幅只会制造焦虑。
        // 这条信息放在导入页的脚注里，按当前签名实际能力显示。
        return nil
    }
}
