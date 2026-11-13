import Foundation
import Testing

@testable import MiscKitCore

private func makeSuite() -> (defaults: UserDefaults, suite: String) {
    let suite = "misckit-settings-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

private func cleanup(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
}

/// 不碰 `launchAtLogin`：它的 didSet 会真的注册/注销登录项，测试里不许动系统状态。
@MainActor
@Suite("设置：默认值与落盘")
struct AppSettingsTests {
    @Test("空域上是出厂默认")
    func factoryDefaults() {
        L10n.withLanguage(.zhHans) {
            let (defaults, suite) = makeSuite()
            defer { cleanup(defaults, suite) }
            let settings = AppSettings(store: defaults)
            #expect(settings.language == .system)
            #expect(settings.placeholderText == "起飞吧！")
            #expect(settings.position == .cursorScreen)
            #expect(settings.appearance == .system)
            #expect(settings.showMenuBarItem)
            #expect(settings.hideOnBlur)
            #expect(settings.prefillFromClipboard)
            #expect(settings.motionScale == 1.0)
            #expect(settings.reminderCountdownInMenuBar)
            #expect(settings.reminderSuppressionBlacklist == ["com.tencent.meeting"])
            #expect(settings.reminderPlans.isEmpty)
            #expect(settings.reminderFocusWindows.isEmpty)
        }

        L10n.withLanguage(.en) {
            let (defaults, suite) = makeSuite()
            defer { cleanup(defaults, suite) }
            let settings = AppSettings(store: defaults)
            #expect(settings.placeholderText == "Ready to launch!")
        }
    }

    @Test("界面语言切换落盘并在未自定义提示词时跟随语言")
    func languagePersistence() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(defaults, suite) }

        let first = AppSettings(store: defaults)
        #expect(first.language == .system)
        first.language = .en
        #expect(first.placeholderText == "Ready to launch!")

        let second = AppSettings(store: defaults)
        #expect(second.language == .en)
        #expect(second.placeholderText == "Ready to launch!")

        second.language = .zhHans
        #expect(second.placeholderText == "起飞吧！")

        let third = AppSettings(store: defaults)
        #expect(third.language == .zhHans)
    }

    @Test("改过的值重开还在，没改过的仍回默认")
    func persistsAcrossReopen() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(defaults, suite) }
        let first = AppSettings(store: defaults)
        first.showMenuBarItem = false
        first.hideOnBlur = false
        first.placeholderText = "找点什么"
        first.position = .screenCenter
        first.appearance = .dark
        first.motionScale = 1.6

        let second = AppSettings(store: defaults)
        #expect(!second.showMenuBarItem)
        #expect(!second.hideOnBlur)
        #expect(second.placeholderText == "找点什么")
        #expect(second.position == .screenCenter)
        #expect(second.appearance == .dark)
        #expect(second.motionScale == 1.6)
        #expect(second.prefillFromClipboard, "没动过的项不该被别人的落盘带着变")
    }

    @Test("已删功能的旧键在建实例时清掉，不会留在域里等复活")
    func removedFeatureKeyIsPurged() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(defaults, suite) }
        defaults.set(0.45, forKey: "settings.glassDim")
        _ = AppSettings(store: defaults)
        #expect(defaults.object(forKey: "settings.glassDim") == nil)
    }

    @Test("功能开关落盘：关掉的重开还是关着，没关的照常开着")
    func disabledToolsPersist() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(defaults, suite) }
        let first = AppSettings(store: defaults)
        #expect(first.isEnabled(.hosts), "出厂状态所有功能都该是开的")
        first.setEnabled(.hosts, false)
        first.setEnabled(.calc, false)
        #expect(!first.isEnabled(.hosts))
        #expect(first.disabledTools == ["hosts", "calc"])

        let second = AppSettings(store: defaults)
        #expect(!second.isEnabled(.hosts))
        #expect(!second.isEnabled(.calc))
        #expect(second.isEnabled(.otp), "只关掉某两件不该把别的带走")

        second.setEnabled(.hosts, true)
        #expect(second.isEnabled(.hosts))
        #expect(second.disabledTools == ["calc"], "打开后不许把同一个 id 再塞一遍")
    }

    @Test("内置默认提示词（含旧版持久化残留或切语言时 TextField 回写）不会锁死后续语言切换")
    func builtInDefaultPlaceholderDoesNotFreezeAcrossLanguageSwitches() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(defaults, suite) }

        // 模拟旧版或前一次失焦把中文默认文案写入 UserDefaults
        defaults.set("起飞吧！", forKey: "settings.placeholderText")
        let settings = AppSettings(store: defaults)
        #expect(defaults.object(forKey: "settings.placeholderText") == nil)

        // 切到英文后，即使 TextField 在重建前把旧语言默认文案回写进绑定，也不应冻结为自定义值
        settings.language = .en
        settings.placeholderText = "起飞吧！"
        #expect(settings.placeholderText == "Ready to launch!")
        #expect(defaults.object(forKey: "settings.placeholderText") == nil)

        // 切回系统/中文继续跟随语言；自定义文本仍照常持久化；手工改回内置默认后重新解锁跟随
        L10n.withLanguage(.zhHans) {
            settings.language = .system
            #expect(settings.placeholderText == "起飞吧！")
            #expect(settings.language.label == "跟随系统")
            #expect(AppearanceMode.system.label == "跟随系统")
            #expect(PanelPosition.cursorScreen.label == "跟随光标所在屏幕")
        }

        settings.placeholderText = "Search..."
        settings.language = .zhHans
        #expect(settings.placeholderText == "Search...")

        settings.placeholderText = "起飞吧！"
        settings.language = .en
        #expect(settings.placeholderText == "Ready to launch!")
    }
}
