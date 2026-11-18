import Foundation
import Security
import Testing

@testable import MiscKitCore

/// 真打钥匙串的存储测试。每个用例用**自己的 service 名**：Swift Testing 会并行跑用例，
/// 共用一个 service 会互相把对方的条目删掉（`purgeUnreferenced` 尤其致命）。
private func probeService(_ name: String) -> String { "app.misckit.keychain-probe.\(name)" }

/// 绕过 store 直接操作钥匙串，用来制造"store 以为还在、其实已经被外部拿掉"的状态。
private func addBypass(service: String, account: String, data: Data) {
    SecItemAdd([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary, nil)
}

private func removeBypass(service: String, account: String) {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                   kSecAttrService as String: service,
                   kSecAttrAccount as String: account] as CFDictionary)
}

/// 收尾：探针条目和合装条目一起清掉，否则真机上会攒下一堆测试残留。
private func cleanProbe(_ service: String, accounts: [String] = ["a"]) {
    for account in accounts + [KeychainSecretStore.vaultAccount] {
        removeBypass(service: service, account: account)
    }
}

/// 只取属性：免授权，能数出这个 service 下究竟有几个条目（= 会弹几次密码框）。
private func itemAccounts(service: String) -> [String] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let rows = item as? [[String: Any]] else { return [] }
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }
}

private func rawSecret(service: String, account: String) -> Data? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}

@Suite("OTP：钥匙串命名空间按 bundle id 分叉")
struct KeychainNamespaceTests {
    @Test("开发包与正式包落在不同的 service 上")
    func devIsForkedFromRelease() {
        #expect(KeychainSecretStore.keychainService(forBundleID: "app.misckit.MiscKit") == "app.misckit.otp")
        #expect(KeychainSecretStore.keychainService(forBundleID: "app.misckit.MiscKit.dev") == "app.misckit.otp.dev")
        #expect(KeychainSecretStore.keychainService(forBundleID: "app.misckit.MiscKit.dev")
                != KeychainSecretStore.keychainService(forBundleID: "app.misckit.MiscKit"),
                "两条空间必须真错开：开发包的元数据仓是空的，共用空间会让它的 purgeUnreferenced 把正式包的真密钥全删掉")
    }

    @Test("认不出的 bundle id 落回正式空间，不让密钥凭空消失")
    func unknownFallsBackToCanonical() {
        // 无 bundle id 的 SwiftPM/命令行运行必须和正式钥匙串隔离，
        // 否则密钥进正式空间、元数据留在 MiscKit 域，release 包会看成空列表。
        #expect(KeychainSecretStore.keychainService(forBundleID: nil) == "app.misckit.otp.cli")
        #expect(KeychainSecretStore.keychainService(forBundleID: "") == "app.misckit.otp.cli")
        #expect(KeychainSecretStore.keychainService(forBundleID: nil)
                != KeychainSecretStore.keychainService(forBundleID: "app.misckit.MiscKit"))
    }
}

@Suite("OTP：钥匙串存储与进程内缓存")
struct KeychainStoreTests {
    @Test("写入后读的是缓存：合装条目被外部删掉后仍然出得来，invalidate 才变 nil")
    func servesFromCacheUntilInvalidated() throws {
        let service = probeService("cache")
        defer { cleanProbe(service) }
        let store = KeychainSecretStore(service: service)
        let secret = Data("s3cr3t".utf8)
        #expect(store.setSecret(secret, for: "a"))
        #expect(store.secret(for: "a") == secret)

        // 外面把合装条目整条抹掉：进程内缓存还在，这一秒不该再敲钥匙串
        removeBypass(service: service, account: KeychainSecretStore.vaultAccount)
        #expect(store.secret(for: "a") == secret, "第二次读不该再打钥匙串")

        store.invalidateSecretCache()
        #expect(store.secret(for: "a") == nil)
    }

    @Test("取不到的条目不再逐秒重试：条目悄悄回来了也要 invalidate 才看得见")
    func missingIsRemembered() throws {
        let service = probeService("missing")
        defer { cleanProbe(service) }
        let store = KeychainSecretStore(service: service)
        #expect(store.secret(for: "a") == nil)

        // 条目在 store 之外被补上（模拟同步晚到）：这一轮已经记成"取不到"，不该再敲钥匙串
        addBypass(service: service, account: "a", data: Data("late".utf8))
        #expect(store.secret(for: "a") == nil)
        #expect(!store.authorizationDenied, "条目本来就没有，不是被授权挡下，别误报成要用户点允许")

        store.invalidateSecretCache()
        #expect(store.secret(for: "a") == Data("late".utf8))
    }

    @Test("新写入顺手补缓存，否则刚加的账户当秒出不了码")
    func writePopulatesCache() throws {
        let service = probeService("write")
        defer { cleanProbe(service) }
        let store = KeychainSecretStore(service: service)
        #expect(store.setSecret(Data("first".utf8), for: "a"))
        #expect(store.secret(for: "a") == Data("first".utf8))
        #expect(store.setSecret(Data("second".utf8), for: "a"))
        #expect(store.secret(for: "a") == Data("second".utf8))
    }

    @Test("删除要三档都清干净；本来就没有的返回 false，调用方据此保留元数据")
    func removeClearsEveryVariant() {
        let service = probeService("remove")
        defer { cleanProbe(service) }
        let store = KeychainSecretStore(service: service)
        #expect(store.setSecret(Data("v".utf8), for: "a"))
        #expect(store.removeSecret(for: "a"))
        store.invalidateSecretCache()
        #expect(store.secret(for: "a") == nil, "删完任何形态都不该再读得到")
        #expect(!store.removeSecret(for: "a"), "没写过的条目删不出东西，不能报成功")
    }

    @Test("清理只删元数据没引用的孤儿，点名的账户原样保留")
    func purgeKeepsReferenced() throws {
        let service = probeService("purge")
        defer { cleanProbe(service, accounts: ["keep-1", "keep-2", "orphan-1", "orphan-2"]) }
        let store = KeychainSecretStore(service: service)
        for account in ["keep-1", "keep-2", "orphan-1", "orphan-2"] {
            #expect(store.setSecret(Data("v".utf8), for: account))
        }
        store.invalidateSecretCache()

        let purge = store.purgeUnreferenced(keeping: ["keep-1", "keep-2"])
        #expect(purge.refused.isEmpty, "删不掉的会进 refused：\(purge.refused)")
        #expect(Set(purge.deleted) == Set(["orphan-1", "orphan-2"]))

        #expect(store.secret(for: "keep-1") == Data("v".utf8))
        store.invalidateSecretCache()
        #expect(store.secret(for: "orphan-1") == nil)
        #expect(store.purgeUnreferenced(keeping: ["keep-1", "keep-2"]).isEmpty,
                "第二次扫应当无事可做，不该把已删的报成失败")
    }
}

/// 这组盯的是 2026-11-18 老板实测的那个问题：12 个账户 = 12 条钥匙串条目，
/// ad-hoc 签名下 cdhash 一变，读哪条弹哪个框 —— 一次开面板要输十几次密码。
@Suite("OTP：合装条目（一次授权换整份密钥）")
struct KeychainVaultTests {
    @Test("无论加多少账户，钥匙串里只有一条合装条目")
    func keepsEverythingInOneItem() {
        let service = probeService("vault")
        let accounts = ["a", "b", "c", "d"]
        defer { cleanProbe(service, accounts: accounts) }
        let store = KeychainSecretStore(service: service)
        for account in accounts {
            #expect(store.setSecret(Data("v-\(account)".utf8), for: account))
        }
        store.invalidateSecretCache()

        #expect(itemAccounts(service: service) == [KeychainSecretStore.vaultAccount],
                "多于一条就意味着多弹一次授权框：\(itemAccounts(service: service))")
        for account in accounts {
            #expect(store.secret(for: account) == Data("v-\(account)".utf8))
        }
    }

    @Test("老的单条条目读一次就并进合装条目，老条目随即删掉")
    func legacyItemsAreAdoptedInPlace() {
        let service = probeService("adopt")
        defer { cleanProbe(service, accounts: ["a", "b"]) }
        // 升级前的现场：一账户一条
        addBypass(service: service, account: "a", data: Data("old-a".utf8))
        addBypass(service: service, account: "b", data: Data("old-b".utf8))

        let store = KeychainSecretStore(service: service)
        #expect(store.secret(for: "a") == Data("old-a".utf8))
        #expect(store.secret(for: "b") == Data("old-b".utf8))

        #expect(Set(itemAccounts(service: service)) == [KeychainSecretStore.vaultAccount],
                "迁完只该剩合装条目一条，否则下次启动又得为每条弹一次")
        store.invalidateSecretCache()
        #expect(store.secret(for: "a") == Data("old-a".utf8))
        #expect(store.secret(for: "b") == Data("old-b".utf8))
    }

    @Test("合装条目解不开时绝不被覆盖：写入退回单条，原数据原样留着")
    func corruptVaultIsNeverOverwritten() {
        let service = probeService("corrupt")
        defer { cleanProbe(service) }
        let garbage = Data("not-a-plist".utf8)
        addBypass(service: service, account: KeychainSecretStore.vaultAccount, data: garbage)

        let store = KeychainSecretStore(service: service)
        #expect(store.setSecret(Data("v".utf8), for: "a"), "合装条目写不动要退回单条存，不能直接失败")
        #expect(store.secret(for: "a") == Data("v".utf8))
        #expect(rawSecret(service: service, account: KeychainSecretStore.vaultAccount) == garbage,
                "解不开的合装条目内容不明，写入前必须先确认能解开，否则等于抹掉整份密钥")
    }
}
