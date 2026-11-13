import Foundation
import Testing

@testable import MiscKitCore

@Suite("本地化完整性与语言切换")
struct LocalizationTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/MiscKitCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Repository root
    }

    private func loadStringsCatalog() throws -> [String: [String: Any]] {
        let url = Self.repoRoot.appendingPathComponent("Sources/MiscKitCore/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    private func localizedValue(_ entry: [String: Any], language: String) -> String? {
        guard let localizations = entry["localizations"] as? [String: Any],
              let langDict = localizations[language] as? [String: Any],
              let unit = langDict["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String else {
            return nil
        }
        return value
    }

    private struct FormatSpec: Equatable, Comparable {
        let position: Int?
        let typeChar: String

        static func < (lhs: FormatSpec, rhs: FormatSpec) -> Bool {
            switch (lhs.position, rhs.position) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.typeChar < rhs.typeChar
            }
        }
    }

    private func extractFormatSpecs(from template: String) throws -> [FormatSpec] {
        // 先剔除转义百分号 `%%`，避免把 `100%%` 误当成格式化占位符
        let cleaned = template.replacingOccurrences(of: "%%", with: "")
        let pattern = #"%(?:([1-9]\d*)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiIuUxXoOfFeEgGcCsSp])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = cleaned as NSString
        let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        return matches.map { match in
            let pos: Int?
            if match.range(at: 1).location != NSNotFound {
                pos = Int(ns.substring(with: match.range(at: 1)))
            } else {
                pos = nil
            }
            let typeChar = ns.substring(with: match.range(at: 2))
            return FormatSpec(position: pos, typeChar: typeChar)
        }
    }

    @Test("Localizable.xcstrings 所有键同时具备非空 en 与 zh-Hans 译文")
    func allKeysHaveBothLanguages() throws {
        let strings = try loadStringsCatalog()
        #expect(strings.count >= 200, "本地化键数量异常偏少：\(strings.count)")

        var missing: [String] = []
        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
            let en = localizedValue(entry, language: "en")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let zh = localizedValue(entry, language: "zh-Hans")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if en.isEmpty { missing.append("\(key) [missing en]") }
            if zh.isEmpty { missing.append("\(key) [missing zh-Hans]") }
        }
        #expect(missing.isEmpty, "存在缺失或空译文：\(missing)")
    }

    @Test("Localizable.xcstrings 英文与中文格式化占位符一一匹配")
    func formatSpecifiersMatchBetweenLanguages() throws {
        let strings = try loadStringsCatalog()
        var mismatches: [String] = []

        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
            guard let en = localizedValue(entry, language: "en"),
                  let zh = localizedValue(entry, language: "zh-Hans") else { continue }
            let enSpecs = try extractFormatSpecs(from: en)
            let zhSpecs = try extractFormatSpecs(from: zh)

            let enUsesPositional = enSpecs.contains { $0.position != nil }
            let zhUsesPositional = zhSpecs.contains { $0.position != nil }
            if enUsesPositional || zhUsesPositional {
                // 带位置索引（如 %1$@, %2$lld）允许语序调整，比较按位置排序后的集合
                if enSpecs.sorted() != zhSpecs.sorted() {
                    mismatches.append("\(key): en=\(enSpecs) vs zh=\(zhSpecs)")
                }
            } else if enSpecs != zhSpecs {
                mismatches.append("\(key): en=\(enSpecs) vs zh=\(zhSpecs)")
            }
        }
        #expect(mismatches.isEmpty, "占位符类型或数量不一致：\(mismatches)")
    }

    @Test("L10n.swift 引用的全部键均存在于 Localizable.xcstrings")
    func l10nKeysExistInCatalog() throws {
        let strings = try loadStringsCatalog()
        let l10nURL = Self.repoRoot.appendingPathComponent("Sources/MiscKitCore/Localization/L10n.swift")
        let source = try String(contentsOf: l10nURL, encoding: .utf8)

        let pattern = #"L10n\.(?:tr|format)\("([^"\\]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        #expect(matches.count >= 200)

        var unknown: [String] = []
        for match in matches {
            let key = ns.substring(with: match.range(at: 1))
            if strings[key] == nil { unknown.append(key) }
        }
        for weekday in 0...6 where strings["reminder.display.weekday.\(weekday)"] == nil {
            unknown.append("reminder.display.weekday.\(weekday)")
        }
        for action in SystemActionCatalog.all {
            if strings["system.action.\(action.id)"] == nil {
                unknown.append("system.action.\(action.id)")
            }
            if strings["system.group.\(action.group.rawValue)"] == nil {
                unknown.append("system.group.\(action.group.rawValue)")
            }
        }
        #expect(unknown.isEmpty, "L10n 引用了未定义键：\(Set(unknown).sorted())")
    }

    @Test("运行时切换中英文后关键模块文案即时变化且互不相同")
    func runtimeLanguageSwitchingChangesCopy() {
        let pairs: [() -> String] = [
            { L10n.Language.system },
            { L10n.Defaults.placeholder() },
            { L10n.Common.apply },
            { L10n.Menu.quit },
            { L10n.Settings.windowTitle },
            { L10n.Settings.Tab.about },
            { L10n.About.license },
            { L10n.Launcher.noMatch },
            { L10n.Actions.clipboardFailed },
            { L10n.Calc.Error.divisionByZero },
            { L10n.Files.searching },
            { L10n.OTP.copyCode },
            { L10n.Reminder.Label.water },
        ]

        for fetch in pairs {
            let en = L10n.withLanguage(.en) { fetch() }
            let zh = L10n.withLanguage(.zhHans) { fetch() }
            #expect(!en.isEmpty && !zh.isEmpty)
            #expect(en != zh, "中英文译文意外相同：\(en)")
        }

        // AppLanguage rawValue 与 locale 映射
        #expect(AppLanguage(rawValue: "system") == .system)
        #expect(AppLanguage(rawValue: "en") == .en)
        #expect(AppLanguage(rawValue: "zh-Hans") == .zhHans)
        #expect(AppLanguage.en.resolved == .en)
        #expect(AppLanguage.zhHans.resolved == .zhHans)
        #expect(AppLanguage.en.locale.identifier == "en")
        #expect(AppLanguage.zhHans.locale.identifier == "zh-Hans")
    }
}
