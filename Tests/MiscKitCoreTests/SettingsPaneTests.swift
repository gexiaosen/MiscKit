import Foundation
import Testing
@testable import MiscKitCore

private final class MemoryCache: SettingsPaneCaching, @unchecked Sendable {
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private var stored: (key: String, panes: [SettingsPane])?

    func load(key: String) -> [SettingsPane]? {
        loadCount += 1
        guard let stored, stored.key == key else { return nil }
        return stored.panes
    }

    func save(_ panes: [SettingsPane], key: String) {
        saveCount += 1
        stored = (key, panes)
    }
}

@Suite("设置面板索引：扫描、本地化、索引词与缓存")
struct SettingsPaneTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: url)
    }

    private func paneInfo(_ id: String, termsFile: String? = nil, viaNS: Bool = false) -> [String: Any] {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "InternalCodeName"]
        if viaNS {
            info["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.Settings.extension.ui"]
        } else {
            var ex: [String: Any] = ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui"]
            if let termsFile { ex["SettingsExtensionAttributes"] = ["searchTermsFileName": termsFile] }
            info["EXAppExtensionAttributes"] = ex
        }
        return info
    }

    @discardableResult
    private func writePane(_ root: URL, _ dirName: String, id: String,
                           loctable: [String: Any]? = nil, termsFile: String? = nil,
                           viaNS: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(dirName, isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try writePlist(paneInfo(id, termsFile: termsFile, viaNS: viaNS),
                       to: contents.appendingPathComponent("Info.plist"))
        if let loctable {
            try writePlist(loctable, to: contents.appendingPathComponent("Resources/InfoPlist.loctable"))
        }
        return url
    }

    private func writeTerms(_ bundle: URL, lang: String, file: String,
                            _ entries: [(title: String, index: String)]) throws {
        let value: [String: Any] = ["Main": ["localizableStrings": entries.map {
            ["title": $0.title, "index": $0.index]
        }]]
        try writePlist(value, to: bundle
            .appendingPathComponent("Contents/Resources/\(lang).lproj/\(file).searchTerms"))
    }

    private func scanner(_ root: URL, _ languages: [String] = ["zh-Hans-CN"],
                         cache: MemoryCache = MemoryCache()) -> SettingsPaneScanner {
        SettingsPaneScanner(root: root, cache: cache, preferredLanguages: languages)
    }

    // MARK: 真机

    @Test("真机扫描：53 个面板，蓝牙在列，耳机/无线是蓝牙索引词",
          .enabled(if: FileManager.default.fileExists(atPath: SettingsPaneScanner.extensionsRoot.path)))
    func realMachineScan() throws {
        let cache = MemoryCache()
        let scan = SettingsPaneScanner(cache: cache, preferredLanguages: ["zh-Hans-CN"])
        let panes = scan.scan()
        #expect(panes.count >= 40)
        #expect(panes.filter { !$0.matchTerms.isEmpty }.count >= 15)

        let bluetooth = try #require(panes.first { $0.id == "com.apple.BluetoothSettings" })
        #expect(bluetooth.name == "蓝牙")
        #expect(bluetooth.subtitle == "蓝牙设备")
        #expect(bluetooth.matchTerms.contains("耳机"))
        #expect(bluetooth.matchTerms.contains("无线"))
        #expect(bluetooth.matchTerms.contains("headphones"))
        #expect(bluetooth.url.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings")

        #expect(panes.first { $0.id == "com.apple.Battery-Settings.extension" }?.name == "电池")
        // FollowUp 没有中文名（loctable 连 zh_CN 键都没有），保留 Apple 自己的英文名凑满 53。
        #expect(panes.first { $0.id == "com.apple.FollowUpSettings.FollowUpSettingsExtension" }?.name == "FollowUps")
        #expect(panes.contains { $0.name == "隔空投送与连续互通" })
        #expect(panes.contains { $0.name == "桌面与程序坞" })

        #expect(cache.saveCount == 1 && cache.loadCount == 1)
        #expect(scan.scan() == panes)
        #expect(cache.saveCount == 1 && cache.loadCount == 2)
    }

    // MARK: 判定

    @Test("判定：EX 与 NS 两种声明都收，非设置面板与空包跳过")
    func paneDetection() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePane(root, "A.appex", id: "com.test.a", loctable: ["zh_CN": ["CFBundleDisplayName": "甲"]])
        try writePane(root, "B.appex", id: "com.test.b", loctable: ["zh_CN": ["CFBundleDisplayName": "乙"]],
                      viaNS: true)
        let widget = root.appendingPathComponent("Widget.appex", isDirectory: true)
        try writePlist(["CFBundleIdentifier": "com.test.widget",
                        "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.widgetkit-extension"]],
                       to: widget.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty.appex/Contents"),
                                                withIntermediateDirectories: true)
        try Data("ignore".utf8).write(to: root.appendingPathComponent("Stray.appexlist"))

        let panes = scanner(root).scan()
        #expect(panes.count == 2)
        #expect(Set(panes.map(\.id)) == ["com.test.a", "com.test.b"])
    }

    // MARK: 显示名

    @Test("显示名：loctable 中文名优先，英文回退，电池手工补，无名跳过")
    func displayNameResolution() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePane(root, "Zh.appex", id: "com.test.zh",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "蓝牙"], "en": ["CFBundleDisplayName": "Bluetooth"]])
        try writePane(root, "En.appex", id: "com.test.en", loctable: ["en": ["CFBundleName": "English Only"]])
        try writePane(root, "Battery.appex", id: "com.apple.Battery-Settings.extension",
                      loctable: ["zh_CN": ["NSHumanReadableCopyright": "版权"],
                                 "en": ["NSHumanReadableCopyright": "copyright"]])
        try writePane(root, "NoName.appex", id: "com.test.noname")
        try writePane(root, "Blank.appex", id: "com.test.blank",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "   "]])

        let panes = scanner(root).scan()
        #expect(panes.count == 3)
        #expect(panes.first { $0.id == "com.test.zh" }?.name == "蓝牙")
        #expect(panes.first { $0.id == "com.test.en" }?.name == "English Only")
        #expect(panes.first { $0.id == "com.apple.Battery-Settings.extension" }?.name == "电池")
        // Info.plist 的 CFBundleName 是内部代号，取不到本地化名时宁可跳过也不显示它。
        #expect(!panes.contains { $0.id == "com.test.noname" })
        #expect(!panes.contains { $0.id == "com.test.blank" })
    }

    @Test("语言回退：繁体偏好取 zh_HK，日语缺失退英文变体")
    func languageFallback() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePane(root, "Trad.appex", id: "com.test.trad",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "简体"],
                                 "zh_HK": ["CFBundleDisplayName": "繁體"],
                                 "en": ["CFBundleDisplayName": "English"]])
        try writePane(root, "Ja.appex", id: "com.test.ja",
                      loctable: ["en_GB": ["CFBundleDisplayName": "Colour"],
                                 "zh_CN": ["CFBundleDisplayName": "颜色"]])

        let traditional = scanner(root, ["zh-Hant-HK"]).scan()
        #expect(traditional.first { $0.id == "com.test.trad" }?.name == "繁體")
        let japanese = scanner(root, ["ja-JP"]).scan()
        #expect(japanese.first { $0.id == "com.test.ja" }?.name == "Colour")
    }

    // MARK: 索引词

    @Test("索引词：逗号切分、显示语言+zh_CN+en 并集去重、title 当子标题")
    func searchTermsCollection() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try writePane(root, "Demo.appex", id: "com.test.demo",
                                   loctable: ["zh_CN": ["CFBundleDisplayName": "演示"],
                                              "en": ["CFBundleDisplayName": "Demo"]],
                                   termsFile: "Demo")
        try writeTerms(bundle, lang: "zh_CN", file: "Demo",
                       [("演示设备", "无线, wireless, 耳机, headphones"), ("演示音频", "声音, sound")])
        try writeTerms(bundle, lang: "en", file: "Demo",
                       [("Demo Devices", "wireless, headphones, sound")])
        try writePane(root, "Ghost.appex", id: "com.test.ghost",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "空词"]], termsFile: "Ghost")

        let zh = try #require(scanner(root).scan().first { $0.id == "com.test.demo" })
        #expect(zh.matchTerms == ["无线", "wireless", "耳机", "headphones", "声音", "sound"])
        #expect(zh.subtitle == "演示设备")

        let en = try #require(scanner(root, ["en-US"]).scan().first { $0.id == "com.test.demo" })
        #expect(en.matchTerms == ["wireless", "headphones", "sound", "无线", "耳机", "声音"])
        #expect(en.subtitle == "Demo Devices")

        let ghost = try #require(scanner(root).scan().first { $0.id == "com.test.ghost" })
        #expect(ghost.matchTerms.isEmpty)
        #expect(ghost.subtitle == nil)
    }

    @Test("索引词的分区键各面板自取，不只认 Main")
    func searchTermsSectionKeys() throws {
        // 真机上 24 个带索引词的面板里 22 个的分区键不是 Main（volume / Network / Password …），
        // 只读 Main 会让它们全部变成空词。
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try writePane(root, "Sections.appex", id: "com.test.sections",
                                   loctable: ["zh_CN": ["CFBundleDisplayName": "分区"]],
                                   termsFile: "Sections")
        let value: [String: Any] = [
            "volume": ["localizableStrings": [["title": "音量", "index": "声音, volume"]]],
            "mute": ["localizableStrings": [["title": "静音", "index": "无声, silence"]]],
        ]
        try writePlist(value, to: bundle
            .appendingPathComponent("Contents/Resources/zh_CN.lproj/Sections.searchTerms"))

        let pane = try #require(scanner(root).scan().first { $0.id == "com.test.sections" })
        #expect(Set(pane.matchTerms) == ["声音", "volume", "无声", "silence"])
        // 分区名是小节标题，不是面板副标题：没有 Main 就不给副标题。
        #expect(pane.subtitle == nil)
    }

    // MARK: 排序与直达

    @MainActor
    private func index(_ root: URL) -> SettingsPaneIndex {
        SettingsPaneIndex(scanner: SettingsPaneScanner(root: root, cache: MemoryCache(),
                                                       preferredLanguages: ["zh-Hans-CN"]))
    }

    @Test("名字命中压过索引词命中")
    @MainActor
    func nameBeatsIndexTerms() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let named = try writePane(root, "Named.appex", id: "com.test.named",
                                  loctable: ["zh_CN": ["CFBundleDisplayName": "蓝牙"]])
        try writeTerms(named, lang: "zh_CN", file: "Named", [("别的", "蓝牙, 耳机")])
        let other = try writePane(root, "Other.appex", id: "com.test.other",
                                  loctable: ["zh_CN": ["CFBundleDisplayName": "共享"]])
        try writeTerms(other, lang: "zh_CN", file: "Other", [("共享", "蓝牙, 共享")])

        let results = index(root).search("蓝牙")
        #expect(results.first?.pane.name == "蓝牙")
        #expect(results.first?.score == 98)
    }

    @Test("单字不去匹配索引词：打「设置 等」不该铺出一串面板")
    @MainActor
    func singleCharacterSkipsIndexTerms() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try writePane(root, "A.appex", id: "com.test.a",
                                 loctable: ["zh_CN": ["CFBundleDisplayName": "辅助功能"]])
        try writeTerms(pane, lang: "zh_CN", file: "A", [("辅助", "等价, 等号")])
        #expect(index(root).search("等").isEmpty)
    }

    @Test("不带关键词的直达认名字前缀，两字起才认")
    @MainActor
    func directMatchByName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePane(root, "Login.appex", id: "com.apple.LoginItems-Settings.extension",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "登录项"]])
        try writePane(root, "Battery.appex", id: "com.test.battery",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "电池"]])
        let index = self.index(root)

        #expect(index.directMatches("登录项").map(\.pane.name) == ["登录项"])
        #expect(index.directMatches("登录").map(\.pane.name) == ["登录项"])
        #expect(index.directMatches("电池").map(\.pane.name) == ["电池"])
        // 单字也要能出：他要的是「电」直接给电池
        #expect(index.directMatches("登").map(\.pane.name) == ["登录项"])
        #expect(index.directMatches("电").map(\.pane.name) == ["电池"])
        // 名字命中要排在索引词命中前面
        #expect(index.directMatches("电池").first?.score ?? 0 > 90)
    }

    // MARK: 坏 plist

    @Test("坏 plist 与缺键：坏包跳过，坏索引词不影响面板收录")
    func corruptPlists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("Bad.appex/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: bad.appendingPathComponent("Info.plist"))

        let noID = root.appendingPathComponent("NoID.appex", isDirectory: true)
        try writePlist(["EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui"]],
                       to: noID.appendingPathComponent("Contents/Info.plist"))

        let corruptLoc = try writePane(root, "CorruptLoc.appex", id: "com.test.corruptloc")
        try FileManager.default.createDirectory(
            at: corruptLoc.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: corruptLoc
            .appendingPathComponent("Contents/Resources/InfoPlist.loctable"))

        let good = try writePane(root, "Good.appex", id: "com.test.good",
                                 loctable: ["zh_CN": ["CFBundleDisplayName": "正常"]], termsFile: "Good")
        try FileManager.default.createDirectory(
            at: good.appendingPathComponent("Contents/Resources/zh_CN.lproj", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: good
            .appendingPathComponent("Contents/Resources/zh_CN.lproj/Good.searchTerms"))

        let panes = scanner(root).scan()
        #expect(panes.map(\.id) == ["com.test.good"])
        #expect(panes.first?.matchTerms.isEmpty == true)
        #expect(panes.first?.subtitle == nil)
    }

    // MARK: 缓存

    @Test("缓存：mtime+语言当键，命中不重扫，读不到目录不缓存")
    func cacheBehavior() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePane(root, "A.appex", id: "com.test.a",
                      loctable: ["zh_CN": ["CFBundleDisplayName": "甲"], "en": ["CFBundleDisplayName": "A"]])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: root.path)
        let cache = MemoryCache()
        let scan = scanner(root, cache: cache)

        let first = scan.scan()
        #expect(first.first?.name == "甲")
        #expect(cache.saveCount == 1 && cache.loadCount == 1)
        #expect(scan.scan() == first)
        #expect(cache.saveCount == 1 && cache.loadCount == 2)

        // 改包内文件不动根目录 mtime：键没变就继续吃缓存。
        try writePlist(["zh_CN": ["CFBundleDisplayName": "改名"], "en": ["CFBundleDisplayName": "Renamed"]],
                       to: root.appendingPathComponent("A.appex/Contents/Resources/InfoPlist.loctable"))
        #expect(scan.scan().first?.name == "甲")
        #expect(cache.saveCount == 1)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_999)],
                                              ofItemAtPath: root.path)
        #expect(scan.scan().first?.name == "改名")
        #expect(cache.saveCount == 2)

        #expect(scanner(root, ["en-US"], cache: cache).scan().first?.name == "Renamed")
        #expect(cache.saveCount == 3)

        let missingCache = MemoryCache()
        let missing = scanner(root.appendingPathComponent("不存在"), cache: missingCache)
        #expect(missing.scan().isEmpty)
        #expect(missingCache.loadCount == 0 && missingCache.saveCount == 0)
    }

    @Test("文件缓存：键不符或 JSON 损坏时回退重扫，扫描结果可 round-trip")
    func fileCache() throws {
        let base = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("cache/settings-panes.json")
        let cache = SettingsPaneFileCache(fileURL: file)
        let pane = SettingsPane(id: "com.test.x", name: "测试", subtitle: "子标题", matchTerms: ["词"],
                                url: URL(string: "x-apple.systempreferences:com.test.x")!)
        cache.save([pane], key: "k1")
        #expect(cache.load(key: "k1") == [pane])
        #expect(cache.load(key: "k2") == nil)
        try Data("broken json".utf8).write(to: file)
        #expect(cache.load(key: "k1") == nil)
        #expect(SettingsPaneFileCache(fileURL: base.appendingPathComponent("none.json")).load(key: "k") == nil)

        let root = base.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writePane(root, "X.appex", id: "com.test.x", loctable: ["zh_CN": ["CFBundleDisplayName": "测试"]])
        let scanCache = SettingsPaneFileCache(fileURL: base.appendingPathComponent("scan.json"))
        let scan = SettingsPaneScanner(root: root, cache: scanCache, preferredLanguages: ["zh-Hans-CN"])
        let scanned = scan.scan()
        #expect(scanned.count == 1)
        #expect(scan.scan() == scanned)
    }
}