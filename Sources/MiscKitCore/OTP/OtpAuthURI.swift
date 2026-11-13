import Foundation

public enum OTPKind: String, Codable, CaseIterable, Sendable {
    case totp
    case hotp
}

/// 账户元数据。**不含 secret** —— secret 只进 Keychain，这里存它的条目名。
/// 这样即使用户Defaults 被读走也拿不到密钥，列表还能正常渲染。
public struct OTPAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: OTPKind
    public var issuer: String
    public var account: String
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int
    public var counter: UInt64
    /// Keychain 条目的 account 字段
    public var keychainAccount: String
    public var addedAt: Date
    /// 手动排序位次；⌘1..9 复制按"分组显示顺序"算，不看这个
    public var sortIndex: Int
    /// 用户自己的注记（"公司那个"/"备用号"）。可搜索。
    /// 可选而非空串默认值：合成 Codable 对非可选字段遇到缺键会直接抛错，
    /// 而老版本的元数据里根本没有这个键。空串在写入时就被归一成 nil。
    public var note: String?

    public init(id: UUID = UUID(), kind: OTPKind = .totp, issuer: String = "",
                account: String, algorithm: OTPAlgorithm = .sha1, digits: Int = 6,
                period: Int = 30, counter: UInt64 = 0, keychainAccount: String,
                addedAt: Date = .init(), sortIndex: Int = 0, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.issuer = issuer
        self.account = account
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.counter = counter
        self.keychainAccount = keychainAccount
        self.addedAt = addedAt
        self.sortIndex = sortIndex
        self.note = note
    }

    /// 列表与搜索用的显示名：有 issuer 就 "issuer (account)"，跟 Google Authenticator 导出的形态一致。
    public var displayName: String {
        if issuer.isEmpty { return account }
        return account.isEmpty ? issuer : "\(issuer) (\(account))"
    }

    public func matches(_ term: String) -> Bool { matchScore(term) > 0 }

    /// 启动器排序用：完全命中 issuer/账号 > 前缀 > 包含 > 备注。
    /// 返回 0 表示不命中；`matches` 仍保留给工作区做布尔过滤。
    public func matchScore(_ term: String) -> Int {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        let issuer = issuer.lowercased()
        let account = account.lowercased()
        if issuer == needle || account == needle { return 100 }
        if issuer.hasPrefix(needle) || account.hasPrefix(needle) { return 96 }
        if issuer.contains(needle) || account.contains(needle) { return 90 }
        if let note, note.lowercased().contains(needle) { return 84 }
        return 0
    }
}

/// 一条待导入的账户：元数据 + 解好的密钥，还没落盘。
public struct OTPEntry: Equatable, Sendable {
    public var account: OTPAccount
    public var secret: Data

    public init(account: OTPAccount, secret: Data) {
        self.account = account
        self.secret = secret
    }
}

public enum OTPImportError: LocalizedError, Equatable {
    case notOtpauthURI
    case unsupportedKind(String)
    case missingSecret
    case invalidSecret
    case invalidDigits(Int)
    case invalidPeriod(Int)
    case missingCounter
    case missingLabel
    case unsupportedAlgorithm(String)

    public var errorDescription: String? {
        switch self {
        case .notOtpauthURI: return L10n.OTP.URI.notOtpauth
        case .unsupportedKind(let kind): return L10n.OTP.URI.unsupportedKind(kind)
        case .missingSecret: return L10n.OTP.URI.missingSecret
        case .invalidSecret: return L10n.OTP.URI.invalidSecret
        case .invalidDigits(let digits): return L10n.OTP.URI.invalidDigits(digits)
        case .invalidPeriod(let period): return L10n.OTP.URI.invalidPeriod(period)
        case .missingCounter: return L10n.OTP.URI.missingCounter
        case .missingLabel: return L10n.OTP.URI.missingLabel
        case .unsupportedAlgorithm(let name): return L10n.OTP.URI.unsupportedAlgorithm(name)
        }
    }
}

/// 一条导入失败：能拿去显示的最小信息。**绝不含 secret**——失败摘要里回显原文等于
/// 把密钥写在界面、截图和日志里。
public struct OTPFailure: Equatable, Sendable {
    public let label: String
    public let reason: String

    public init(label: String, reason: String) {
        self.label = label
        self.reason = reason
    }

    public var displayText: String { "\(label)：\(reason)" }
}

/// `otpauth://` 解析。密钥合法性交给 `Base32`，这里只管参数取值范围。
public enum OtpAuthURI {
    public static func parse(_ text: String, now: Date = Date()) -> Result<OTPEntry, OTPImportError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://") else { return .failure(.notOtpauthURI) }
        guard let components = URLComponents(string: trimmed),
              let kindRaw = components.host?.lowercased(),
              let kind = OTPKind(rawValue: kindRaw) else {
            return .failure(.notOtpauthURI)
        }
        guard OTPKind.allCases.contains(kind) else { return .failure(.unsupportedKind(kindRaw)) }

        var query = [String: String]()
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }

        guard let secretText = query["secret"], !secretText.isEmpty else { return .failure(.missingSecret) }
        guard let secret = Base32.decode(secretText) else { return .failure(.invalidSecret) }

        // 参数写了但解不出数字时不能悄悄用默认值：那会让用户以为导对了，结果位数不一样。
        let digits: Int
        if let raw = query["digits"] {
            guard let value = Int(raw) else { return .failure(.invalidDigits(-1)) }
            digits = value
        } else {
            digits = 6
        }
        guard digits == 6 || digits == 8 else { return .failure(.invalidDigits(digits)) }

        let period: Int
        if let raw = query["period"] {
            guard let value = Int(raw) else { return .failure(.invalidPeriod(-1)) }
            period = value
        } else {
            period = 30
        }
        guard period > 0 else { return .failure(.invalidPeriod(period)) }

        var counter: UInt64 = 0
        if kind == .hotp {
            guard let raw = query["counter"], let value = UInt64(raw) else { return .failure(.missingCounter) }
            counter = value
        }

        // 写了不认识的算法不能悄悄按 SHA1 算：导入会"成功"，码却永远不对。
        let algorithm: OTPAlgorithm
        if let raw = query["algorithm"] {
            guard let value = OTPAlgorithm(name: raw) else { return .failure(.unsupportedAlgorithm(raw)) }
            algorithm = value
        } else {
            algorithm = .sha1
        }
        let label = label(from: components)
        // issuer 参数优先（Google/Microsoft 都这么给）；没有就用 label 冒号前那段。
        let issuer = nonEmpty(query["issuer"]) ?? nonEmpty(label.issuer) ?? ""
        let account = nonEmpty(label.account) ?? nonEmpty(label.issuer) ?? ""
        let entry = OTPAccount(kind: kind, issuer: issuer, account: account,
                               algorithm: algorithm, digits: digits, period: period,
                               counter: counter, keychainAccount: UUID().uuidString,
                               addedAt: now)
        return .success(OTPEntry(account: entry, secret: secret))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// 路径里的 `Issuer:user@site` 形式；冒号只切第一个，邮箱里的冒号不管。
    private static func label(from components: URLComponents) -> (issuer: String, account: String) {
        let path = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        let decoded = path.removingPercentEncoding ?? path
        let parts = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return ("", decoded.trimmingCharacters(in: .whitespaces))
    }

    /// 批量粘贴：一段文本里可能夹着多条链接和别的文字，逐个抓 `otpauth://` 到下一个空白/分号为止。
    /// 返回成功的与失败的（每条带原因，不带原文），调用方一次报清。
    public static func parseBatch(_ text: String, now: Date = Date())
        -> (entries: [OTPEntry], failures: [OTPFailure]) {
        let detailed = parseBatchDetailed(text, now: now)
        var failures = detailed.failures
        for batch in detailed.batches where !batch.isComplete {
            failures.append(OTPFailure(
                label: L10n.OTP.Import.batchIncompleteLabel,
                reason: L10n.OTP.Import.batchIncompleteReason(batch.size, batch.indexes.count)))
        }
        return (detailed.entries, failures)
    }

    /// 和 `parseBatch` 同一条解析路径，但把批次进度原样交给界面：多张图分别解析后
    /// 可以跨图合并，避免每张都喊一次"不完整"。
    public static func parseBatchDetailed(_ text: String, now: Date = Date())
        -> (entries: [OTPEntry], failures: [OTPFailure], batches: [OTPMigration.BatchProgress]) {
        var entries: [OTPEntry] = []
        var failures: [OTPFailure] = []
        // 从钉钉/微信粘过来的链接后面常跟全角标点，`;` 与 `,` 本身是合法 URI 字符，
        // 所以只能按"聊天文本里的结束符"来切，不能按 RFC 字符集。
        let delimiters: Set<Character> = ["\n", "\r", " ", "\t", ";", ",", "；", "，", "、", "。",
                                          "\"", "'", "<", ">", "（", "）", "(", ")"]
        var search = Substring(text)
        var index = 0
        while let range = search.range(of: "otpauth://", options: .caseInsensitive) {
            index += 1
            let tail = search[range.lowerBound...]
            let uri = tail.dropFirst("otpauth://".count).prefix { !delimiters.contains($0) }
            let candidate = "otpauth://" + String(uri)
            let label = safeLabel(of: candidate, index: index)
            switch parse(candidate, now: now) {
            case .success(let entry): entries.append(entry)
            case .failure(let error): failures.append(OTPFailure(label: label, reason: error.errorDescription ?? L10n.OTP.unparseable))
            }
            search = search[range.upperBound...]
        }
        // 批量迁移链接：一条 `otpauth-migration://` 顶几十条普通链接，Google Authenticator 导出就是这种
        let migration = OTPMigration.decodeAll(from: text, now: now)
        entries.append(contentsOf: migration.entries)
        failures.append(contentsOf: migration.failures)
        if entries.isEmpty, failures.isEmpty,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append(OTPFailure(label: L10n.OTP.Import.pastedLabel,
                                       reason: L10n.OTP.Import.pastedMissingLink))
        }
        return (entries, failures, migration.batches)
    }

    /// 只取 scheme 与 path 里的 label 当标识，query 一律不碰：secret 就在 query 里。
    private static func safeLabel(of candidate: String, index: Int) -> String {
        let fallback = L10n.OTP.accountFallback(index)
        guard let schemeEnd = candidate.range(of: "://") else { return fallback }
        let rest = candidate[schemeEnd.upperBound...]
        let head = String(rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let parts = head.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = parts.count > 1 ? String(parts[1]) : ""
        let decoded = (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? fallback : String(decoded.prefix(40))
    }
}

/// 手工录入：网站只给一串 Base32 密钥、没给 otpauth 链接时的入口。
/// 与链接导入共用同一套校验和同一个 `OTPEntry` 出口，密钥同样只交给 `OTPStore` 落钥匙串，
/// 这里不碰任何持久化。
public enum OTPManualEntry {
    public static func entry(issuer: String, account accountName: String, secret: String,
                             digits: Int = 6, period: Int = 30, note: String? = nil,
                             now: Date = Date()) -> Result<OTPEntry, OTPImportError> {
        let trimmedIssuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedIssuer.isEmpty ? trimmedAccount : trimmedAccount.isEmpty ? trimmedIssuer : trimmedAccount
        guard !label.isEmpty else { return .failure(.missingLabel) }
        guard digits == 6 || digits == 8 else { return .failure(.invalidDigits(digits)) }
        guard period > 0 else { return .failure(.invalidPeriod(period)) }
        // 站点常把密钥写成带空格或连字符的形式，Base32.decode 已经容忍；空串单独拦
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.missingSecret) }
        guard let key = Base32.decode(secret) else { return .failure(.invalidSecret) }

        let account = OTPAccount(issuer: trimmedIssuer, account: label, digits: digits,
                                 period: period, keychainAccount: UUID().uuidString,
                                 addedAt: now, note: normalizedNote(note))
        return .success(OTPEntry(account: account, secret: key))
    }

    /// 空串和纯空白都算"没备注"，不让 "" 和 nil 两种状态并存。
    static func normalizedNote(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
