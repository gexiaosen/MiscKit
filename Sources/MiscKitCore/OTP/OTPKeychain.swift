import Foundation
import Security

/// 删密钥的三态结果：删掉了 / 钥匙串里本来就没找到 / 真的删失败（例如签名被拒或 IO 错误）。
public enum SecretRemovalStatus: Equatable, Sendable {
    case removed
    case notFound
    case failed
}

/// 密钥存放的抽象。单测注入内存实现，真机走 Keychain —— 这样"删除不留孤儿"
/// 这类不变式可以在测试里断言，不必依赖签名与钥匙串状态。
public protocol SecretStoring: Sendable {
    func secret(for account: String) -> Data?
    @discardableResult func setSecret(_ data: Data, for account: String) -> Bool
    @discardableResult func removeSecret(for account: String) -> Bool
    func removeSecretWithStatus(for account: String) -> SecretRemovalStatus
    /// 同步属性是否真的生效（iCloud 钥匙串没开时会退成本机存储）
    var synchronizesToCloud: Bool { get }
    var lastError: String? { get }
    /// 最近一次读取是**被授权挡下**而不是条目不存在。面板据此说"去点始终允许"，
    /// 而不是把授权被拒误报成"等 iCloud 同步"。
    var authorizationDenied: Bool { get }
    /// 丢掉进程内缓存，让下一次读取重新打钥匙串。面板每次打开时调一次。
    func invalidateSecretCache()
}

public extension SecretStoring {
    func invalidateSecretCache() {}
    var authorizationDenied: Bool { false }
    func removeSecretWithStatus(for account: String) -> SecretRemovalStatus {
        removeSecret(for: account) ? .removed : .failed
    }
}

/// 通用口令条目存储。没有 biometry ACL —— 定案是"同步 + 放弃生物锁定"。
///
/// ⚠ 为什么必须有进程内缓存：OTP 面板用 `TimelineView(.periodic(by: 1))` 每秒重算每一行，
/// 直连钥匙串就等于每秒 N 次访问。而经典钥匙串的条目门禁(gate)在 ad-hoc 与非 Apple 签名下
/// 只认 cdhash（2026-10-21 实测：换自签证书、钉死 requirements 后重建，读自己写的条目
/// 仍返回 -25293），一旦身份变了就是**每次访问都要用户点一次授权**。没有缓存，
/// 16 个账户会放大成每秒 16 个授权框。
///
/// ⚠ 为什么所有密钥合装在一个条目里（`vaultAccount`）：授权弹窗是按**条目**弹的，
/// 不是按应用弹的。12 个账户各存一条 = 一次打开面板 12 个密码框（2026-11-18 老板机器实测）。
/// 合成一条之后，一次授权换整份密钥。ad-hoc 签名下这已经是能做到的下限——每次启动一次。
///
/// 类而不是结构体：要把"同步属性被拒 → 降级成本机存储"与缓存结果写回给自己。
public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    public static let service = "app.misckit.otp"

    /// 合装条目的账户名。故意不用 UUID 形态，永远撞不上真实账户。
    static let vaultAccount = "vault:v1"

    /// 钥匙串命名空间必须跟着 bundle id 分叉：`make-app.sh` 给 debug 产物换了
    /// `.dev` 后缀，而账户元数据在按 bundle id 隔离的 UserDefaults 里。
    /// 无 bundle id 的 `swift run` / 命令行构建用独立 `.cli` 空间——元数据域也是
    /// 进程自己的；落回正式空间会让密钥进正式钥匙串、元数据留在别处，release 包
    /// 就会看到"一个账户都没有"而密钥还在。
    public static var serviceForCurrentBundle: String { keychainService(forBundleID: Bundle.main.bundleIdentifier) }

    /// 纯函数版：`Bundle.main` 在测试里改不动，三条分支只能这样才测得到。
    static func keychainService(forBundleID id: String?) -> String {
        guard let id, !id.isEmpty else { return "\(service).cli" }
        return id.hasSuffix(".dev") ? "\(service).dev" : service
    }

    /// 一种钥匙串访问形态。
    private struct Variant: Equatable {
        let dataProtection: Bool
        let synchronize: Bool
    }

    /// 合装条目的已知状态。`blocked` / `corrupt` 与 `absent` 必须分开：
    /// 把"读不到"当成"没有"，下一次写入就会把整份密钥覆盖掉。
    private enum Vault {
        case unknown
        case absent
        case loaded([String: Data])
        /// 读下来了却解不开（格式变更、数据被截断）。不能被覆盖，但读取可以退回老条目。
        case corrupt
        /// 压根读不到（授权被拒、钥匙串暂时不可用）。既不能覆盖，也**不能**退回逐条读——
        /// 那会把"一次授权"退化回"一次打开十几次弹框"。
        case blocked
    }

    /// 从最好到最兜底：iCloud 同步 → 本机 data-protection → 经典文件钥匙串。
    /// 没有 Apple 签发的身份时前两档吃 errSecMissingEntitlement，只有第三档能用——
    /// 这时功能照常，只是不再同步。
    private static let variants: [Variant] = [
        Variant(dataProtection: true, synchronize: true),
        Variant(dataProtection: true, synchronize: false),
        Variant(dataProtection: false, synchronize: false),
    ]

    private let service: String
    private let accessGroup: String?
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    /// 本进程内确认取不到的条目。不记住的话，面板每秒重算会把同一扇被拒的门再敲一遍。
    private var unreadable: Set<String> = []
    /// 上一次成功写入用的形态；读取优先按它试，避免每次都重走两档注定失败的变体。
    private var knownVariant: Variant?
    private var vault: Vault = .unknown
    private var _synchronizesToCloud: Bool
    private var _lastError: String?
    private var _authorizationDenied = false

    public var synchronizesToCloud: Bool {
        lock.lock(); defer { lock.unlock() }; return _synchronizesToCloud
    }
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }; return _lastError
    }
    public var authorizationDenied: Bool {
        lock.lock(); defer { lock.unlock() }; return _authorizationDenied
    }

    /// `service` 刻意**没有默认值**：选哪个钥匙串空间必须由调用方写出来。
    /// 生产入口只有一个（`OTPStore.shared`），它必须传 `serviceForCurrentBundle`。
    public init(service: String, accessGroup: String? = nil, synchronizesToCloud: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self._synchronizesToCloud = synchronizesToCloud
    }

    // MARK: 读

    public func secret(for account: String) -> Data? {
        lock.lock()
        if let hit = cache[account] { lock.unlock(); return hit }
        if unreadable.contains(account) { lock.unlock(); return nil }
        lock.unlock()

        loadVaultIfNeeded()
        lock.lock()
        switch vault {
        case .loaded(let items):
            if let data = items[account] {
                cache[account] = data
                lock.unlock()
                return data
            }
        case .blocked:
            // 合装条目读不下来（授权被拒 / 暂时故障）：本轮就报没有。
            // 退回逐条读老条目会让 12 个账户各弹一次框——正要修的就是这个。
            lock.unlock()
            return nil
        case .unknown, .absent, .corrupt:
            break
        }
        lock.unlock()

        // 老形态（一账户一条）兜底：升级后头一次读还要靠它。
        // 读到就顺手并进合装条目，并把那条旧条目删掉——不然下次启动又得为它单独授权一次。
        guard let legacy = readLegacy(account: account) else { return nil }
        adopt(legacy, for: account)
        return legacy
    }

    /// 读单条老形态条目。
    private func readLegacy(account: String) -> Data? {
        var lastStatus: OSStatus = errSecItemNotFound
        // 合装条目里的账户不该再逐条去敲：那条老条目可能只是迁移没删干净。
        for variant in orderedVariants() {
            var query = baseQuery(account: account, variant: variant)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                lock.lock()
                cache[account] = data
                knownVariant = variant
                _lastError = nil
                _authorizationDenied = false
                lock.unlock()
                return data
            }
            if status != errSecItemNotFound { lastStatus = status }
        }
        lock.lock()
        // 只把"确定取不到"记进不在场缓存：条目不存在（等同步）、被授权挡下，
        // 或该档钥匙串在当前签名身份下用不了（ad-hoc 的 DP 档）。其余暂时性故障
        // （errSecNotAvailable、IO 错误…）下一拍还要再试，永久判死会让面板
        // 从此报"密钥丢失"，而它其实还在。
        if lastStatus == errSecItemNotFound || lastStatus == errSecMissingEntitlement
            || Self.isAuthorizationRefusal(lastStatus) {
            unreadable.insert(account)
        }
        _lastError = describe(lastStatus)
        _authorizationDenied = Self.isAuthorizationRefusal(lastStatus)
        lock.unlock()
        return nil
    }

    /// 用户点了「拒绝」、或系统压根不许弹框时，条目看起来和"不存在"一模一样，
    /// 但成因完全不同，给出的指引也必须不同。-128 是 MacErrors 的 userCanceled，
    /// Security 这一侧没有对应常量。
    static func isAuthorizationRefusal(_ status: OSStatus) -> Bool {
        [errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired, -128].contains(status)
    }

    // MARK: 写 / 删

    public func setSecret(_ data: Data, for account: String) -> Bool {
        loadVaultIfNeeded()
        if let items = writableVault() {
            var next = items
            next[account] = data
            if persistVault(next) {
                lock.lock()
                cache[account] = data
                unreadable.remove(account)
                _synchronizesToCloud = knownVariant.map { $0.synchronize && $0.dataProtection } ?? false
                _lastError = nil
                lock.unlock()
                return true
            }
        }
        // 合装条目写不进去（体积超限、被拒）：退回一账户一条，功能优先于整齐。
        for variant in orderedVariants() {
            if put(data, account: account, variant: variant) {
                lock.lock()
                cache[account] = data
                unreadable.remove(account)
                knownVariant = variant
                _synchronizesToCloud = variant.synchronize && variant.dataProtection
                _lastError = nil
                lock.unlock()
                return true
            }
        }
        return false
    }

    /// 删除要三档都试：条目可能在降级前后分别写过。
    /// 除了"成功/本来就没有"，`errSecMissingEntitlement` 也算走过——那一档在
    /// 当前签名身份下根本用不了（ad-hoc 实测恒为 -34018），不可能藏着条目。
    /// 其余错误（授权被拒、IO…）说明条目可能还在，此时返回 `.failed`，
    /// 调用方保留元数据，不会留下没人引用的孤儿密钥。
    public func removeSecretWithStatus(for account: String) -> SecretRemovalStatus {
        loadVaultIfNeeded()
        var removed = false
        var failure: OSStatus?

        if let items = writableVault(), items[account] != nil {
            var next = items
            next.removeValue(forKey: account)
            if persistVault(next) { removed = true } else { failure = errSecIO }
        }

        // 老形态的残留一并清掉；删不动就如实报告，不假装干净。
        for variant in Self.variants {
            let status = SecItemDelete(baseQuery(account: account, variant: variant) as CFDictionary)
            switch status {
            case errSecSuccess: removed = true
            case errSecItemNotFound, errSecMissingEntitlement: break
            default: if failure == nil { failure = status }
            }
        }

        if let failure {
            lock.lock(); _lastError = describe(failure); lock.unlock()
            return .failed
        }
        lock.lock()
        cache.removeValue(forKey: account)
        unreadable.remove(account)
        lock.unlock()
        return removed ? .removed : .notFound
    }

    public func removeSecret(for account: String) -> Bool {
        removeSecretWithStatus(for: account) == .removed
    }

    public func invalidateSecretCache() {
        lock.lock()
        cache.removeAll()
        unreadable.removeAll()
        vault = .unknown
        _authorizationDenied = false
        lock.unlock()
    }

    // MARK: 合装条目

    /// 本进程第一次碰钥匙串时读一次合装条目。
    /// 只在 `.unknown` 时动手：`.absent` / `.blocked` 再读一遍没有意义，还会多弹框。
    private func loadVaultIfNeeded() {
        lock.lock()
        let state = vault
        lock.unlock()
        if case .unknown = state {} else { return }

        var lastStatus: OSStatus = errSecItemNotFound
        for variant in orderedVariants() {
            var query = baseQuery(account: Self.vaultAccount, variant: variant)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess {
                if let data = item as? Data, let items = Self.decode(data) {
                    lock.lock()
                    vault = .loaded(items)
                    knownVariant = variant
                    _lastError = nil
                    _authorizationDenied = false
                    lock.unlock()
                    return
                }
                // 读到了却解不开：当成"有东西但不可用"，绝不能按"没有"覆盖掉。
                lastStatus = errSecDecode
                continue
            }
            if status != errSecItemNotFound { lastStatus = status }
        }

        lock.lock()
        switch lastStatus {
        case errSecItemNotFound:
            vault = .absent
        case errSecDecode:
            vault = .corrupt
            _lastError = describe(lastStatus)
        default:
            vault = .blocked
            _lastError = describe(lastStatus)
            _authorizationDenied = Self.isAuthorizationRefusal(lastStatus)
        }
        lock.unlock()
    }

    /// 能安全改写时返回当前内容；`unknown` / `corrupt` / `blocked` 返回 nil——
    /// 内容不明的写入等于把整份密钥抹掉。
    private func writableVault() -> [String: Data]? {
        lock.lock(); defer { lock.unlock() }
        switch vault {
        case .loaded(let items): return items
        case .absent: return [:]
        case .unknown, .corrupt, .blocked: return nil
        }
    }

    private func persistVault(_ items: [String: Data]) -> Bool {
        guard let blob = Self.encode(items) else { return false }
        for variant in orderedVariants() {
            if put(blob, account: Self.vaultAccount, variant: variant) {
                lock.lock(); knownVariant = variant; vault = .loaded(items); lock.unlock()
                return true
            }
        }
        return false
    }

    /// 老条目升进合装条目：先写成功，再删旧条目——顺序反了会在写失败时丢密钥。
    private func adopt(_ data: Data, for account: String) {
        lock.lock()
        var items: [String: Data]
        switch vault {
        case .loaded(let existing): items = existing
        case .absent: items = [:]
        case .unknown, .corrupt, .blocked: lock.unlock(); return
        }
        guard items[account] == nil else { lock.unlock(); return }
        items[account] = data
        vault = .loaded(items)
        cache[account] = data
        lock.unlock()

        guard persistVault(items) else { return }
        Breadcrumbs.event("otp.vault.adopt", ["accounts": String(items.count)])
        for variant in Self.variants {
            SecItemDelete(baseQuery(account: account, variant: variant) as CFDictionary)
        }
    }

    private static func encode(_ items: [String: Data]) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: ["v": 1, "items": items], format: .binary, options: 0)
    }

    private static func decode(_ data: Data) -> [String: Data]? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let items = dict["items"] as? [String: Data] else { return nil }
        return items
    }

    // MARK: 孤儿清理

    /// 钥匙串里存在、但元数据已经不再引用的密钥。只列属性不需要授权（实测 -25293 只发生在
    /// 取数据时），所以枚举是免授权的；删除则看条目脸色，删不动的原样报告，不假装干净。
    public struct SecretPurge: Sendable {
        public let deleted: [String]
        public let refused: [String]
        public var isEmpty: Bool { deleted.isEmpty && refused.isEmpty }
    }

    public func purgeUnreferenced(keeping accounts: Set<String>) -> SecretPurge {
        loadVaultIfNeeded()
        var deleted: [String] = []
        var refused: [String] = []

        // 合装条目里的孤儿：一次改写就清完，不用逐个授权。
        if let items = writableVault() {
            let orphans = items.keys.filter { !accounts.contains($0) }
            if !orphans.isEmpty {
                var next = items
                for key in orphans { next.removeValue(forKey: key) }
                if persistVault(next) { deleted.append(contentsOf: orphans) }
                else { refused.append(contentsOf: orphans) }
            }
        }

        // 历史单条条目的残渣。
        for variant in Self.variants {
            for account in listAccounts(variant: variant)
            where !accounts.contains(account) && account != Self.vaultAccount {
                let status = SecItemDelete(baseQuery(account: account, variant: variant) as CFDictionary)
                switch status {
                case errSecSuccess: deleted.append(account)
                case errSecItemNotFound: break
                default: refused.append(account)
                }
            }
        }
        lock.lock()
        for account in deleted { cache.removeValue(forKey: account); unreadable.remove(account) }
        lock.unlock()
        return SecretPurge(deleted: deleted, refused: refused)
    }

    /// 只取属性不取数据：免授权，能列出全部条目名。
    private func listAccounts(variant: Variant) -> [String] {
        var query = baseQuery(account: nil, variant: variant)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let rows = item as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: 内部

    private func orderedVariants() -> [Variant] {
        lock.lock(); let known = knownVariant; lock.unlock()
        guard let known, let index = Self.variants.firstIndex(of: known) else { return Self.variants }
        return [Self.variants[index]] + Self.variants.filter { $0 != known }
    }

    private func put(_ data: Data, account: String, variant: Variant) -> Bool {
        var attributes = baseQuery(account: account, variant: variant)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // 已存在（例如重复导入、合装条目二次写入）：直接更新数据
            status = SecItemUpdate(baseQuery(account: account, variant: variant) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            lock.lock(); _lastError = describe(status); lock.unlock()
        }
        return status == errSecSuccess
    }

    private func baseQuery(account: String?, variant: Variant) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if variant.dataProtection {
            // macOS 26 上不带这个会走老钥匙串，同步属性会被忽略
            query[kSecUseDataProtectionKeychain as String] = true
        }
        query[kSecAttrSynchronizable as String] = variant.synchronize ? kCFBooleanTrue : kCFBooleanFalse
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? { return message }
        return L10n.OTP.Keychain.error(status)
    }
}

/// 测试与降级路径用的内存实现。
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    public var items: [String: Data] = [:]
    public var synchronizesToCloud: Bool
    public var lastError: String?
    /// 让下一次 setSecret 失败，用来验证"写不进去就不落元数据"
    public var failNextWrite = false
    /// 让下一次 removeSecretWithStatus 失败，用于单测验证密钥删除失败保留元数据。
    public var failNextRemove = false

    public init(synchronizesToCloud: Bool = true) { self.synchronizesToCloud = synchronizesToCloud }

    public func secret(for account: String) -> Data? { items[account] }

    @discardableResult
    public func setSecret(_ data: Data, for account: String) -> Bool {
        if failNextWrite {
            failNextWrite = false
            lastError = L10n.OTP.Keychain.mockWriteFailed
            return false
        }
        items[account] = data
        return true
    }

    public func removeSecretWithStatus(for account: String) -> SecretRemovalStatus {
        if failNextRemove {
            failNextRemove = false
            lastError = L10n.OTP.Keychain.deleteFailed
            return .failed
        }
        return items.removeValue(forKey: account) != nil ? .removed : .notFound
    }

    @discardableResult
    public func removeSecret(for account: String) -> Bool {
        removeSecretWithStatus(for: account) == .removed
    }
}
