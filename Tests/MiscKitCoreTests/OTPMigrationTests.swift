import Foundation
import Testing
@testable import MiscKitCore

// MARK: - 测试用的最小 protobuf 写入器
// 字段号来自 Google Authenticator 5.10 反推的 OtpMigration.proto：
// OtpParameters{secret=1, name=2, issuer=3, algorithm=4, digits=5, type=6, counter=7}
// MigrationPayload{otp_parameters=1, version=2, batch_size=3, batch_index=4, batch_id=5}

private func pbVarint(_ value: UInt64) -> [UInt8] {
    var rest = value
    var out: [UInt8] = []
    while true {
        let byte = UInt8(rest & 0x7F)
        rest >>= 7
        if rest == 0 { out.append(byte); return out }
        out.append(byte | 0x80)
    }
}

private func pbTag(_ number: Int, _ wire: Int) -> [UInt8] { pbVarint(UInt64(number << 3 | wire)) }

private func pbInt(_ number: Int, _ value: UInt64) -> [UInt8] { pbTag(number, 0) + pbVarint(value) }

private func pbBytes(_ number: Int, _ data: [UInt8]) -> [UInt8] {
    pbTag(number, 2) + pbVarint(UInt64(data.count)) + data
}

private func pbString(_ number: Int, _ text: String) -> [UInt8] { pbBytes(number, Array(text.utf8)) }

private func pbParam(secret: [UInt8], name: String = "", issuer: String = "",
                     algorithm: UInt64 = 1, digits: UInt64 = 1, type: UInt64 = 2,
                     counter: UInt64? = nil) -> [UInt8] {
    var out = pbBytes(1, secret)
    if !name.isEmpty { out += pbString(2, name) }
    if !issuer.isEmpty { out += pbString(3, issuer) }
    out += pbInt(4, algorithm)
    out += pbInt(5, digits)
    out += pbInt(6, type)
    if let counter { out += pbInt(7, counter) }
    return out
}

private func pbPayload(_ params: [[UInt8]], version: UInt64 = 1, batchSize: UInt64 = 1,
                       batchIndex: UInt64 = 0, batchID: UInt64 = 7) -> [UInt8] {
    var out: [UInt8] = []
    for param in params { out += pbBytes(1, param) }
    out += pbInt(2, version)
    out += pbInt(3, batchSize)
    out += pbInt(4, batchIndex)
    out += pbInt(5, batchID)
    return out
}

private func migrationURI(_ payload: [UInt8]) -> String {
    "otpauth-migration://offline?data=" + Data(payload).base64EncodedString()
}

private let sampleSecret: [UInt8] = Array((0..<20).map { UInt8($0 + 1) })

/// 解不出来就直接让用例失败，免得断言里到处摆 `case .success`
private func decodeOK(_ uri: String) throws -> OTPMigration.Payload {
    guard case .success(let payload) = OTPMigration.decode(uri: uri) else {
        Issue.record("这条迁移链接应该能解开")
        throw OTPMigration.MigrationError.noAccounts
    }
    return payload
}


@Suite("OTP：批量迁移链接（otpauth-migration）")
struct OTPMigrationTests {
    @Test("HOTP 条目保留计数器，type=1 认成 hotp")
    func hotpKeepsCounter() throws {
        let uri = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "Old:user",
                                                  type: 1, counter: 42)]))
        let (entries, failures) = OtpAuthURI.parseBatch(uri)
        #expect(failures.isEmpty)
        let entry = try #require(entries.first)
        #expect(entry.account.kind == .hotp)
        #expect(entry.account.counter == 42)
        #expect(entry.account.issuer == "Old")
        #expect(entry.account.account == "user")
    }

    @Test("digits=2 是 8 位，algorithm=3 是 SHA512")
    func digitsAndAlgorithmMapping() throws {
        let uri = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "Big:vault",
                                                  algorithm: 3, digits: 2)]))
        let entry = try #require(OtpAuthURI.parseBatch(uri).entries.first)
        #expect(entry.account.digits == 8)
        #expect(entry.account.algorithm == .sha512)
    }

    @Test("issuer 字段优先于 name 里冒号前那段")
    func issuerFieldWins() throws {
        let uri = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "Whatever:me@x.test",
                                                  issuer: "Real Co")]))
        let entry = try #require(OtpAuthURI.parseBatch(uri).entries.first)
        #expect(entry.account.issuer == "Real Co")
        #expect(entry.account.account == "me@x.test")
    }

    @Test("MD5 不支持时报的是算法编号，不是含糊的解不开")
    func unsupportedAlgorithmIsNamed() {
        let uri = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "X:y", algorithm: 4)]))
        L10n.withLanguage(.zhHans) {
            let (entries, failures) = OtpAuthURI.parseBatch(uri)
            #expect(entries.isEmpty)
            #expect(failures.first?.reason.contains("算法不支持") == true)
            #expect(failures.first?.reason.contains("4") == true)
        }
        L10n.withLanguage(.en) {
            let (entries, failures) = OtpAuthURI.parseBatch(uri)
            #expect(entries.isEmpty)
            #expect(failures.first?.reason.contains("Unsupported algorithm") == true)
            #expect(failures.first?.reason.contains("4") == true)
        }
    }

    @Test("空密钥的条目单独报错，且不回显 base64 内容")
    func emptySecretFailsWithoutLeaking() {
        let uri = migrationURI(pbPayload([pbParam(secret: [])]))
        L10n.withLanguage(.zhHans) {
            let (entries, failures) = OtpAuthURI.parseBatch(uri)
            #expect(entries.isEmpty)
            let text = failures.map(\.displayText).joined()
            #expect(text.contains("密钥是空的"))
            // 展示文案里只有 label + 原因，不能把整条 data 段抄上去
            #expect(!text.contains("otpauth-migration://"))
        }
        L10n.withLanguage(.en) {
            let (entries, failures) = OtpAuthURI.parseBatch(uri)
            #expect(entries.isEmpty)
            let text = failures.map(\.displayText).joined()
            #expect(text.contains("empty secret"))
            #expect(!text.contains("otpauth-migration://"))
        }
    }

    @Test("带口令的加密导出要说是加密，不要说成数据坏了")
    func encryptedPayloadIsRecognised() {
        // 明文格式里 version(2) 一定是 varint；加密格式里 field 2 是 encryption_key（长度型）
        var out: [UInt8] = pbBytes(1, pbParam(secret: sampleSecret, name: "Enc:y"))
        out += pbBytes(2, pbBytes(1, [0x01, 0x02, 0x03]))
        L10n.withLanguage(.zhHans) {
            let (entries, failures) = OtpAuthURI.parseBatch(migrationURI(out))
            #expect(entries.isEmpty)
            #expect(failures.first?.reason.contains("带口令的加密导出") == true)
        }
        L10n.withLanguage(.en) {
            let (entries, failures) = OtpAuthURI.parseBatch(migrationURI(out))
            #expect(entries.isEmpty)
            #expect(failures.first?.reason.contains("Password-protected") == true)
        }
    }

    @Test("base64 被截断时不猜，直接说数据不完整")
    func truncatedBase64() {
        let uri = "otpauth-migration://offline?data=Cj8KFGnEpnTMQ7KDguNWnddy"
        let (entries, failures) = OtpAuthURI.parseBatch(uri)
        #expect(entries.isEmpty)
        #expect(failures.count == 1)
    }

    @Test("protobuf 被截断时整条拒绝，不把读到的半个当完整结果")
    func truncatedPayloadIsRejected() {
        let full = pbPayload([pbParam(secret: sampleSecret, name: "One:a"),
                              pbParam(secret: sampleSecret, name: "Two:b")])
        // 切掉末尾 12 字节：批次元信息全没，最后一条账户的字节也不完整
        let cut = Array(full.prefix(full.count - 12))
        switch OTPMigration.decode(payload: Data(cut)) {
        case .success: Issue.record("截断的数据不能返回成功")
        case .failure(let error): #expect(error == .truncated)
        }
        // 走完整入口：半批账户不能混进导入结果，失败原因要说清是数据不完整
        L10n.withLanguage(.zhHans) {
            let (entries, failures) = OtpAuthURI.parseBatch(migrationURI(cut))
            #expect(entries.isEmpty)
            #expect(failures.contains { $0.reason.contains("截断") })
        }
        L10n.withLanguage(.en) {
            let (entries, failures) = OtpAuthURI.parseBatch(migrationURI(cut))
            #expect(entries.isEmpty)
            #expect(failures.contains { $0.reason.contains("truncated") })
        }
    }

    @Test("只扫到一部分二维码时说清还差几批")
    func partialBatchIsReported() {
        let uri = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "One:a")],
                                         batchSize: 3, batchIndex: 0))
        L10n.withLanguage(.zhHans) {
            let (entries, failures) = OtpAuthURI.parseBatch(uri)
            #expect(entries.count == 1)
            #expect(failures.contains { $0.label == "批量迁移不完整" })
            #expect(failures.first { $0.label == "批量迁移不完整" }?.reason.contains("3 张") == true)
            #expect(failures.first { $0.label == "批量迁移不完整" }?.reason.contains("只有 1 张") == true)
        }
        L10n.withLanguage(.en) {
            let (entries, failures) = OtpAuthURI.parseBatch(uri)
            #expect(entries.count == 1)
            #expect(failures.contains { $0.label == "Incomplete export batch" })
            #expect(failures.first { $0.label == "Incomplete export batch" }?.reason.contains("3 QR") == true)
        }
    }

    @Test("多张二维码分两次解析后，批次进度可以合并到齐")
    func detailedBatchProgressMerges() {
        let firstURI = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "One:a")],
                                              batchSize: 2, batchIndex: 0, batchID: 44))
        let secondURI = migrationURI(pbPayload([pbParam(secret: sampleSecret, name: "Two:b")],
                                               batchSize: 2, batchIndex: 1, batchID: 44))
        let first = OtpAuthURI.parseBatchDetailed(firstURI)
        #expect(first.batches.count == 1)
        #expect(first.batches[0].isComplete == false)
        #expect(first.failures.isEmpty, "详细入口不再为单张扣上一条红色失败")

        let second = OtpAuthURI.parseBatchDetailed(secondURI)
        var merged = first.batches[0]
        merged.size = max(merged.size, second.batches[0].size)
        merged.indexes.formUnion(second.batches[0].indexes)
        #expect(merged.isComplete)
    }

    @Test("三批齐了就不报不完整，条目按批次顺序合并")
    func completeBatchesMerge() throws {
        let payloads = (0..<3).map { index in
            pbPayload([pbParam(secret: sampleSecret, name: "Site:user\(index)")],
                      batchSize: 3, batchIndex: UInt64(index), batchID: 99)
        }
        let text = payloads.map { migrationURI($0) }.joined(separator: "\n")
        let (entries, failures) = OtpAuthURI.parseBatch(text)
        #expect(entries.count == 3)
        #expect(entries.map(\.account.account) == ["user0", "user1", "user2"])
        #expect(failures.isEmpty)
    }

    @Test("每条账户的 Keychain 条目名互不相同")
    func keychainAccountsAreUnique() throws {
        let payloads = (0..<2).map { _ in
            pbPayload([pbParam(secret: sampleSecret, name: "Same:user"),
                       pbParam(secret: sampleSecret, name: "Same:user")])
        }
        let text = payloads.map { migrationURI($0) }.joined(separator: "\n")
        let (entries, _) = OtpAuthURI.parseBatch(text)
        #expect(entries.count == 4)
        #expect(Set(entries.map(\.account.keychainAccount)).count == 4)
    }

    @Test("批次元信息按 proto 字段号读出来")
    func batchMetadata() throws {
        let raw = pbPayload([pbParam(secret: sampleSecret, name: "A:a")], version: 1,
                            batchSize: 2, batchIndex: 1, batchID: 1234)
        let payload = try decodeOK(migrationURI(raw))
        #expect(payload.version == 1)
        #expect(payload.batchSize == 2)
        #expect(payload.batchIndex == 1)
        #expect(payload.batchID == 1234)
        #expect(payload.entries.count == 1)
    }

    @Test("未知字段按 protobuf 约定跳过，不影响已认得的账户")
    func unknownFieldsAreSkipped() throws {
        var payloadBytes = pbBytes(1, pbParam(secret: sampleSecret, name: "Future:a"))
        payloadBytes += pbInt(9, 7)              // 未来新增的顶层 varint 字段
        payloadBytes += pbBytes(10, [1, 2, 3])   // 未来新增的顶层长度型字段
        payloadBytes += pbInt(2, 1)
        payloadBytes += pbInt(3, 1)
        payloadBytes += pbInt(4, 0)
        payloadBytes += pbInt(5, 7)
        let decoded = try decodeOK(migrationURI(payloadBytes))
        #expect(decoded.entries.count == 1)
        #expect(decoded.batchID == 7)
    }
}
