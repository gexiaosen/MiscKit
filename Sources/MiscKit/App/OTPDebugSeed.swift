#if DEBUG
import Foundation
import MiscKitCore

/// 验收用的合成稿纸：几行算式与几张按时间命名的张，用来核对排版与持久化。
enum CalcDebugSeed {
    static func installSyntheticSheets() {
        Task { @MainActor in
            let store = CalcStore.shared
            guard store.sheets.isEmpty else { return }
            let samples: [[String]] = [
                ["23+12", "0.1+0.2", "1,234+1", "round(2.345,2)"],
                ["sum(12,30,7)", "100*8%", "10%3"],
                ["sqrt(144)+pow(2,5)", "1/0"],
            ]
            for (offset, expressions) in samples.enumerated() {
                store.newSheet(date: Date().addingTimeInterval(TimeInterval(-offset * 3600)))
                guard let sheet = store.selectedSheet else { continue }
                store.updateRow(sheet.rows[0].id, expression: expressions[0])
                var last = sheet.rows[0].id
                for expression in expressions.dropFirst() {
                    last = store.insertRow(after: last, expression: expression).id
                }
            }
            store.selectedSheetID = store.activeSheets.last?.id
            FileHandle.standardError.write("otp seed calc sheets=\(store.sheets.count)\n".data(using: .utf8)!)
        }
    }
}

/// 验收用的合成账户：全部用 RFC 6238 附录里的公开测试密钥，不含任何真实账号。
enum OTPDebugSeed {
    static func installSyntheticAccounts() {
        let master = Data("12345678901234567890".utf8)
        let long = Data("12345678901234567890123456789012".utf8)
        let candidates: [OTPEntry] = [
            OTPEntry(account: OTPAccount(issuer: "Example", account: "octocat",
                                         keychainAccount: "seed-example",
                                         note: "备用号"), secret: master),
            OTPEntry(account: OTPAccount(issuer: "Example", account: "admin@example.test",
                                         digits: 8, period: 60,
                                         keychainAccount: "seed-example-8"), secret: long),
            OTPEntry(account: OTPAccount(kind: .hotp, issuer: "Legacy", account: "counter",
                                         counter: 3, keychainAccount: "seed-legacy"), secret: master),
        ]
        Task { @MainActor in
            let store = OTPStore.shared
            for candidate in candidates where !store.accounts.contains(where: {
                $0.keychainAccount == candidate.account.keychainAccount
            }) {
                let ok = store.add(candidate)
                FileHandle.standardError.write("otp seed \(candidate.account.keychainAccount) ok=\(ok) error=\(store.lastError ?? "none") sync=\(store.synchronizesToCloud)\n".data(using: .utf8)!)
            }
        }
    }

    /// 验收完把合成账户清干净：密钥和元数据必须一起走。
    /// 删完再扫一遍孤儿——历次换签名身份后 `delete` 会静默失败，钥匙串里攒着一堆没人引用的密钥。
    static func removeSyntheticAccounts() {
        Task { @MainActor in
            let store = OTPStore.shared
            for account in store.accounts where account.keychainAccount.hasPrefix("seed-") {
                let ok = store.delete(account)
                FileHandle.standardError.write("otp unseed \(account.keychainAccount) ok=\(ok)\n".data(using: .utf8)!)
            }
            if let purge = store.purgeOrphanSecrets() {
                FileHandle.standardError.write("otp purge deleted=\(purge.deleted.count) refused=\(purge.refused.count)\n".data(using: .utf8)!)
            }
        }
    }
}
#endif
