import Foundation

/// Google Authenticator（以及 anduin 等兼容工具）的批量迁移链接：
/// `otpauth-migration://offline?data=<base64 protobuf>`，一条链接里能装几十个账户。
///
/// 字段号取自按 Google Authenticator 5.10 反推出来的 `OtpMigration.proto`：
/// MigrationPayload{otp_parameters=1, version=2, batch_size=3, batch_index=4, batch_id=5}
/// OtpParameters{secret=1(bytes), name=2, issuer=3, algorithm=4, digits=5, type=6, counter=7}
/// Algorithm{SHA1=1, SHA256=2, SHA512=3, MD5=4} DigitCount{SIX=1, EIGHT=2} OtpType{HOTP=1, TOTP=2}
/// 这个格式没有 period 字段，Google 一律 30 秒。
public enum OTPMigration {
    public static let scheme = "otpauth-migration://"

    public struct Payload: Equatable, Sendable {
        public var entries: [OTPEntry]
        public var version: Int
        public var batchSize: Int
        public var batchIndex: Int
        public var batchID: Int
    }

    /// 一组被拆成多张二维码的导出。`indexes` 是已收到的批次下标；
    /// 同一批的多张图在不同入口（逐张选图/拖入）分别解析后，由界面合并到这里。
    public struct BatchProgress: Equatable, Sendable {
        public var batchID: Int
        public var size: Int
        public var indexes: Set<Int>

        public init(batchID: Int, size: Int, indexes: Set<Int> = []) {
            self.batchID = batchID
            self.size = size
            self.indexes = indexes
        }

        public var isComplete: Bool { size > 0 && indexes.count >= size }
    }

    public enum MigrationError: LocalizedError, Equatable {
        case notMigrationLink
        case missingData
        case truncated
        case encrypted
        case noAccounts
        case unsupportedAlgorithm(Int)
        case emptySecret

        public var errorDescription: String? {
            switch self {
            case .notMigrationLink: return L10n.OTP.Migration.notLink
            case .missingData: return L10n.OTP.Migration.missingData
            case .truncated: return L10n.OTP.Migration.truncated
            case .encrypted: return L10n.OTP.Migration.encrypted
            case .noAccounts: return L10n.OTP.Migration.noAccounts
            case .unsupportedAlgorithm(let raw): return L10n.OTP.Migration.unsupportedAlgorithm(Int32(raw))
            case .emptySecret: return L10n.OTP.Migration.emptySecret
            }
        }
    }

    // MARK: 入口

    /// 从一段文本里抓出所有迁移链接，逐条解；多条时按 batch_id 合并成一次导入。
    public static func decodeAll(from text: String, now: Date = Date())
        -> (entries: [OTPEntry], failures: [OTPFailure], batches: [BatchProgress]) {
        var entries: [OTPEntry] = []
        var failures: [OTPFailure] = []
        var batches: [Int: BatchProgress] = [:]
        for link in migrationLinks(in: text) {
            switch decode(uri: link, now: now) {
            case .success(let payload):
                entries.append(contentsOf: payload.entries)
                // 单张导出不需要进度提示；多张才需要知道缺哪几张。
                guard payload.batchSize > 1 else { continue }
                var progress = batches[payload.batchID]
                    ?? BatchProgress(batchID: payload.batchID, size: payload.batchSize)
                progress.size = max(progress.size, payload.batchSize)
                progress.indexes.insert(payload.batchIndex)
                batches[payload.batchID] = progress
            case .failure(let error):
                failures.append(OTPFailure(label: L10n.OTP.Migration.batchLink,
                                           reason: error.errorDescription ?? L10n.OTP.unparseable))
            }
        }
        return (entries, failures, batches.values.sorted { $0.batchID < $1.batchID })
    }

    public static func decode(uri: String, now: Date = Date()) -> Result<Payload, MigrationError> {
        guard uri.lowercased().hasPrefix(scheme) else { return .failure(.notMigrationLink) }
        guard let components = URLComponents(string: uri),
              let data = components.queryItems?.first(where: { $0.name.lowercased() == "data" })?.value,
              !data.isEmpty else { return .failure(.missingData) }
        // 有的导出工具会给 base64 加换行或省掉 padding
        let cleaned = data.filter { !$0.isNewline && $0 != " " && $0 != "\t" }
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        guard let raw = Data(base64Encoded: padded) else { return .failure(.truncated) }
        return decode(payload: raw, now: now)
    }

    static func decode(payload raw: Data, now: Date = Date()) -> Result<Payload, MigrationError> {
        var payload = Payload(entries: [], version: 0, batchSize: 0, batchIndex: 0, batchID: 0)
        var reader = ProtoReader(raw)
        while let field = reader.next() {
            switch (field.number, field.wire) {
            case (1, .bytes):
                switch entry(from: Data(field.bytes), now: now) {
                case .success(let entry): payload.entries.append(entry)
                case .failure(let error): return .failure(error)
                }
            case (2, .varint): payload.version = Int(field.varint)
            // 明文格式里 version 一定是 varint；这里是长度型，说明是带口令的加密导出
            case (2, .bytes): return .failure(.encrypted)
            case (3, .varint): payload.batchSize = Int(field.varint)
            case (4, .varint): payload.batchIndex = Int(field.varint)
            case (5, .varint): payload.batchID = Int(field.varint)
            default: break  // 未知字段按 protobuf 约定跳过
            }
        }
        // 读到一半断了不能把"已经读出来的部分"当完整结果：用户会以为整批都导进来了
        if reader.isCorrupt { return .failure(.truncated) }
        if payload.entries.isEmpty { return .failure(.noAccounts) }
        return .success(payload)
    }

    /// 迁移链接里不含 `otpauth://` 这个子串，所以和平时的逐条链接互不干扰。
    /// 切结束符时不能按 RFC 字符集：base64 本身不含下面这些，但聊天文本里紧跟其后的会有。
    private static let linkDelimiters: Set<Character> = ["\n", "\r", " ", "\t", ";", ",", "；", "，",
                                                         "。", "、", "（", "）", "\"", "'", "<", ">", "&"]

    private static func migrationLinks(in text: String) -> [String] {
        var links: [String] = []
        let lowered = text.lowercased()
        var search = lowered.startIndex
        while let found = lowered.range(of: scheme, range: search..<lowered.endIndex) {
            let tail = text[found.upperBound...]
            links.append(scheme + String(tail.prefix { !linkDelimiters.contains($0) }))
            search = found.upperBound
        }
        return links
    }

    private static func entry(from raw: Data, now: Date) -> Result<OTPEntry, MigrationError> {
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithmRaw = 1
        var digitsRaw = 1
        var typeRaw = 2
        var counter: UInt64 = 0
        var reader = ProtoReader(raw)
        while let field = reader.next() {
            switch (field.number, field.wire) {
            case (1, .bytes): secret = Data(field.bytes)
            case (2, .bytes): name = String(decoding: field.bytes, as: UTF8.self)
            case (3, .bytes): issuer = String(decoding: field.bytes, as: UTF8.self)
            case (4, .varint): algorithmRaw = Int(field.varint)
            case (5, .varint): digitsRaw = Int(field.varint)
            case (6, .varint): typeRaw = Int(field.varint)
            case (7, .varint): counter = field.varint
            default: break
            }
        }
        if reader.isCorrupt { return .failure(.truncated) }
        guard !secret.isEmpty else { return .failure(.emptySecret) }
        let algorithm: OTPAlgorithm
        switch algorithmRaw {
        case 0, 1: algorithm = .sha1
        case 2: algorithm = .sha256
        case 3: algorithm = .sha512
        default: return .failure(.unsupportedAlgorithm(algorithmRaw))
        }
        let digits = digitsRaw == 2 ? 8 : 6
        let kind: OTPKind = typeRaw == 1 ? .hotp : .totp

        // name 常写成 "Issuer:account"；显式的 issuer 字段优先，跟 otpauth:// 的规则一致。
        let label = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let nameIssuer = label.count == 2 ? label[0] : ""
        let account = label.count == 2 ? label[1] : name
        let finalIssuer = issuer.isEmpty ? nameIssuer : issuer
        let finalAccount = account.isEmpty ? finalIssuer : account
        let entry = OTPAccount(kind: kind, issuer: finalIssuer.isEmpty ? finalAccount : finalIssuer,
                               account: finalAccount, algorithm: algorithm, digits: digits,
                               period: 30, counter: counter, keychainAccount: UUID().uuidString,
                               addedAt: now)
        return .success(OTPEntry(account: entry, secret: secret))
    }
}

// MARK: - 最小 protobuf 读取器

/// 只用到 wire type 0/2，其余按长度跳过；不依赖任何 protobuf 运行时。
private struct ProtoReader {
    enum Wire: Int { case varint = 0, fixed64 = 1, bytes = 2, startGroup = 3, endGroup = 4, fixed32 = 5 }

    struct Field {
        let number: Int
        let wire: Wire
        let varint: UInt64
        let bytes: [UInt8]
    }

    private let bytes: [UInt8]
    private var index = 0
    private var failed = false

    init(_ data: Data) { bytes = Array(data) }

    /// 中途读坏（varint 越界、长度超过剩余字节、group）：调用方必须整条判失败，
    /// 不能把断点到失败点之间读到的字段当完整数据用。
    var isCorrupt: Bool { failed }

    mutating func next() -> Field? {
        guard !failed, index < bytes.count else { return nil }
        guard let key = varint() else { failed = true; return nil }
        let number = Int(key >> 3)
        guard number > 0, let wire = Wire(rawValue: Int(key & 7)) else { failed = true; return nil }
        switch wire {
        case .varint:
            guard let value = varint() else { failed = true; return nil }
            return Field(number: number, wire: wire, varint: value, bytes: [])
        case .bytes:
            guard let length = varint(), length <= UInt64(bytes.count - index) else { failed = true; return nil }
            let end = index + Int(length)
            let payload = Array(bytes[index..<end])
            index = end
            return Field(number: number, wire: wire, varint: 0, bytes: payload)
        case .fixed64:
            guard consume(8) else { failed = true; return nil }
            return Field(number: number, wire: wire, varint: 0, bytes: [])
        case .fixed32:
            guard consume(4) else { failed = true; return nil }
            return Field(number: number, wire: wire, varint: 0, bytes: [])
        case .startGroup, .endGroup:
            // proto2 的 group 已经没人用了，遇到就当数据不对
            failed = true
            return nil
        }
    }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private mutating func consume(_ count: Int) -> Bool {
        guard bytes.count - index >= count else { return false }
        index += count
        return true
    }
}
