import AppKit
import Foundation
import Testing

@testable import MiscKitCore

/// RFC 4226 / RFC 6238 的附录向量是唯一的硬依据。这里的期望值先用独立的
/// Python `hmac` 实现算出来再抄进来，避免"实现和测试同一个笔误"。
private let sha1Secret = Data("12345678901234567890".utf8)
private let sha256Secret = Data("12345678901234567890123456789012".utf8)
private let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

@Suite("OTP：Base32 解码")
struct Base32Tests {
    @Test("RFC 4648 附录向量的三种长度都能解回原字节")
    func decodesRFCMasters() {
        #expect(Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") == sha1Secret)
        #expect(Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA====") == sha256Secret)
        #expect(Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA=") == sha512Secret)
    }

    @Test("大小写、空格、连字符与无 padding 都接受")
    func tolerantForms() {
        let upper = "JBSWY3DPEHPK3PXP"
        #expect(Base32.decode(upper.lowercased()) == Base32.decode(upper))
        #expect(Base32.decode("JBSW Y3DP EHPK 3PXP") == Base32.decode(upper))
        #expect(Base32.decode("JBSW-Y3DP-EHPK-3PXP") == Base32.decode(upper))
        #expect(Base32.decode("JBSWY3DPEHPK3PXP====") == Base32.decode(upper))
    }

    @Test("0/1/8/9 与非法长度一律拒绝，不当成密钥")
    func rejectsInvalid() {
        #expect(Base32.decode("JBSWY3DPEHPK3PX0") == nil, "0 不在字母表里（是 O 的形近字）")
        #expect(Base32.decode("JBSWY3DPEHPK3PX1") == nil)
        #expect(Base32.decode("JBSWY3DPEHPK3PX8") == nil)
        #expect(Base32.decode("JBSWY3DPEHPK3PX9") == nil)
        #expect(Base32.decode("A") == nil, "1 个字符凑不出整字节")
        #expect(Base32.decode("ABC") == nil, "3 个字符同理")
        #expect(Base32.decode("ABCDEF") == nil, "6 个字符同理")
        #expect(Base32.decode("") == nil)
        #expect(Base32.decode("====") == nil)
    }

    @Test("末尾残留位必须是 0，截断输入要拒绝")
    func rejectsNonZeroTail() {
        // "MFRA" = 5,5,17,0 → 20bit，最后一组只用了 2bit 有效数据，补出的低位非 0
        #expect(Base32.decode("MFRB") == nil)
        #expect(Base32.decode("MFRA") == Data([0x61, 0x62]), "4 个字符只有 2 个整字节")
    }

    @Test("编码回写与解码互为逆运算")
    func encodeRoundTrip() {
        for length in [1, 2, 3, 4, 5, 10, 16, 20, 32, 64] {
            let data = Data((0..<length).map { UInt8($0 % 251) })
            let encoded = Base32.encode(data)
            #expect(Base32.decode(encoded) == data, "长度 \(length) 往返失败")
        }
    }
}

@Suite("OTP：HOTP 与 TOTP")
struct HOTPTOTPTests {
    private static let rfc4226 = ["755224", "287082", "359152", "969429", "338314",
                                  "254676", "287922", "162583", "399871", "520489"]
    private static let times: [(TimeInterval, [String])] = [
        (59, ["94287082", "46119246", "90693936"]),
        (1_111_111_109, ["07081804", "68084774", "25091201"]),
        (1_111_111_111, ["14050471", "67062674", "99943326"]),
        (1_234_567_890, ["89005924", "91819424", "93441116"]),
        (2_000_000_000, ["69279037", "90698825", "38618901"]),
        (20_000_000_000, ["65353130", "77737706", "47863826"]),
    ]

    @Test("RFC 4226 附录 D：计数器 0…9 全对")
    func hotpVectors() {
        for (counter, expected) in Self.rfc4226.enumerated() {
            let code = HOTP.code(secret: sha1Secret, counter: UInt64(counter))
            #expect(code == expected, "counter=\(counter)")
        }
    }

    @Test("RFC 6238 附录 B：SHA1/256/512 × 六个时刻全对")
    func totpVectors() {
        let algorithms: [OTPAlgorithm] = [.sha1, .sha256, .sha512]
        let secrets: [Data] = [sha1Secret, sha256Secret, sha512Secret]
        for (time, expectedPerAlgorithm) in Self.times {
            for (index, algorithm) in algorithms.enumerated() {
                let date = Date(timeIntervalSince1970: time)
                let code = TOTP.code(secret: secrets[index], date: date, digits: 8,
                                     algorithm: algorithm)
                #expect(code == expectedPerAlgorithm[index],
                        "\(algorithm.rawValue) @ \(Int(time)) 期望 \(expectedPerAlgorithm[index])，实得 \(code ?? "nil")")
            }
        }
    }

    @Test("6 位码是 8 位码的后 6 位（同一截断值取不同模）")
    func sixDigitMatchesTailOfEight() {
        for (time, _) in Self.times {
            let date = Date(timeIntervalSince1970: time)
            let eight = TOTP.code(secret: sha1Secret, date: date, digits: 8) ?? ""
            let six = TOTP.code(secret: sha1Secret, date: date, digits: 6) ?? ""
            #expect(six == String(eight.suffix(6)))
        }
    }

    @Test("9 位拒绝，空 secret 拒绝")
    func rejectsBadArguments() {
        #expect(HOTP.code(secret: sha1Secret, counter: 1, digits: 9) == nil)
        #expect(HOTP.code(secret: Data(), counter: 1) == nil)
        #expect(TOTP.code(secret: sha1Secret, date: .init(timeIntervalSince1970: 59), period: 0) == nil)
    }

    @Test("周期剩余秒数与刷新边界")
    func remainingSeconds() {
        #expect(TOTP.secondsRemaining(date: Date(timeIntervalSince1970: 59), period: 30) == 1)
        #expect(TOTP.secondsRemaining(date: Date(timeIntervalSince1970: 60), period: 30) == 30)
        #expect(TOTP.secondsRemaining(date: Date(timeIntervalSince1970: 61), period: 30) == 29)
    }

    @Test("手动校准的 offset 等于把时间平移")
    func offsetShiftsWindow() {
        let date = Date(timeIntervalSince1970: 1_111_111_111)
        let shifted = TOTP.code(secret: sha1Secret, date: date, digits: 8, offset: 30)
        #expect(shifted == TOTP.code(secret: sha1Secret,
                                     date: Date(timeIntervalSince1970: 1_111_111_141), digits: 8))
    }

    @Test("算法名大小写不敏感")
    func algorithmNames() {
        #expect(OTPAlgorithm(name: "sha1") == .sha1)
        #expect(OTPAlgorithm(name: "SHA512") == .sha512)
        #expect(OTPAlgorithm(name: "md5") == nil)
    }
}

@Suite("OTP：otpauth:// 解析与批量导入")
struct OtpAuthURITests {
    private static let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    private static func uri(_ rest: String) -> String { "otpauth://\(rest)" }

    @Test("标准 label + 参数：issuer、account、算法、位数、周期都落对")
    func parsesStandardTOTP() {
        let result = OtpAuthURI.parse(Self.uri("totp/GitHub:octocat?secret=\(Self.secret)&issuer=GitHub&algorithm=SHA1&digits=6&period=30"))
        guard case .success(let entry) = result else {
            Issue.record("应解析成功")
            return
        }
        #expect(entry.account.kind == .totp)
        #expect(entry.account.issuer == "GitHub")
        #expect(entry.account.account == "octocat")
        #expect(entry.account.digits == 6)
        #expect(entry.account.period == 30)
        #expect(entry.account.algorithm == .sha1)
        #expect(entry.secret == sha1Secret)
        #expect(entry.account.displayName == "GitHub (octocat)")
    }

    @Test("issuer 参数优先于 label 前缀；没有冒号时整段当 account")
    func issuerPrecedence() {
        let withParam = OtpAuthURI.parse(Self.uri("totp/Label:me?secret=\(Self.secret)&issuer=Real"))
        if case .success(let entry) = withParam {
            #expect(entry.account.issuer == "Real")
            #expect(entry.account.account == "me")
        }
        let labelOnly = OtpAuthURI.parse(Self.uri("totp/me%40site.test?secret=\(Self.secret)"))
        if case .success(let entry) = labelOnly {
            #expect(entry.account.issuer == "")
            #expect(entry.account.account == "me@site.test")
            #expect(entry.account.displayName == "me@site.test")
        }
    }

    @Test("8 位 SHA512 的 URI 端到端能出 RFC 6238 的码")
    func endToEndProducesRFCCode() {
        let master = "1234567890123456789012345678901234567890123456789012345678901234"
        let encoded = Base32.encode(Data(master.utf8))
        let result = OtpAuthURI.parse(Self.uri("totp/Test:me?secret=\(encoded)&algorithm=SHA512&digits=8"))
        guard case .success(let entry) = result else { Issue.record("应解析成功"); return }
        let code = TOTP.code(secret: entry.secret, date: Date(timeIntervalSince1970: 59),
                             digits: 8, algorithm: entry.account.algorithm)
        #expect(code == "90693936")
    }

    @Test("hotp 要 counter，给了就用")
    func hotpNeedsCounter() {
        #expect(OtpAuthURI.parse(Self.uri("hotp/x?secret=\(Self.secret)")) == .failure(.missingCounter))
        let ok = OtpAuthURI.parse(Self.uri("hotp/x?secret=\(Self.secret)&counter=42"))
        if case .success(let entry) = ok {
            #expect(entry.account.kind == .hotp)
            #expect(entry.account.counter == 42)
        }
    }

    @Test("非法参数逐条拒绝，不静默改成默认值")
    func rejectsBadParameters() {
        #expect(OtpAuthURI.parse("https://example.test/x") == .failure(.notOtpauthURI))
        #expect(OtpAuthURI.parse(Self.uri("totp/x")) == .failure(.missingSecret))
        #expect(OtpAuthURI.parse(Self.uri("totp/x?secret=!!!!")) == .failure(.invalidSecret))
        #expect(OtpAuthURI.parse(Self.uri("totp/x?secret=\(Self.secret)&digits=7")) == .failure(.invalidDigits(7)))
        #expect(OtpAuthURI.parse(Self.uri("totp/x?secret=\(Self.secret)&period=0")) == .failure(.invalidPeriod(0)))
        #expect(OtpAuthURI.parse(Self.uri("magic/x?secret=\(Self.secret)")) == .failure(.notOtpauthURI))
    }

    @Test("写了不认识的算法要拒绝，不能静默按 SHA1 导入")
    func rejectsUnknownAlgorithm() {
        #expect(OtpAuthURI.parse(Self.uri("totp/x?secret=\(Self.secret)&algorithm=MD5"))
                == .failure(.unsupportedAlgorithm("MD5")))
        #expect(OtpAuthURI.parse(Self.uri("totp/x?secret=\(Self.secret)&algorithm=SHAA1"))
                == .failure(.unsupportedAlgorithm("SHAA1")))
    }

    @Test("小写算法名照常导入，不被当成不认识的算法")
    func algorithmNameIsCaseInsensitive() {
        let result = OtpAuthURI.parse(Self.uri("totp/x?secret=\(Self.secret)&algorithm=sha256"))
        guard case .success(let entry) = result else {
            Issue.record("小写算法名应能导入")
            return
        }
        #expect(entry.account.algorithm == .sha256)
    }

    @Test("scheme、host、参数名大小写都容错")
    func caseInsensitive() {
        let result = OtpAuthURI.parse(Self.uri("TOTP/GitHub:octocat?SECRET=\(Self.secret)&Issuer=GitHub&DIGITS=6"))
        if case .success(let entry) = result {
            #expect(entry.account.issuer == "GitHub")
            #expect(entry.account.digits == 6)
        } else {
            Issue.record("大写形式应能解析")
        }
    }

    @Test("批量粘贴：混在文字里的多条链接都能抓出来，坏的那条单独报")
    func batchImport() {
        let text = """
        我的两个账号，帮我导进来
        otpauth://totp/A:me?secret=\(Self.secret)
        还有这个 otpauth://totp/B:me?secret=\(Self.secret)&digits=8； 以及一个坏的 otpauth://totp/C:me?secret=???
        """
        let (entries, failures) = OtpAuthURI.parseBatch(text)
        #expect(entries.count == 2)
        #expect(entries.map(\.account.issuer) == ["A", "B"])
        #expect(entries[1].account.digits == 8)
        #expect(failures.count == 1)
        // 失败只报"哪一条 + 为什么"，标识取 label，绝不回显带 secret 的原文
        #expect(failures[0].label == "C:me")
        #expect(failures[0].reason.contains("Base32"))
        #expect(!failures[0].displayText.contains("secret="))
    }

    @Test("失败摘要里不能出现密钥本身")
    func failuresNeverLeakSecret() {
        // 17 位是非法 Base32 长度，一定会落到失败列表里
        let text = "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXPQ"
        let (_, failures) = OtpAuthURI.parseBatch(text)
        let line = failures.map(\.displayText).joined(separator: " ")
        #expect(failures.count == 1)
        #expect(!line.contains("JBSWY3DPEHPK3PXPQ"))
        #expect(line.contains("GitHub"))
    }

    @Test("验证器整体导出的 otpauth-migration 链接能直接批量导入")
    func migrationLinkImports() {
        // 真实样例：Google Authenticator 导出的 4 个账户（示例域名，非真实账号）
        let uri = "otpauth-migration://offline?data="
            + "Cj8KFGnEpnTMQ7KDguNWnddyGyCbSVLaEhhBQ01FIENvOmpvaG5AZXhhbXBsZS5jb20aB0FDTUUgQ28gASgBMAIKRAoUXkj+5MY2arwKjsnH2aDsbm6TAlYSG0JldGEgTHRkLjpob21lckBleGFtcGxlLmNvbRoJQmV0YSBMdGQuIAEoATACCkgKFDDFyzUNPgYoI3q/KGHBdcNU9ptWEh1DYXRzICYgRG9nczptYXJnZUBleGFtcGxlLmNvbRoLQ2F0cyAmIERvZ3MgASgBMAIKSAoUunHzbm5h/LUO0yilLMI+dYZY1eISHURhaWx5IEJ1Z2xlOnBldGVyQGV4YW1wbGUuY29tGgtEYWlseSBCdWdsZSABKAEwAhABGAEgACjDnb+uAg=="
        let (entries, failures) = OtpAuthURI.parseBatch(uri)
        #expect(failures.isEmpty)
        #expect(entries.count == 4)
        #expect(entries.map(\.account.issuer) == ["ACME Co", "Beta Ltd.", "Cats & Dogs", "Daily Bugle"])
        #expect(entries.map(\.account.account) == ["john@example.com", "homer@example.com",
                                                   "marge@example.com", "peter@example.com"])
        #expect(entries.allSatisfy { $0.account.kind == .totp })
        #expect(entries.allSatisfy { $0.account.digits == 6 })
        #expect(entries.allSatisfy { $0.account.algorithm == .sha1 })
        #expect(entries.allSatisfy { $0.account.period == 30 })
        #expect(entries[0].secret.count == 20)
        // 密钥原文（base64 段）不能出现在任何展示文案里
        #expect(!failures.map(\.displayText).joined().contains("Cj8KFG"))
    }

    @Test("粘进来的普通链接和批量迁移链接可以混在同一段文本里")
    func mixedPasteImportsBoth() {
        let uri = "otpauth-migration://offline?data="
            + "Cj8KFGnEpnTMQ7KDguNWnddyGyCbSVLaEhhBQ01FIENvOmpvaG5AZXhhbXBsZS5jb20aB0FDTUUgQ28gASgBMAIKRAoUXkj+5MY2arwKjsnH2aDsbm6TAlYSG0JldGEgTHRkLjpob21lckBleGFtcGxlLmNvbRoJQmV0YSBMdGQuIAEoATACCkgKFDDFyzUNPgYoI3q/KGHBdcNU9ptWEh1DYXRzICYgRG9nczptYXJnZUBleGFtcGxlLmNvbRoLQ2F0cyAmIERvZ3MgASgBMAIKSAoUunHzbm5h/LUO0yilLMI+dYZY1eISHURhaWx5IEJ1Z2xlOnBldGVyQGV4YW1wbGUuY29tGgtEYWlseSBCdWdsZSABKAEwAhABGAEgACjDnb+uAg=="
        let text = "先给我一个普通的\notpauth://totp/Solo:me?secret=GEZDGNBVGY3TQOJQ\n然后整包导出：\(uri)"
        let (entries, failures) = OtpAuthURI.parseBatch(text)
        #expect(failures.isEmpty)
        #expect(entries.count == 5)
        #expect(entries.map(\.account.issuer) == ["Solo", "ACME Co", "Beta Ltd.", "Cats & Dogs", "Daily Bugle"])
    }

    @Test("粘进来完全不是 otpauth 链接时，也要给一句能照着做的话")
    func nonLinkPasteExplainsItself() {
        let (entries, failures) = OtpAuthURI.parseBatch("123456")
        #expect(entries.isEmpty)
        #expect(failures.count == 1)
        #expect(failures[0].reason.contains("otpauth://"))
    }

    @Test("空文本什么都不报，避免把「没粘东西」说成失败")
    func emptyPasteReportsNothing() {
        let (_, failures) = OtpAuthURI.parseBatch("   \n ")
        #expect(failures.isEmpty)
    }

    @Test("位数写了 7 这种不支持的值，报的是位数而不是含糊的解不开")
    func unsupportedDigitsNamesTheField() {
        L10n.withLanguage(.zhHans) {
            let (_, failures) = OtpAuthURI.parseBatch("otpauth://totp/X:me?secret=JBSWY3DPEHPK3PXP&digits=7")
            #expect(failures.count == 1)
            #expect(failures[0].reason.contains("位数"))
        }
        L10n.withLanguage(.en) {
            let (_, failures) = OtpAuthURI.parseBatch("otpauth://totp/X:me?secret=JBSWY3DPEHPK3PXP&digits=7")
            #expect(failures.count == 1)
            #expect(failures[0].reason.contains("Digits"))
        }
    }

    @Test("每条账户的 Keychain 条目名互不相同")
    func keychainAccountsAreUnique() {
        var seen = Set<String>()
        for index in 0..<20 {
            let result = OtpAuthURI.parse(Self.uri("totp/Site\(index):me?secret=\(Self.secret)"))
            if case .success(let entry) = result {
                #expect(seen.insert(entry.account.keychainAccount).inserted)
            }
        }
    }
}

/// 每个用例一套独立 UserDefaults + 内存密钥仓，不碰真钥匙串。
@MainActor
private func makeOTPStore() -> (OTPStore, InMemorySecretStore, UserDefaults, String) {
    let suite = "misckit-otp-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let secrets = InMemorySecretStore()
    return (OTPStore(defaults: defaults, secrets: secrets), secrets, defaults, suite)
}

private func cleanupOTP(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
}

private func otpEntry(issuer: String, account: String, secret: Data = sha1Secret,
                      kind: OTPKind = .totp, digits: Int = 6, period: Int = 30,
                      counter: UInt64 = 0) -> OTPEntry {
    let meta = OTPAccount(kind: kind, issuer: issuer, account: account, digits: digits,
                          period: period, counter: counter,
                          keychainAccount: "\(issuer)/\(account)")
    return OTPEntry(account: meta, secret: secret)
}

@MainActor
@Suite("OTP：账户仓与密钥仓同生共死")
struct OTPStoreTests {
    @Test("导入后元数据与密钥都在，重开还能读回来")
    func persistsAcrossReload() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        #expect(store.add(otpEntry(issuer: "GitHub", account: "octocat")))
        #expect(secrets.items["GitHub/octocat"] == sha1Secret)
        #expect(store.accounts.count == 1)

        let reopened = OTPStore(defaults: defaults, secrets: secrets)
        #expect(reopened.accounts.first?.displayName == "GitHub (octocat)")
        #expect(reopened.code(for: reopened.accounts[0],
                             date: Date(timeIntervalSince1970: 59)) != nil)
    }

    @Test("密钥写不进去时不留幽灵条目")
    func writeFailureLeavesNoMetadata() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        L10n.withLanguage(.zhHans) {
            secrets.failNextWrite = true
            #expect(!store.add(otpEntry(issuer: "A", account: "me")))
            #expect(store.accounts.isEmpty)
            #expect(store.lastError == "模拟写入失败")
        }
        L10n.withLanguage(.en) {
            secrets.failNextWrite = true
            #expect(!store.add(otpEntry(issuer: "B", account: "me")))
            #expect(store.accounts.isEmpty)
            #expect(store.lastError == "Simulated write failure")
        }
    }

    @Test("删除同时清掉密钥；密钥删不掉就不动列表")
    func deleteRemovesBothOrNeither() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "A", account: "me"))
        store.add(otpEntry(issuer: "B", account: "me"))
        #expect(store.delete(store.accounts[0]))
        #expect(store.accounts.count == 1)
        #expect(secrets.items.keys.sorted() == ["B/me"])

        // 伪造一个列表里没有但密钥仓里有的条目不会发生；反过来：密钥仓删失败时列表保持原样
        let ghost = OTPAccount(issuer: "C", account: "me", keychainAccount: "missing")
        L10n.withLanguage(.zhHans) {
            #expect(!store.delete(ghost))
            #expect(store.accounts.count == 1)
            #expect(store.lastError?.contains("删除") == true)
        }
        L10n.withLanguage(.en) {
            #expect(!store.delete(ghost))
            #expect(store.lastError?.contains("Keychain delete failed") == true)
        }
    }

    @Test("deleteWithStatus 区分已删 / 密钥不存在 / 失败，仅在明确确认后清理缺失密钥的元数据")
    func deleteWithStatusHandlesMissingSecretSafely() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        #expect(store.add(otpEntry(issuer: "Keep", account: "me")))
        #expect(store.add(otpEntry(issuer: "Gone", account: "me")))

        // 1) 真实删除失败（如权限被拒 / IO 错误）→ .failed，保留元数据与密钥
        let keep = store.accounts[0]
        secrets.failNextRemove = true
        #expect(store.deleteWithStatus(keep) == .failed)
        #expect(store.accounts.contains { $0.id == keep.id })
        #expect(secrets.items["Keep/me"] != nil)

        // 2) 密钥已被外部移除 → .secretMissing，先保留元数据等二次确认
        let gone = store.accounts[1]
        secrets.items.removeValue(forKey: "Gone/me")
        #expect(store.deleteWithStatus(gone) == .secretMissing)
        #expect(store.accounts.contains { $0.id == gone.id })

        // 用户确认移除坏元数据后 → 从列表清理且清空 lastError
        store.removeFromListIfSecretMissing(gone)
        #expect(!store.accounts.contains { $0.id == gone.id })
        #expect(store.lastError == nil)

        // 3) 正常删除 → .deleted
        #expect(store.deleteWithStatus(keep) == .deleted)
        #expect(store.accounts.isEmpty)
        #expect(secrets.items.isEmpty)
    }

    @Test("清空所有账户后不留孤儿密钥")
    func noOrphansAfterClearAll() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        for index in 0..<5 { store.add(otpEntry(issuer: "S\(index)", account: "me")) }
        #expect(secrets.items.count == 5)
        for account in store.accounts { #expect(store.delete(account)) }
        #expect(store.accounts.isEmpty)
        #expect(secrets.items.isEmpty, "密钥必须跟着列表一起清空")
    }

    @Test("TOTP 出码与 RFC 向量一致，偏移等于平移时间")
    func totpCodesAndDrift() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "RFC", account: "me", secret: sha1Secret, digits: 8))
        let account = store.accounts[0]
        #expect(store.code(for: account, date: Date(timeIntervalSince1970: 59)) == "94287082")
        // 偏移 30 秒 = 把 59 当成 89，落到下一个时间窗（counter 2）
        store.driftOffset = 30
        #expect(store.code(for: account, date: Date(timeIntervalSince1970: 59)) == "37359152")
        store.driftOffset = 0
        #expect(store.code(for: account, date: Date(timeIntervalSince1970: 89)) == "37359152",
                "偏移与直接平移时间必须等价")
    }

    @Test("偏移落盘，重开还在")
    func driftPersists() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.driftOffset = -12
        let reopened = OTPStore(defaults: defaults, secrets: secrets)
        #expect(reopened.driftOffset == -12)
    }

    @Test("周期剩余秒数按账户自己的 period 算")
    func remainingUsesAccountPeriod() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "P30", account: "me", period: 30))
        store.add(otpEntry(issuer: "P60", account: "me", period: 60))
        let date = Date(timeIntervalSince1970: 61)
        #expect(store.secondsRemaining(for: store.accounts[0], date: date) == 29)
        #expect(store.secondsRemaining(for: store.accounts[1], date: date) == 59)
    }

    @Test("HOTP 出码后计数器推进并落盘")
    func hotpCounterAdvances() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "H", account: "me", kind: .hotp))
        let account = store.accounts[0]
        #expect(store.code(for: account) == "755224")
        store.advanceCounter(account)
        let reopened = OTPStore(defaults: defaults, secrets: secrets)
        #expect(reopened.accounts[0].counter == 1)
        #expect(reopened.code(for: reopened.accounts[0]) == "287082")
    }

    @Test("分组按首次出现排序，组内保持手动顺序")
    func grouping() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "B", account: "1"))
        store.add(otpEntry(issuer: "A", account: "1"))
        store.add(otpEntry(issuer: "B", account: "2"))
        #expect(store.grouped.map(\.issuer) == ["B", "A"])
        #expect(store.grouped[0].accounts.map(\.account) == ["1", "2"])
        store.move(store.accounts[1].id, to: 0)
        #expect(store.grouped.map(\.issuer) == ["A", "B"])
    }

    @Test("搜索跨组命中 issuer 与 account，⌘ 序号按扁平顺序")
    func searchFlattens() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "GitHub", account: "octocat"))
        store.add(otpEntry(issuer: "GitLab", account: "eason"))
        store.add(otpEntry(issuer: "AWS", account: "root"))
        #expect(store.visibleAccounts(matching: "git").map(\.issuer) == ["GitHub", "GitLab"])
        #expect(store.visibleAccounts(matching: "root").map(\.issuer) == ["AWS"])
        #expect(store.visibleAccounts(matching: "  ").count == 3)
    }

    @Test("密钥缺失给出提示，同步降级不再占横幅")
    func healthNotices() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "A", account: "me"))
        #expect(store.healthNotice == nil)

        secrets.items.removeAll()
        L10n.withLanguage(.zhHans) {
            #expect(store.healthNotice?.contains("1 个账户") == true)
        }
        L10n.withLanguage(.en) {
            #expect(store.healthNotice?.contains("1 account") == true)
        }

        // 降级只影响同步能力，不应再变成常驻警告；账户密钥齐时没有任何 healthNotice。
        let local = InMemorySecretStore(synchronizesToCloud: false)
        local.items = ["A/me": Data("test".utf8)]
        let downgraded = OTPStore(defaults: defaults, secrets: local)
        #expect(downgraded.healthNotice == nil)
    }

    @Test("批量导入文本一次报清成功与失败")
    func batchImportReportsBoth() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        let text = """
        otpauth://totp/One:me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
        otpauth://totp/Two:me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
        otpauth://totp/Bad:me?secret=%%%
        """
        let result = store.importText(text)
        #expect(result.added == 2)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].label == "Bad:me")
        #expect(store.accounts.map(\.issuer) == ["One", "Two"])
    }

    @Test("密钥写不进去时，失败条目带账户名和真正的失败原因")
    func keychainFailureReportsReason() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        secrets.failNextWrite = true
        let text = "otpauth://totp/Three:me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let result = store.importText(text)
        #expect(result.added == 0)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].label == "Three (me)")
        #expect(!result.failures[0].reason.isEmpty)
        #expect(!result.failures[0].displayText.contains("GEZDGNBVGY3TQOJQ"))
        #expect(store.accounts.isEmpty)
    }
}

@MainActor
@Suite("OTP：手工录入只有密钥的账户")
struct OTPManualEntryTests {
    @Test("填服务名 + Base32 就能出正确的码")
    func buildsWorkingEntry() {
        let result = OTPManualEntry.entry(issuer: "GitHub", account: "octocat",
                                          secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        guard case .success(let entry) = result else {
            if case .failure(let error) = result { Issue.record("不该失败：\(error.errorDescription ?? "")") }
            return
        }
        #expect(entry.account.displayName == "GitHub (octocat)")
        #expect(entry.secret == sha1Secret)
        #expect(TOTP.code(secret: entry.secret, date: Date(timeIntervalSince1970: 59),
                          period: entry.account.period, digits: entry.account.digits) == "287082")
    }

    @Test("8 位可选，7 位直接拒而不是悄悄当 6 位")
    func digitsAreValidated() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        guard case .success(let eight) = OTPManualEntry.entry(issuer: "X", account: "me",
                                                             secret: secret, digits: 8) else {
            Issue.record("8 位该放行")
            return
        }
        #expect(TOTP.code(secret: eight.secret, date: Date(timeIntervalSince1970: 59),
                          period: 30, digits: 8) == "94287082")
        #expect(OTPManualEntry.entry(issuer: "X", account: "me", secret: secret, digits: 7)
                == .failure(.invalidDigits(7)))
    }

    @Test("空格、连字符、小写都容忍；非法字符与空密钥各自给原因")
    func tolerantSecret() {
        if case .failure(let error) = OTPManualEntry.entry(issuer: "X", account: "me",
                                                           secret: "gezdgnbv gy3tqojq gezdgnbvgy3tqojq") {
            Issue.record("小写带空格该容忍：\(error.errorDescription ?? "")")
        }
        #expect(OTPManualEntry.entry(issuer: "X", account: "me", secret: "JBSWY3DPEHPK3PX0")
                == .failure(.invalidSecret), "0 是 O 的形近字，不该当密钥收")
        #expect(OTPManualEntry.entry(issuer: "X", account: "me", secret: "   ")
                == .failure(.missingSecret))
    }

    @Test("服务名与账户名都空时拒绝，否则存进来认不出是谁")
    func requiresLabel() {
        #expect(OTPManualEntry.entry(issuer: " ", account: "", secret: "GEZDGNBVGY3TQOJQ")
                == .failure(.missingLabel))
        guard case .success(let onlyIssuer) = OTPManualEntry.entry(issuer: "Only", account: "  ",
                                                                   secret: "GEZDGNBVGY3TQOJQ") else {
            Issue.record("只有服务名也该收下")
            return
        }
        #expect(onlyIssuer.account.account == "Only")
    }

    @Test("两条同名账户不互相覆盖 —— 密钥条目名各走各的 UUID")
    func sameLabelDifferentSlots() {
        let (store, secrets, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        guard case .success(let first) = OTPManualEntry.entry(issuer: "GitHub", account: "octocat",
                                                              secret: "GEZDGNBVGY3TQOJQ"),
                case .success(let second) = OTPManualEntry.entry(issuer: "GitHub", account: "octocat",
                                                                 secret: "JBSWY3DPEHPK3PXP") else {
            Issue.record("两条都该解析成功")
            return
        }
        #expect(first.account.keychainAccount != second.account.keychainAccount)
        #expect(store.add(first))
        #expect(store.add(second))
        #expect(store.accounts.count == 2)
        #expect(secrets.items.count == 2)
        #expect(store.code(for: store.accounts[0]) != store.code(for: store.accounts[1]),
                "同名的两条必须各自出各自的码")
    }
}

@MainActor
@Suite("OTP：备注与手动重排")
struct OTPNoteAndReorderTests {
    @Test("老元数据里没有 note 键也解得开，解出来是 nil")
    func decodesLegacyMetadata() throws {
        let legacy = Data(#"""
            {"id":"5A1B4C9E-77D4-4A0F-9C11-3E2F8B6D0A21","kind":"totp","issuer":"Old","account":"me",
             "algorithm":"SHA1","digits":6,"period":30,"counter":0,
             "keychainAccount":"Old/me","addedAt":700000000,"sortIndex":0}
            """#.utf8)
        let account = try JSONDecoder().decode(OTPAccount.self, from: legacy)
        #expect(account.note == nil)
        #expect(account.id.uuidString == "5A1B4C9E-77D4-4A0F-9C11-3E2F8B6D0A21")
        #expect(account.displayName == "Old (me)")
    }

    @Test("备注可搜索、空白归一成 nil、重开还在")
    func noteRoundTrips() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        store.add(otpEntry(issuer: "GitHub", account: "octocat"))
        let id = store.accounts[0].id
        #expect(store.visibleAccounts(matching: "公司那个").isEmpty)

        store.updateNote("  公司那个  ", for: id)
        #expect(store.accounts[0].note == "公司那个", "首尾空白该削掉")
        #expect(store.visibleAccounts(matching: "公司").map(\.id) == [id])
        #expect(store.visibleAccounts(matching: "COMPANY").isEmpty)

        store.updateNote("   ", for: id)
        #expect(store.accounts[0].note == nil, "全空白等于没备注，不留 \"\" 这种第二状态")

        store.updateNote("备用", for: id)
        let reopened = OTPStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(reopened.accounts[0].note == "备用")
    }

    @Test("move(before:) 按目标落位，sortIndex 始终连续")
    func moveBeforeKeepsOrderDense() {
        let (store, _, defaults, suite) = makeOTPStore()
        defer { cleanupOTP(defaults, suite) }
        for name in ["A", "B", "C", "D"] { store.add(otpEntry(issuer: name, account: "me")) }
        let ids = store.accounts.map(\.id)  // [A, B, C, D]

        // 往上拖：D 落到 A 前面
        store.move(ids[3], before: ids[0])
        #expect(store.accounts.map(\.issuer) == ["D", "A", "B", "C"])
        // 往下拖：A 落到 C 前面（B 顶上来补位）
        store.move(ids[0], before: ids[2])
        #expect(store.accounts.map(\.issuer) == ["D", "B", "A", "C"])
        #expect(store.accounts.map(\.sortIndex) == [0, 1, 2, 3], "位次不许出现空洞")

        store.move(ids[0], before: ids[0])
        #expect(store.accounts.map(\.issuer) == ["D", "B", "A", "C"], "拖到自己前面是 no-op")
        store.move(UUID(), before: ids[0])
        #expect(store.accounts.map(\.issuer) == ["D", "B", "A", "C"], "不存在的 id 不该改动顺序")
    }
}

/// 剪贴板是系统级共享状态，三个用例必须排队跑，否则互相把对方的内容清掉。
/// 而且**不碰 general**：那既会把用户真剪贴板抹掉，也会被别的 App 中途复制打断
/// （实测偶发红过一次）。命名板是这块逻辑唯一的注入点，走 `ClipboardGuard.init(pasteboard:)`。
@MainActor
@Suite("OTP：剪贴板 60 秒自清", .serialized)
struct ClipboardGuardTests {
    private let board = NSPasteboard(name: .init("app.misckit.clipboardtest"))

    private func pasteboardString() -> String? { board.string(forType: .string) }

    @Test("到期后仍是我们写的那一份就清掉")
    func clearsOurOwnCopy() async throws {
        board.clearContents()
        let guard1 = ClipboardGuard(pasteboard: board)
        guard1.lifetime = 0.3
        #expect(guard1.copySecret("123456"))
        #expect(pasteboardString() == "123456")
        // 余量给足：@MainActor 的定时器要等主队列被排空才送达，卡着 0.6 秒会偶发来不及
        try await Task.sleep(for: .seconds(1.2))
        #expect(pasteboardString() != "123456", "到期后验证码不该还在剪贴板")
    }

    @Test("用户中途复制了别的东西就不该被我们抹掉")
    func leavesUserContentAlone() async throws {
        board.clearContents()
        let guard1 = ClipboardGuard(pasteboard: board)
        guard1.lifetime = 0.4
        #expect(guard1.copySecret("654321"))
        board.clearContents()
        board.setString("用户自己复制的文本", forType: .string)
        try await Task.sleep(for: .seconds(1.4))
        #expect(pasteboardString() == "用户自己复制的文本")
    }

    @Test("取消待清理后不再动剪贴板")
    func cancelStopsClear() async throws {
        board.clearContents()
        let guard1 = ClipboardGuard(pasteboard: board)
        guard1.lifetime = 0.3
        guard1.copySecret("111222")
        guard1.cancelPendingClear()
        try await Task.sleep(for: .seconds(1.2))
        #expect(pasteboardString() == "111222")
    }

    @Test("复制文件写的是文件引用，且算「我们自己复制的那一份」")
    func copiesFileURLs() throws {
        board.clearContents()
        board.setString("先前的一段文字", forType: .string)
        let guard1 = ClipboardGuard(pasteboard: board)
        let urls = [URL(fileURLWithPath: "/tmp/甲.txt"), URL(fileURLWithPath: "/tmp/乙 目录")]
        #expect(guard1.copyFiles(urls))
        let readBack = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(readBack?.map(\.path) == urls.map(\.path), "粘贴方要能按路径取回这些文件")
        #expect(pasteboardString() == nil, "写文件引用要顶掉旧文字，否则粘贴方先拿到上一段文字")
        // 空集合不写：一个 ⌘V 都粘不出东西，还白把用户剪贴板清了
        #expect(!guard1.copyFiles([]))
        #expect(guard1.lastOwnChangeCount == board.changeCount,
                "少了这条登记，面板会把刚自己复制的文件当成外部新内容带进搜索框")
    }
}

@Suite("OTP：启动器匹配评分")
struct OTPMatchScoreTests {
    private let account = OTPAccount(issuer: "Rousi", account: "me@example.com",
                                     keychainAccount: "test", note: "备用号")

    @Test("完全命中 > 前缀 > 包含 > 备注，且大小写不敏感")
    func ranks() {
        #expect(account.matchScore("rousi") == 100)
        #expect(account.matchScore("ROU") == 96)
        #expect(account.matchScore("ous") == 90)
        #expect(account.matchScore("me@example") == 96)
        #expect(account.matchScore("example.com") == 90)
        #expect(account.matchScore("备用") == 84)
        #expect(account.matchScore("nope") == 0)
        #expect(!account.matches("nope"))
        #expect(account.matches("rou"))
    }

    @Test("空白不命中，避免空查询把所有账户捞出来")
    func emptyDoesNotMatch() {
        #expect(account.matchScore("   ") == 0)
    }
}
