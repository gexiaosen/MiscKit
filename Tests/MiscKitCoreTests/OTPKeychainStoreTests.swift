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
    @Test("写入后读的是缓存：条目被外部删掉后仍然出得来，invalidate 才变 nil")
    func servesFromCacheUntilInvalidated() throws {
        let service = probeService("cache")
        defer { removeBypass(service: service, account: "a") }
        let store = KeychainSecretStore(service: service)
        let secret = Data("s3cr3t".utf8)
        #expect(store.setSecret(secret, for: "a"))
        #expect(store.secret(for: "a") == secret)

        removeBypass(service: service, account: "a")
        #expect(store.secret(for: "a") == secret, "第二次读不该再打钥匙串")

        store.invalidateSecretCache()
        #expect(store.secret(for: "a") == nil)
    }

    @Test("取不到的条目不再逐秒重试：条目悄悄回来了也要 invalidate 才看得见")
    func missingIsRemembered() throws {
        let service = probeService("missing")
        defer { removeBypass(service: service, account: "a") }
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
        defer { removeBypass(service: service, account: "a") }
        let store = KeychainSecretStore(service: service)
        #expect(store.setSecret(Data("first".utf8), for: "a"))
        #expect(store.secret(for: "a") == Data("first".utf8))
        #expect(store.setSecret(Data("second".utf8), for: "a"))
        #expect(store.secret(for: "a") == Data("second".utf8))
    }

    @Test("删除要三档都清干净；本来就没有的返回 false，调用方据此保留元数据")
    func removeClearsEveryVariant() {
        let service = probeService("remove")
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
        for account in ["keep-1", "keep-2"] { removeBypass(service: service, account: account) }
    }
}
