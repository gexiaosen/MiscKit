import Foundation
import Testing
@testable import MiscKitCore

/// RFC 4226 的标准测试密钥（ASCII "12345678901234567890"），够 6 位 SHA1 出码。
private let testSecret = Data("12345678901234567890".utf8)

private func hotkeyCombo(_ keyCode: UInt32, _ modifiers: UInt32 = 1 << 8) -> HotkeyCombo {
    HotkeyCombo(keyCode: keyCode, carbonModifiers: modifiers)
}

@MainActor private func makeSettings() -> (settings: AppSettings, defaults: UserDefaults, suite: String) {
    let suite = "misckit-hotkey-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (AppSettings(store: defaults), defaults, suite)
}

private func cleanup(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
}

// MARK: 键名与迁移

@Suite("动作键：键名解析与旧数据迁移")
@MainActor
struct HotkeyKeysTests {
    @Test("四类目标都能解析回来")
    func parsesEveryNamespace() {
        let section = UUID()
        #expect(HotkeyKeys.target(for: HotkeyKeys.summon) == .summon)
        #expect(HotkeyKeys.target(for: HotkeyKeys.app("com.example.app")) == .app(bundleID: "com.example.app"))
        #expect(HotkeyKeys.target(for: HotkeyKeys.hostsSection(section)) == .hostsSection(id: section))
        #expect(HotkeyKeys.target(for: HotkeyKeys.otpIssuer("GitHub")) == .otpIssuer("GitHub"))
    }

    @Test("认不出的键名一律返回 nil，不猜成应用")
    func rejectsUnknownKeys() {
        #expect(HotkeyKeys.target(for: "settings.foo") == nil)
        #expect(HotkeyKeys.target(for: "") == nil)
        // 段键必须是 UUID，乱写的段键不能被当成某个段
        #expect(HotkeyKeys.target(for: HotkeyKeys.hostsPrefix + "not-a-uuid") == nil)
    }

    @Test("迁移：裸 bundleID 加前缀，已带前缀的不动")
    func normalizesLegacyKeys() {
        #expect(HotkeyKeys.normalized(key: "com.example.app") == "app.com.example.app")
        #expect(HotkeyKeys.normalized(key: "app.com.example.app") == "app.com.example.app")
        #expect(HotkeyKeys.normalized(key: HotkeyKeys.hostsSection(UUID()))
                .hasPrefix(HotkeyKeys.hostsPrefix))
        #expect(HotkeyKeys.normalized(key: HotkeyKeys.summon) == HotkeyKeys.summon)
    }

    @Test("旧 appHotkeys 迁进新表并当场落盘、删掉旧键")
    func migratesStoredTable() {
        let suite = "misckit-hotkey-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { cleanup(defaults, suite) }

        let combo = hotkeyCombo(8)
        defaults.set(try? JSONEncoder().encode(["com.example.app": combo]), forKey: "settings.appHotkeys")

        let settings = AppSettings(store: defaults)
        #expect(settings.hotkeys == ["app.com.example.app": combo])

        // 迁移必须持久化：只改内存的话，用户全部解绑后旧键会把这些绑定的复活一次。
        #expect(AppSettings(store: defaults).hotkeys == ["app.com.example.app": combo])
        #expect(defaults.data(forKey: "settings.appHotkeys") == nil)
    }
}

// MARK: 只切这一段

@Suite("动作键：Hosts 段独占选择")
@MainActor
struct HostsExclusiveSelectionTests {
    private struct Fixture {
        let store: HostsStore
        let cleanup: () -> Void
    }

    private func makeFixture(_ text: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-hotkey-hosts-\(UUID().uuidString)", isDirectory: true)
        let hosts = root.appendingPathComponent("hosts")
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: hosts, atomically: true, encoding: .utf8)
        let store = HostsStore(paths: HostsPaths(hostsFile: hosts, supportDirectory: support))
        store.ensureLoaded()
        return Fixture(store: store, cleanup: { try? FileManager.default.removeItem(at: root) })
    }

    /// 段标题必须是 `#-------- 名称 --------`，第一个段自动是基座。
    private static let threeSections = """
    # 合成 fixture，仅用于测试
    #-------- 共用 --------
    127.0.0.1 localhost

    #-------- dev --------
    10.0.0.1 example.test

    #-------- staging --------
    10.0.0.2 example.test
    """

    @Test("选一个叠加段：基座留着，另一个叠加段关掉")
    func selectsOneOverlay() throws {
        let fixture = try makeFixture(Self.threeSections)
        defer { fixture.cleanup() }
        let store = fixture.store
        let dev = try #require(store.sections.first { $0.name == "dev" })
        let staging = try #require(store.sections.first { $0.name == "staging" })
        store.setSectionEnabled(staging.id, enabled: true)

        #expect(store.selectSectionExclusive(dev.id) == true)
        #expect(store.sections.first { $0.id == dev.id }?.isEnabled == true)
        #expect(store.sections.first { $0.id == staging.id }?.isEnabled == false)
        #expect(store.sections.contains { $0.isBase && !$0.isEnabled } == false)
    }

    @Test("本来就是这个状态、或段不存在时返回 false，不白写一次")
    func repeatedSelectionIsNoop() throws {
        let fixture = try makeFixture(Self.threeSections)
        defer { fixture.cleanup() }
        let dev = try #require(fixture.store.sections.first { $0.name == "dev" })

        #expect(fixture.store.selectSectionExclusive(dev.id) == true)
        #expect(fixture.store.selectSectionExclusive(dev.id) == false)
        #expect(fixture.store.selectSectionExclusive(UUID()) == false)
    }
}

// MARK: 派发

@Suite("动作键：派发与结果说明")
@MainActor
struct HotkeyDispatcherTests {
    private final class Recorder {
        var summoned = 0
        var launched: [String] = []
        var written: [UUID] = []
        var copied: [String] = []
        var copySucceeds = true

        func handlers() -> HotkeyDispatcher.Handlers {
            var handlers = HotkeyDispatcher.Handlers()
            handlers.summon = { [weak self] in self?.summoned += 1 }
            handlers.launch = { [weak self] in self?.launched.append($0) }
            handlers.writeHosts = { [weak self] in self?.written.append($0) }
            handlers.copySecret = { [weak self] code in
                self?.copied.append(code)
                return self?.copySucceeds ?? false
            }
            return handlers
        }
    }

    private func makeApp(_ bundleID: String = "com.example.app", name: String = "示例应用") -> InstalledApp {
        InstalledApp(id: bundleID, bundleID: bundleID,
                     url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name)
    }

    private func makeDispatcher(hosts: HostsStore? = nil, otp: OTPStore? = nil,
                                apps: [InstalledApp] = [], recorder: Recorder) -> HotkeyDispatcher {
        let dispatcher = HotkeyDispatcher()
        dispatcher.handlers = recorder.handlers()
        if let hosts { dispatcher.hosts = hosts }
        if let otp { dispatcher.otp = otp }
        dispatcher.appLookup = { id in apps.first { $0.id == id } }
        return dispatcher
    }

    private func makeOTPStore() -> (store: OTPStore, secrets: InMemorySecretStore,
                                    defaults: UserDefaults, suite: String) {
        let suite = "misckit-hotkey-otp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secrets = InMemorySecretStore()
        return (OTPStore(defaults: defaults, secrets: secrets), secrets, defaults, suite)
    }

    private func makeAccount(kind: OTPKind = .totp, issuer: String, account: String,
                             counter: UInt64 = 0) -> OTPEntry {
        OTPEntry(account: OTPAccount(kind: kind, issuer: issuer, account: account, digits: 6,
                                     period: 30, counter: counter,
                                     keychainAccount: "\(issuer)/\(account)"),
                 secret: testSecret)
    }

    private func makeHostsStore() throws -> (store: HostsStore, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-hotkey-dispatch-\(UUID().uuidString)", isDirectory: true)
        let hosts = root.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#-------- 共用 --------\n127.0.0.1 localhost\n\n#-------- dev --------\n10.0.0.1 example.test\n"
            .write(to: hosts, atomically: true, encoding: .utf8)
        let store = HostsStore(paths: HostsPaths(hostsFile: hosts,
                                                 supportDirectory: root.appendingPathComponent("Support")))
        store.ensureLoaded()
        return (store, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("唤起键直接开面板，不带任何提示语")
    func summonRoutesToPanel() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(recorder: recorder)
        let outcome = dispatcher.dispatch(key: HotkeyKeys.summon)

        #expect(recorder.summoned == 1)
        #expect(outcome.status == .done)
        #expect(outcome.message == nil)
        #expect(dispatcher.lastOutcome == outcome)
    }

    @Test("应用还在就交给启动器，bundleID 原样带过去")
    func launchKnownApp() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(apps: [makeApp()], recorder: recorder)
        let outcome = dispatcher.dispatch(key: HotkeyKeys.app("com.example.app"))

        #expect(recorder.launched == ["com.example.app"])
        #expect(outcome.status == .done)
        #expect(outcome.message?.contains("示例应用") == true)
    }

    @Test("应用已经不在了：报失败并说清是哪一个")
    func launchMissingApp() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(recorder: recorder)
        let outcome = dispatcher.dispatch(key: HotkeyKeys.app("com.example.gone"))

        #expect(outcome.isFailure)
        #expect(recorder.launched.isEmpty)
        #expect(outcome.message?.contains("com.example.gone") == true)
    }

    @Test("不认识的键名报失败，而不是静默无效")
    func unknownKey() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(recorder: recorder)
        let outcome = dispatcher.dispatch(key: "who.knows.what")

        #expect(outcome.isFailure)
        #expect(outcome.message?.contains("who.knows.what") == true)
    }

    @Test("hosts 段键：只切这一段并交给写盘，一次按下只写一次")
    func hostsSectionSwitch() throws {
        let fixture = try makeHostsStore()
        defer { fixture.cleanup() }
        let store = fixture.store
        let recorder = Recorder()
        let dispatcher = makeDispatcher(hosts: store, recorder: recorder)
        let dev = try #require(store.sections.first { $0.name == "dev" })
        let base = try #require(store.sections.first { $0.isBase })

        store.setSectionEnabled(dev.id, enabled: false)
        let outcome = dispatcher.dispatch(key: HotkeyKeys.hostsSection(dev.id))

        #expect(recorder.written == [dev.id])
        #expect(store.sections.first { $0.id == dev.id }?.isEnabled == true)
        #expect(store.sections.first { $0.id == base.id }?.isEnabled == true)
        #expect(outcome.status == .done)

        // 再按一次：本来就是这个状态，绝不能再触发写盘——那会白弹一次管理员授权窗。
        recorder.written.removeAll()
        let second = dispatcher.dispatch(key: HotkeyKeys.hostsSection(dev.id))
        #expect(recorder.written.isEmpty)
        #expect(second.status == .skipped)
    }

    @Test("hosts 段被改名或删掉后按键只报失败，不碰文件")
    func hostsSectionMissing() throws {
        let fixture = try makeHostsStore()
        defer { fixture.cleanup() }
        let recorder = Recorder()
        let dispatcher = makeDispatcher(hosts: fixture.store, recorder: recorder)

        let outcome = dispatcher.dispatch(key: HotkeyKeys.hostsSection(UUID()))
        #expect(outcome.isFailure)
        #expect(recorder.written.isEmpty)
    }

    @Test("OTP issuer 键复制当前码，提示里不含码本身")
    func otpCopiesCode() throws {
        let fixture = makeOTPStore()
        defer { cleanup(fixture.defaults, fixture.suite) }
        #expect(fixture.store.add(makeAccount(issuer: "GitHub", account: "octocat")))
        let recorder = Recorder()
        let dispatcher = makeDispatcher(otp: fixture.store, recorder: recorder)

        let expected = try #require(fixture.store.code(for: fixture.store.accounts[0]))
        let outcome = dispatcher.dispatch(key: HotkeyKeys.otpIssuer("GitHub"))

        #expect(recorder.copied == [expected])
        #expect(outcome.status == .done)
        // 提示只能出现账户名：验证码不能被写进任何会被截图或日志看到的地方
        #expect(outcome.message?.contains(expected) == false)
        #expect(outcome.message?.contains("GitHub") == true)
    }

    @Test("同 issuer 多个账户时复制排在最前的那个")
    func otpCopiesFirstAccountOfIssuer() {
        let fixture = makeOTPStore()
        defer { cleanup(fixture.defaults, fixture.suite) }
        #expect(fixture.store.add(makeAccount(issuer: "GitHub", account: "octocat")))
        #expect(fixture.store.add(makeAccount(issuer: "GitHub", account: "another")))
        let recorder = Recorder()
        let dispatcher = makeDispatcher(otp: fixture.store, recorder: recorder)

        let first = dispatcher.otp.code(for: dispatcher.otp.accounts[0])
        #expect(dispatcher.dispatch(key: HotkeyKeys.otpIssuer("GitHub")).status == .done)
        #expect(recorder.copied.count == 1)
        #expect(recorder.copied.first == first)
    }

    @Test("issuer 大小写不同也能命中")
    func otpIssuerIsCaseInsensitive() {
        let fixture = makeOTPStore()
        defer { cleanup(fixture.defaults, fixture.suite) }
        #expect(fixture.store.add(makeAccount(issuer: "Acme", account: "a@b.test")))
        let recorder = Recorder()
        let dispatcher = makeDispatcher(otp: fixture.store, recorder: recorder)

        #expect(dispatcher.dispatch(key: HotkeyKeys.otpIssuer("acme")).status == .done)
        #expect(recorder.copied.count == 1)
    }

    @Test("issuer 没了 / 密钥不在本机 / 剪贴板写不进，三种失败各有说法")
    func otpFailures() {
        let fixture = makeOTPStore()
        defer { cleanup(fixture.defaults, fixture.suite) }
        #expect(fixture.store.add(makeAccount(issuer: "GitHub", account: "octocat")))

        let missingIssuer = Recorder()
        let gone = makeDispatcher(otp: fixture.store, recorder: missingIssuer)
            .dispatch(key: HotkeyKeys.otpIssuer("Notion"))
        #expect(gone.isFailure)
        #expect(missingIssuer.copied.isEmpty)

        // 元数据还在、密钥不在本机（iCloud 钥匙串还没同步过来）：出不了码也要说得清
        let noSecret = Recorder()
        let downgraded = OTPStore(defaults: fixture.defaults, secrets: InMemorySecretStore())
        L10n.withLanguage(.zhHans) {
            let noCode = makeDispatcher(otp: downgraded, recorder: noSecret)
                .dispatch(key: HotkeyKeys.otpIssuer("GitHub"))
            #expect(noCode.isFailure)
            #expect(noCode.message?.contains("钥匙串") == true)
        }
        L10n.withLanguage(.en) {
            let noCode = makeDispatcher(otp: downgraded, recorder: noSecret)
                .dispatch(key: HotkeyKeys.otpIssuer("GitHub"))
            #expect(noCode.isFailure)
            #expect(noCode.message?.contains("Keychain") == true)
        }
        #expect(noSecret.copied.isEmpty)

        let clipboardFailure = Recorder()
        clipboardFailure.copySucceeds = false
        L10n.withLanguage(.zhHans) {
            let blocked = makeDispatcher(otp: fixture.store, recorder: clipboardFailure)
                .dispatch(key: HotkeyKeys.otpIssuer("GitHub"))
            #expect(blocked.isFailure)
            #expect(blocked.message?.contains("剪贴板") == true)
        }
        L10n.withLanguage(.en) {
            let blocked = makeDispatcher(otp: fixture.store, recorder: clipboardFailure)
                .dispatch(key: HotkeyKeys.otpIssuer("GitHub"))
            #expect(blocked.isFailure)
            #expect(blocked.message?.contains("clipboard") == true)
        }
    }

    @Test("HOTP 键每按一次推进一次计数器")
    func otpAdvancesHotpCounter() {
        let fixture = makeOTPStore()
        defer { cleanup(fixture.defaults, fixture.suite) }
        #expect(fixture.store.add(makeAccount(kind: .hotp, issuer: "Old", account: "user", counter: 5)))
        let recorder = Recorder()
        let dispatcher = makeDispatcher(otp: fixture.store, recorder: recorder)

        #expect(dispatcher.dispatch(key: HotkeyKeys.otpIssuer("Old")).status == .done)
        #expect(fixture.store.accounts.first?.counter == 6)
        #expect(dispatcher.dispatch(key: HotkeyKeys.otpIssuer("Old")).status == .done)
        #expect(fixture.store.accounts.first?.counter == 7)
        #expect(recorder.copied[0] != recorder.copied[1])
    }

    @Test("异步副作用结算后的结果覆盖前一条")
    func reportReplacesLastOutcome() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(recorder: recorder)
        let interim = dispatcher.dispatch(key: HotkeyKeys.hostsSection(UUID()))
        let settled = HotkeyOutcome(key: interim.key, status: .failed, message: "写入失败")

        dispatcher.report(settled)
        #expect(dispatcher.lastOutcome == settled)
    }

    @Test("没接副作用时不崩，也不谎报成功")
    func unwiredHandlersAreHonest() {
        let dispatcher = HotkeyDispatcher()
        dispatcher.appLookup = { _ in makeApp() }
        #expect(dispatcher.dispatch(key: HotkeyKeys.summon).status == .done)
        // 剪贴板出口没接上 → 必须报失败，不能说"已复制"
        let fixture = makeOTPStore()
        defer { cleanup(fixture.defaults, fixture.suite) }
        #expect(fixture.store.add(makeAccount(issuer: "GitHub", account: "octocat")))
        dispatcher.otp = fixture.store
        #expect(dispatcher.dispatch(key: HotkeyKeys.otpIssuer("GitHub")).isFailure)
    }

    @Test("功能在设置里被关掉后，它绑的动作键一律不执行；唤起键不受牵连")
    func disabledFeaturesBlockActionKeys() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(apps: [makeApp()], recorder: recorder)
        dispatcher.isFeatureOn = { _ in false }

        #expect(dispatcher.dispatch(key: HotkeyKeys.app("com.example.app")).status == .failed)
        #expect(dispatcher.dispatch(key: HotkeyKeys.hostsSection(UUID())).status == .failed)
        #expect(dispatcher.dispatch(key: HotkeyKeys.otpIssuer("GitHub")).status == .failed)
        #expect(recorder.launched.isEmpty, "应用被关掉却启动了")
        #expect(recorder.written.isEmpty, "hosts 被关掉却写了文件")
        #expect(recorder.copied.isEmpty, "OTP 被关掉却动了剪贴板")

        // 面板不属于任何一件可关的功能：否则关掉一件就连 ⌥Z 都按不出来
        #expect(dispatcher.dispatch(key: HotkeyKeys.summon).status == .done)
        #expect(recorder.summoned == 1)
    }

    @Test("关掉的功能重新打开后，动作键照旧执行")
    func reenabledFeatureRestoresKeys() {
        let recorder = Recorder()
        let dispatcher = makeDispatcher(apps: [makeApp()], recorder: recorder)
        dispatcher.isFeatureOn = { _ in false }
        #expect(dispatcher.dispatch(key: HotkeyKeys.app("com.example.app")).isFailure)

        dispatcher.isFeatureOn = { _ in true }
        #expect(dispatcher.dispatch(key: HotkeyKeys.app("com.example.app")).status == .done)
        #expect(recorder.launched == ["com.example.app"])
    }
}

// MARK: 清单与冲突

@Suite("动作键：可绑清单与撞键")
@MainActor
struct HotkeyTargetsTests {
    @Test("四组恒定出现，顺序固定，面板组永远排第一")
    func alwaysFourGroups() {
        let groups = HotkeyTargets.groups()
        #expect(groups.map(\.kind) == [.panel, .app, .hosts, .otp])
        #expect(groups.first?.targets.first?.key == HotkeyKeys.summon)
    }

    @Test("只有应用组默认收起未绑定的行")
    func appGroupHidesUnbound() {
        #expect(HotkeyGroupKind.app.listsEveryTarget == false)
        #expect(HotkeyGroupKind.hosts.listsEveryTarget == true)
        #expect(HotkeyGroupKind.otp.listsEveryTarget == true)
        #expect(HotkeyGroupKind.app.canAddTarget == true)
        #expect(HotkeyGroupKind.hosts.canAddTarget == false)
    }

    @Test("撞自己的键要点名占用者")
    func conflictNamesTheOwner() {
        let fixture = makeSettings()
        defer { cleanup(fixture.defaults, fixture.suite) }
        let settings = fixture.settings
        let combo = hotkeyCombo(4)
        settings.summonMode = .combo
        settings.summonCombo = combo

        #expect(HotkeyTargets.conflict(settings: settings, combo: combo,
                                       excluding: HotkeyKeys.app("com.example.app"))
                == HotkeyTargets.panelTarget.title)
        // 唤起键不算"撞自己"
        #expect(HotkeyTargets.conflict(settings: settings, combo: combo,
                                       excluding: HotkeyKeys.summon) == nil)

        // 双击模式也保留组合键兜底，所以 ⌥Z 仍然不许绑给动作键
        settings.summonMode = .doubleTap
        #expect(HotkeyTargets.conflict(settings: settings, combo: combo,
                                       excluding: HotkeyKeys.app("com.example.app"))
                == HotkeyTargets.panelTarget.title)

        let other = hotkeyCombo(21)
        settings.hotkeys[HotkeyKeys.app("com.example.a")] = other
        #expect(HotkeyTargets.conflict(settings: settings, combo: other,
                                       excluding: HotkeyKeys.app("com.example.b")) != nil)
        #expect(HotkeyTargets.conflict(settings: settings, combo: other,
                                       excluding: HotkeyKeys.app("com.example.a")) == nil)
        #expect(HotkeyTargets.conflict(settings: settings, combo: hotkeyCombo(19),
                                       excluding: HotkeyKeys.app("com.example.b")) == nil)
    }

    @Test("索引没扫完时不把应用键当孤儿，别的键照常报孤儿")
    func orphansIgnoreAppsUntilIndexReady() {
        let fixture = makeSettings()
        defer { cleanup(fixture.defaults, fixture.suite) }
        let settings = fixture.settings
        let combo = hotkeyCombo(40)
        settings.hotkeys[HotkeyKeys.app("com.example.app")] = combo
        settings.hotkeys[HotkeyKeys.hostsSection(UUID())] = combo
        // 测试进程没调用 AppIndex.shared.start()，hasLoaded 为 false，正是"刚启动"的状态
        #expect(AppIndex.shared.hasLoaded == false)

        let orphans = HotkeyTargets.orphans(settings: settings)
        #expect(orphans.count == 1)
        #expect(orphans.first?.key.hasPrefix(HotkeyKeys.hostsPrefix) == true)
        #expect(orphans.first?.combo == combo)
    }

    @Test("孤儿键清掉后从表里消失")
    func clearingOrphanRemovesBinding() {
        let fixture = makeSettings()
        defer { cleanup(fixture.defaults, fixture.suite) }
        let settings = fixture.settings
        let key = HotkeyKeys.otpIssuer("Gone")
        settings.hotkeys[key] = hotkeyCombo(40)
        #expect(HotkeyTargets.orphans(settings: settings).count == 1)

        settings.hotkeys[key] = nil
        #expect(HotkeyTargets.orphans(settings: settings).isEmpty)
    }

    @Test("每个 issuer 只出现一行，多账户写清复制哪个")
    func otpGroupsIssuers() throws {
        let entries = [makeAccountForTargets(issuer: "GitHub", account: "octocat"),
                       makeAccountForTargets(issuer: "GitHub", account: "second"),
                       makeAccountForTargets(issuer: "Acme", account: "a@b.test")]
        try L10n.withLanguage(.zhHans) {
            let targets = HotkeyTargets.groups(accounts: entries.map(\.account))
                .first { $0.kind == .otp }?.targets ?? []

            let github = try #require(targets.first { $0.key == HotkeyKeys.otpIssuer("GitHub") })
            #expect(github.detail.contains("2 个账户"))
            #expect(targets.filter { $0.key == HotkeyKeys.otpIssuer("GitHub") }.count == 1)
            #expect(targets.map(\.title) == ["Acme", "GitHub"])
        }
        try L10n.withLanguage(.en) {
            let targets = HotkeyTargets.groups(accounts: entries.map(\.account))
                .first { $0.kind == .otp }?.targets ?? []
            let github = try #require(targets.first { $0.key == HotkeyKeys.otpIssuer("GitHub") })
            #expect(github.detail.contains("2 accounts"))
        }
    }

    @Test("没有 issuer 的账户不进可绑清单")
    func blankIssuerIsNotBindable() {
        let entry = makeAccountForTargets(issuer: "  ", account: "nameless")
        let targets = HotkeyTargets.groups(accounts: [entry.account])
            .first { $0.kind == .otp }?.targets ?? []
        #expect(targets.isEmpty)
    }
}

private func makeAccountForTargets(issuer: String, account: String) -> OTPEntry {
    OTPEntry(account: OTPAccount(kind: .totp, issuer: issuer, account: account, digits: 6, period: 30,
                                 counter: 0, keychainAccount: "\(issuer)/\(account)"),
             secret: testSecret)
}
