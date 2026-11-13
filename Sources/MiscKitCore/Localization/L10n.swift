public import Foundation
public import SwiftUI
import os

public enum ResolvedLanguage: String, CaseIterable, Sendable {
    case en = "en"
    case zhHans = "zh-Hans"

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public static var systemResolved: ResolvedLanguage {
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") { return .zhHans }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en = "en"

    public var resolved: ResolvedLanguage {
        switch self {
        case .system: return .systemResolved
        case .zhHans: return .zhHans
        case .en: return .en
        }
    }

    public var locale: Locale {
        resolved.locale
    }

    public var label: String {
        switch self {
        case .system: return L10n.Language.system
        case .zhHans: return L10n.Language.zhHans
        case .en: return L10n.Language.en
        }
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .system
}

public extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

private final class BundleToken: NSObject {}

private enum ResourceLookup {
    static let bundleName = "MiscKit_MiscKitCore"

    static let resourceBundle: Bundle = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("\(bundleName).bundle"),
            Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle"),
            Bundle(for: BundleToken.self).resourceURL?.appendingPathComponent("\(bundleName).bundle"),
            Bundle(for: BundleToken.self).bundleURL.appendingPathComponent("\(bundleName).bundle"),
            Bundle(for: BundleToken.self).bundleURL,
        ]
        for case let candidate? in candidates {
            if let bundle = Bundle(url: candidate), hasLocalizableStrings(in: bundle) {
                return bundle
            }
        }
        return Bundle.module
    }()

    private static func hasLocalizableStrings(in bundle: Bundle) -> Bool {
        bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil
            || bundle.resourceURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("en.lproj/Localizable.strings").path)
            } ?? false
    }

    static let enTable: [String: String] = loadTable(for: "en")
    static let zhHansTable: [String: String] = loadTable(for: "zh-Hans")

    private static func loadTable(for localization: String) -> [String: String] {
        let bundle = resourceBundle
        if let url = bundle.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: localization
        ),
            let dict = NSDictionary(contentsOf: url) as? [String: String]
        {
            return dict
        }
        if let direct = bundle.resourceURL?.appendingPathComponent("\(localization).lproj/Localizable.strings"),
            let dict = NSDictionary(contentsOf: direct) as? [String: String]
        {
            return dict
        }
        if let sub = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(localization).lproj"),
            let dict = NSDictionary(contentsOf: sub) as? [String: String]
        {
            return dict
        }
        return [:]
    }

    static func table(for language: ResolvedLanguage) -> [String: String] {
        switch language {
        case .en: return enTable
        case .zhHans: return zhHansTable
        }
    }
}

public enum L10n {
    @TaskLocal public static var overrideLanguage: ResolvedLanguage?

    private static let storedLanguage = OSAllocatedUnfairLock<AppLanguage>(initialState: .system)

    public static var currentLanguage: AppLanguage {
        get { storedLanguage.withLock { $0 } }
        set { storedLanguage.withLock { $0 = newValue } }
    }

    public static var effectiveLanguage: ResolvedLanguage {
        overrideLanguage ?? currentLanguage.resolved
    }

    public static func withLanguage<T>(_ language: ResolvedLanguage, operation: () throws -> T) rethrows -> T {
        try $overrideLanguage.withValue(language, operation: operation)
    }

    public nonisolated(nonsending) static func withLanguage<T>(
        _ language: ResolvedLanguage,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $overrideLanguage.withValue(language, operation: operation)
    }

    public static func tr(_ key: String, language: ResolvedLanguage? = nil) -> String {
        let resolved = language ?? effectiveLanguage
        if let value = ResourceLookup.table(for: resolved)[key] {
            return value
        }
        if let fallback = ResourceLookup.enTable[key] {
            return fallback
        }
        return ResourceLookup.resourceBundle.localizedString(forKey: key, value: key, table: nil)
    }

    public static func format(_ key: String, language: ResolvedLanguage? = nil, _ args: CVarArg...) -> String {
        let resolved = language ?? effectiveLanguage
        let template = tr(key, language: resolved)
        return String(format: template, locale: resolved.locale, arguments: args)
    }

    // MARK: - Language

    public enum Language {
        public static var system: String { L10n.tr("language.system") }
        public static var zhHans: String { L10n.tr("language.zhHans") }
        public static var en: String { L10n.tr("language.en") }
    }

    // MARK: - Defaults

    public enum Defaults {
        public static func placeholder(for language: AppLanguage? = nil) -> String {
            L10n.tr("defaults.placeholder", language: L10n.overrideLanguage ?? language?.resolved)
        }
    }

    // MARK: - Common

    public enum Common {
        public static var add: String { L10n.tr("common.add") }
        public static var apply: String { L10n.tr("common.apply") }
        public static var cancel: String { L10n.tr("common.cancel") }
        public static var clear: String { L10n.tr("common.clear") }
        public static var create: String { L10n.tr("common.create") }
        public static var delete: String { L10n.tr("common.delete") }
        public static var done: String { L10n.tr("common.done") }
        public static var edit: String { L10n.tr("common.edit") }
        public static var enable: String { L10n.tr("common.enable") }
        public static var moveDown: String { L10n.tr("common.moveDown") }
        public static var moveUp: String { L10n.tr("common.moveUp") }
        public static var ok: String { L10n.tr("common.ok") }
        public static var openSettings: String { L10n.tr("common.openSettings") }
        public static var openSystemSettings: String { L10n.tr("common.openSystemSettings") }
        public static var remove: String { L10n.tr("common.remove") }
        public static var restoreDefault: String { L10n.tr("common.restoreDefault") }
        public static var retry: String { L10n.tr("common.retry") }
        public static var save: String { L10n.tr("common.save") }
        public static var actionFailed: String { L10n.tr("common.actionFailed") }
        public static var unknownTime: String { L10n.tr("common.unknownTime") }
    }

    // MARK: - Menu

    public enum Menu {
        public static var togglePanel: String { L10n.tr("menu.togglePanel") }
        public static var waterReminder: String { L10n.tr("menu.waterReminder") }
        public static var standReminder: String { L10n.tr("menu.standReminder") }
        public static var checkUpdates: String { L10n.tr("menu.checkUpdates") }
        public static var settings: String { L10n.tr("menu.settings") }
        public static var quit: String { L10n.tr("menu.quit") }
    }

    // MARK: - Settings

    public enum Settings {
        public static var windowTitle: String { L10n.tr("settings.windowTitle") }

        public enum Tab {
            public static var general: String { L10n.tr("settings.tab.general") }
            public static var shortcuts: String { L10n.tr("settings.tab.shortcuts") }
            public static var tools: String { L10n.tr("settings.tab.tools") }
            public static var reminders: String { L10n.tr("settings.tab.reminders") }
            public static var quicklinks: String { L10n.tr("settings.tab.quicklinks") }
            public static var permissions: String { L10n.tr("settings.tab.permissions") }
            public static var about: String { L10n.tr("settings.tab.about") }
        }

        public enum Position {
            public static var label: String { L10n.tr("settings.position.label") }
            public static var cursorScreen: String { L10n.tr("settings.position.cursorScreen") }
            public static var screenCenter: String { L10n.tr("settings.position.screenCenter") }
            public static var remembered: String { L10n.tr("settings.position.remembered") }
        }

        public enum Appearance {
            public static var label: String { L10n.tr("settings.appearance.label") }
            public static var system: String { L10n.tr("settings.appearance.system") }
            public static var light: String { L10n.tr("settings.appearance.light") }
            public static var dark: String { L10n.tr("settings.appearance.dark") }
        }

        public enum Summon {
            public static var combo: String { L10n.tr("settings.summon.combo") }
            public static var doubleTap: String { L10n.tr("settings.summon.doubleTap") }
        }

        public enum Motion {
            public static var section: String { L10n.tr("settings.motion.section") }
            public static var scale: String { L10n.tr("settings.motion.scale") }
        }

        public static var languageLabel: String { L10n.tr("settings.language.label") }
        public static var placeholderLabel: String { L10n.tr("settings.placeholder.label") }
        public static var launchAtLogin: String { L10n.tr("settings.launchAtLogin") }
        public static var showMenuBar: String { L10n.tr("settings.showMenuBar") }
        public static var hideOnBlur: String { L10n.tr("settings.hideOnBlur") }
        public static var clipboardPrefill: String { L10n.tr("settings.clipboardPrefill") }
        public static var previewStart: String { L10n.tr("settings.preview.start") }
        public static var previewStop: String { L10n.tr("settings.preview.stop") }
    }

    // MARK: - About

    public enum About {
        public static func version(_ v: String) -> String { L10n.format("about.version", v) }
        public static func newVersion(_ v: String) -> String { L10n.format("about.newVersion", v) }
        public static var platform: String { L10n.tr("about.platform") }
        public static var license: String { L10n.tr("about.license") }
    }

    // MARK: - Actions

    public enum Actions {
        public static func appMissing(_ name: String) -> String { L10n.format("actions.appMissing", name) }
        public static func appNotRunning(_ name: String) -> String { L10n.format("actions.appNotRunning", name) }
        public static func quitTimedOut(_ name: String) -> String { L10n.format("actions.quitTimedOut", name) }
        public static func launchFailed(_ name: String, _ error: String) -> String { L10n.format("actions.launchFailed", name, error) }
        public static func fileOpenFailed(_ path: String) -> String { L10n.format("actions.fileOpenFailed", path) }
        public static func terminalFailed(_ detail: String) -> String { L10n.format("actions.terminalFailed", detail) }
        public static func invalidURL(_ url: String) -> String { L10n.format("actions.invalidURL", url) }
        public static var clipboardFailed: String { L10n.tr("actions.clipboardFailed") }
        public static var otpSecretMissing: String { L10n.tr("actions.otpSecretMissing") }
        public static var meetingJoinFailed: String { L10n.tr("actions.meetingJoinFailed") }
        public static var tencentMeetingUnavailable: String { L10n.tr("actions.tencentMeetingUnavailable") }
    }

    // MARK: - RowAction

    public enum RowAction {
        public static var open: String { L10n.tr("rowaction.open") }
        public static var reveal: String { L10n.tr("rowaction.reveal") }
        public static var copyPath: String { L10n.tr("rowaction.copyPath") }
        public static var terminal: String { L10n.tr("rowaction.terminal") }
        public static var quit: String { L10n.tr("rowaction.quit") }
        public static var forceQuit: String { L10n.tr("rowaction.forceQuit") }
        public static var relaunch: String { L10n.tr("rowaction.relaunch") }
        public static var alias: String { L10n.tr("rowaction.alias") }
    }

    // MARK: - Launcher

    public enum Launcher {
        public static var noMatch: String { L10n.tr("launcher.noMatch") }

        public enum A11y {
            public static var copyOTP: String { L10n.tr("launcher.a11y.copyOTP") }
            public static var currentOTP: String { L10n.tr("launcher.a11y.currentOTP") }
            public static var hint: String { L10n.tr("launcher.a11y.hint") }
            public static var running: String { L10n.tr("launcher.a11y.running") }
            public static var selected: String { L10n.tr("launcher.a11y.selected") }
            public static var separator: String { L10n.tr("launcher.a11y.separator") }
            public static func shortcut(_ index: String) -> String { L10n.format("launcher.a11y.shortcut", index) }
            public static func source(_ title: String) -> String { L10n.format("launcher.a11y.source", title) }
        }

        public enum Alias {
            public static var title: String { L10n.tr("launcher.alias.title") }
            public static var placeholder: String { L10n.tr("launcher.alias.placeholder") }
            public static func message(_ name: String) -> String { L10n.format("launcher.alias.message", name) }
        }

        public enum Context {
            public static var copyDefinition: String { L10n.tr("launcher.context.copyDefinition") }
            public static var copyMeeting: String { L10n.tr("launcher.context.copyMeeting") }
            public static var execute: String { L10n.tr("launcher.context.execute") }
        }
    }

    // MARK: - Features

    public enum Features {
        public static var noKeywords: String { L10n.tr("features.noKeywords") }
    }

    // MARK: - Tools

    public enum Tools {
        public enum Apps {
            public static var title: String { L10n.tr("tools.apps.title") }
            public static var trigger: String { L10n.tr("tools.apps.trigger") }
            public static var anyLabel: String { L10n.tr("tools.apps.anyLabel") }
            public static var anyTitle: String { L10n.tr("tools.apps.anyTitle") }
        }

        public enum Calc {
            public static var title: String { L10n.tr("tools.calc.title") }
            public static var titleRow: String { L10n.tr("tools.calc.titleRow") }
            public static func sheetsCount(_ count: Int) -> String { L10n.format("tools.calc.sheetsCount", Int64(count)) }
        }

        public enum Dictionary {
            public static var title: String { L10n.tr("tools.dictionary.title") }
            public static var systemTitle: String { L10n.tr("tools.dictionary.systemTitle") }
        }

        public enum Files {
            public static var title: String { L10n.tr("tools.files.title") }
            public static var trigger: String { L10n.tr("tools.files.trigger") }
            public static var search: String { L10n.tr("tools.files.search") }
        }

        public enum Hosts {
            public static var titleRow: String { L10n.tr("tools.hosts.titleRow") }
        }

        public enum Meeting {
            public static var title: String { L10n.tr("tools.meeting.title") }
            public static var triggerLabel: String { L10n.tr("tools.meeting.triggerLabel") }
            public static var triggerTitle: String { L10n.tr("tools.meeting.triggerTitle") }
            public static func rowTitle(_ code: String) -> String { L10n.format("tools.meeting.rowTitle", code) }
            public static var reasonInvite: String { L10n.tr("tools.meeting.reasonInvite") }
            public static var reasonBare: String { L10n.tr("tools.meeting.reasonBare") }
            public static func reasonKeyword(_ word: String) -> String { L10n.format("tools.meeting.reasonKeyword", word) }
        }

        public enum OTP {
            public static var openWorkspace: String { L10n.tr("tools.otp.openWorkspace") }
            public static var titleRow: String { L10n.tr("tools.otp.titleRow") }
            public static var emptySubtitle: String { L10n.tr("tools.otp.emptySubtitle") }
            public static func accountCount(_ count: Int) -> String { L10n.format("tools.otp.accountCount", Int64(count)) }
            public static func manyMatches(_ count: Int) -> String { L10n.format("tools.otp.manyMatches", Int64(count)) }
            public static var triggerAccount: String { L10n.tr("tools.otp.triggerAccount") }
        }

        public enum Quicklink {
            public static var title: String { L10n.tr("tools.quicklink.title") }
            public static var label: String { L10n.tr("tools.quicklink.label") }
            public static var enterQuery: String { L10n.tr("tools.quicklink.enterQuery") }
        }

        public enum Reminder {
            public static var title: String { L10n.tr("tools.reminder.title") }
            public static var titleRow: String { L10n.tr("tools.reminder.titleRow") }
        }

        public enum Settings {
            public static var title: String { L10n.tr("tools.settings.title") }
            public static var paneLabel: String { L10n.tr("tools.settings.paneLabel") }
            public static var systemSubtitle: String { L10n.tr("tools.settings.systemSubtitle") }
            public static var batteryName: String { L10n.tr("tools.settings.batteryName") }
        }

        public enum System {
            public static var title: String { L10n.tr("tools.system.title") }
            public static var actionTrigger: String { L10n.tr("tools.system.actionTrigger") }
            public static var volumePrefill: String { L10n.tr("tools.system.volumePrefill") }
            public static func volumeTitle(_ pct: Int) -> String { L10n.format("tools.system.volumeTitle", Int64(pct)) }
            public static func volumeSubtitle(_ current: String) -> String { L10n.format("tools.system.volumeSubtitle", current) }
            public static var volumeUnavailable: String { L10n.tr("tools.system.volumeUnavailable") }
        }

        public enum Trigger {
            public static func anyText(_ target: String) -> String { L10n.format("tools.trigger.anyText", target) }
            public static func minLengthText(_ n: Int, _ target: String) -> String {
                L10n.format("tools.trigger.minLengthText", Int64(n), target)
            }
        }
    }

    // MARK: - System Control

    public enum System {
        public static func group(_ id: String) -> String { L10n.tr("system.group.\(id)") }
        public static func action(_ id: String) -> String { L10n.tr("system.action.\(id)") }

        public enum Error {
            public static var defaultOutputDevice: String { L10n.tr("system.error.defaultOutputDevice") }
            public static var defaultInputDevice: String { L10n.tr("system.error.defaultInputDevice") }
            public static var muteControl: String { L10n.tr("system.error.muteControl") }
            public static var volumeControl: String { L10n.tr("system.error.volumeControl") }
            public static var micMute: String { L10n.tr("system.error.micMute") }
            public static var deviceRejected: String { L10n.tr("system.error.deviceRejected") }
            public static var volumeLabel: String { L10n.tr("system.error.volumeLabel") }
            public static var muteLabel: String { L10n.tr("system.error.muteLabel") }
            public static var unmuteLabel: String { L10n.tr("system.error.unmuteLabel") }
            public static var finderRejected: String { L10n.tr("system.error.finderRejected") }
            public static var lockScreen: String { L10n.tr("system.error.lockScreen") }
            public static func actionLabel(_ label: String) -> String { L10n.format("system.error.actionLabel", label) }
            public static func pmsetExit(_ status: Int32) -> String { L10n.format("system.error.pmsetExit", Int64(status)) }
            public static func unavailable(_ feature: String) -> String { L10n.format("system.error.unavailable", feature) }
            public static func failed(_ operation: String, _ reason: String) -> String {
                L10n.format("system.error.failed", operation, reason)
            }
        }
    }

    // MARK: - Calc

    public enum Calc {
        public static var archive: String { L10n.tr("calc.archive") }
        public static func archivedButton(_ count: Int) -> String { L10n.format("calc.archivedButton", Int64(count)) }
        public static func archivedHeader(_ count: Int) -> String { L10n.format("calc.archivedHeader", Int64(count)) }
        public static var backToActive: String { L10n.tr("calc.backToActive") }
        public static var clearRows: String { L10n.tr("calc.clearRows") }
        public static func copiedSheet(_ lines: Int) -> String { L10n.format("calc.copiedSheet", Int64(lines)) }
        public static var copySheet: String { L10n.tr("calc.copySheet") }
        public static var decimals: String { L10n.tr("calc.decimals") }
        public static var deleteSheet: String { L10n.tr("calc.deleteSheet") }
        public static var emptyArchived: String { L10n.tr("calc.emptyArchived") }
        public static var emptyMatching: String { L10n.tr("calc.emptyMatching") }
        public static var expressionPlaceholder: String { L10n.tr("calc.expressionPlaceholder") }
        public static var grouping: String { L10n.tr("calc.grouping") }
        public static var namePlaceholder: String { L10n.tr("calc.namePlaceholder") }
        public static var newSheet: String { L10n.tr("calc.newSheet") }
        public static var rename: String { L10n.tr("calc.rename") }
        public static var renameTitle: String { L10n.tr("calc.renameTitle") }
        public static var saveFailed: String { L10n.tr("calc.saveFailed") }
        public static func scaleLabel(_ decimals: Int) -> String { L10n.format("calc.scaleLabel", Int64(decimals)) }
        public static var searchPlaceholder: String { L10n.tr("calc.searchPlaceholder") }
        public static var unarchive: String { L10n.tr("calc.unarchive") }
        public static var undoDelete: String { L10n.tr("calc.undoDelete") }

        public enum Error {
            public static var empty: String { L10n.tr("calc.error.empty") }
            public static var missingOperand: String { L10n.tr("calc.error.missingOperand") }
            public static var divisionByZero: String { L10n.tr("calc.error.divisionByZero") }
            public static var notANumber: String { L10n.tr("calc.error.notANumber") }
            public static var unbalancedOpen: String { L10n.tr("calc.error.unbalancedOpen") }
            public static var unbalancedClose: String { L10n.tr("calc.error.unbalancedClose") }
            public static var unexpectedEnd: String { L10n.tr("calc.error.unexpectedEnd") }
            public static func invalidNumber(_ raw: String) -> String { L10n.format("calc.error.invalidNumber", raw) }
            public static func unknownSymbol(_ raw: String) -> String { L10n.format("calc.error.unknownSymbol", raw) }
            public static func unknownFunction(_ name: String) -> String { L10n.format("calc.error.unknownFunction", name) }
            public static func misplacedOperator(_ op: String) -> String { L10n.format("calc.error.misplacedOperator", op) }
            public static func arityRange(_ name: String, _ expected: String, _ got: Int) -> String {
                L10n.format("calc.error.arityRange", name, expected, Int64(got))
            }
        }
    }

    // MARK: - Files

    public enum Files {
        public static var searching: String { L10n.tr("files.searching") }
        public static var selected: String { L10n.tr("files.selected") }
        public static func selectedCount(_ count: Int) -> String { L10n.format("files.selectedCount", Int64(count)) }
        public static var iCloudNotDownloaded: String { L10n.tr("files.iCloud.notDownloaded") }

        public enum Alias {
            public static var edit: String { L10n.tr("files.alias.edit") }
            public static var set: String { L10n.tr("files.alias.set") }
            public static var title: String { L10n.tr("files.alias.title") }
            public static var placeholder: String { L10n.tr("files.alias.placeholder") }
        }

        public enum Category {
            public static var all: String { L10n.tr("files.category.all") }
            public static var audio: String { L10n.tr("files.category.audio") }
            public static var folder: String { L10n.tr("files.category.folder") }
            public static var image: String { L10n.tr("files.category.image") }
            public static var video: String { L10n.tr("files.category.video") }
        }

        public enum Context {
            public static var copy: String { L10n.tr("files.context.copy") }
            public static func copyMany(_ count: Int) -> String { L10n.format("files.context.copyMany", Int64(count)) }
            public static var pin: String { L10n.tr("files.context.pin") }
            public static var unpin: String { L10n.tr("files.context.unpin") }
            public static var trash: String { L10n.tr("files.context.trash") }
            public static func trashMany(_ count: Int) -> String { L10n.format("files.context.trashMany", Int64(count)) }
        }

        public enum Count {
            public static func exact(_ count: Int) -> String { L10n.format("files.count.exact", Int64(count)) }
            public static func truncated(_ count: Int, _ shown: Int) -> String {
                L10n.format("files.count.truncated", Int64(count), Int64(shown))
            }
        }

        public enum DB {
            public static var closed: String { L10n.tr("files.db.closed") }
            public static var noStaged: String { L10n.tr("files.db.noStaged") }
            public static func open(_ detail: String) -> String { L10n.format("files.db.open", detail) }
            public static func sql(_ detail: String) -> String { L10n.format("files.db.sql", detail) }
        }

        public enum Index {
            public static func building(_ count: String) -> String { L10n.format("files.index.building", count) }
            public static var noDirectories: String { L10n.tr("files.index.noDirectories") }
            public static var opening: String { L10n.tr("files.index.opening") }
            public static var unavailable: String { L10n.tr("files.index.unavailable") }
        }

        public enum Notice {
            public static var emptyFoldersFallback: String { L10n.tr("files.notice.emptyFoldersFallback") }
            public static var emptyQuery: String { L10n.tr("files.notice.emptyQuery") }
            public static func missingPath(_ path: String) -> String { L10n.format("files.notice.missingPath", path) }
            public static var spotlightDisabled: String { L10n.tr("files.notice.spotlightDisabled") }
            public static var spotlightTimeout: String { L10n.tr("files.notice.spotlightTimeout") }
            public static func unreadableDir(_ path: String) -> String { L10n.format("files.notice.unreadableDir", path) }
        }

        public enum Picker {
            public static var message: String { L10n.tr("files.picker.message") }
            public static var prompt: String { L10n.tr("files.picker.prompt") }
        }

        public enum Preview {
            public static var created: String { L10n.tr("files.preview.created") }
            public static var fileKind: String { L10n.tr("files.preview.fileKind") }
            public static var folderKind: String { L10n.tr("files.preview.folderKind") }
            public static var itemsCount: String { L10n.tr("files.preview.itemsCount") }
            public static var kind: String { L10n.tr("files.preview.kind") }
            public static var lastOpened: String { L10n.tr("files.preview.lastOpened") }
            public static var modified: String { L10n.tr("files.preview.modified") }
            public static var path: String { L10n.tr("files.preview.path") }
            public static var selectPrompt: String { L10n.tr("files.preview.selectPrompt") }
            public static var typeTree: String { L10n.tr("files.preview.typeTree") }
        }

        public enum Scope {
            public static var addFolder: String { L10n.tr("files.scope.addFolder") }
            public static var description: String { L10n.tr("files.scope.description") }
            public static var empty: String { L10n.tr("files.scope.empty") }
            public static var folders: String { L10n.tr("files.scope.folders") }
            public static var foldersOnly: String { L10n.tr("files.scope.foldersOnly") }
            public static var heading: String { L10n.tr("files.scope.heading") }
            public static var mac: String { L10n.tr("files.scope.mac") }
            public static var specifiedFolders: String { L10n.tr("files.scope.specifiedFolders") }
        }

        public enum Settings {
            public static var a11y: String { L10n.tr("files.settings.a11y") }
            public static var button: String { L10n.tr("files.settings.button") }
        }

        public enum Sort {
            public static var created: String { L10n.tr("files.sort.created") }
            public static var modified: String { L10n.tr("files.sort.modified") }
            public static var name: String { L10n.tr("files.sort.name") }
            public static var relevance: String { L10n.tr("files.sort.relevance") }
            public static var size: String { L10n.tr("files.sort.size") }
        }

        public enum Trash {
            public static var confirmTitle: String { L10n.tr("files.trash.confirmTitle") }
            public static func failedNone(_ error: String) -> String { L10n.format("files.trash.failedNone", error) }
            public static var includingContents: String { L10n.tr("files.trash.includingContents") }
            public static func manyScope(_ first: String, _ count: Int) -> String {
                L10n.format("files.trash.manyScope", first, Int64(count))
            }
            public static func message(_ target: String, _ contentsSuffix: String) -> String {
                L10n.format("files.trash.message", target, contentsSuffix)
            }
            public static func movedMany(_ count: Int) -> String { L10n.format("files.trash.movedMany", Int64(count)) }
            public static var movedOne: String { L10n.tr("files.trash.movedOne") }
            public static func partialFailure(_ moved: Int, _ failed: Int, _ error: String) -> String {
                L10n.format("files.trash.partialFailure", Int64(moved), Int64(failed), error)
            }
        }

        public enum ViewMode {
            public static var list: String { L10n.tr("files.view.list") }
            public static var split: String { L10n.tr("files.view.split") }
        }
    }

    // MARK: - Hosts

    public enum Hosts {
        public enum Analysis {
            public static var header: String { L10n.tr("hosts.analysis.header") }
            public static func invalidDomain(_ domain: String) -> String { L10n.format("hosts.analysis.invalidDomain", domain) }
            public static func invalidIP(_ ip: String) -> String { L10n.format("hosts.analysis.invalidIP", ip) }
            public static var invalidIPFirstCol: String { L10n.tr("hosts.analysis.invalidIPFirstCol") }
            public static var missingDomain: String { L10n.tr("hosts.analysis.missingDomain") }
            public static var mixedWhitespace: String { L10n.tr("hosts.analysis.mixedWhitespace") }
        }

        public enum Diff {
            public static var matches: String { L10n.tr("hosts.diff.matches") }
            public static func summary(_ added: Int, _ removed: Int, _ changed: Int) -> String {
                L10n.format("hosts.diff.summary", Int64(added), Int64(removed), Int64(changed))
            }
        }

        public enum Doc {
            public static func nameDuplicate(_ name: String) -> String { L10n.format("hosts.doc.nameDuplicate", name) }
            public static var nameEdgeHyphen: String { L10n.tr("hosts.doc.nameEdgeHyphen") }
            public static var nameEmpty: String { L10n.tr("hosts.doc.nameEmpty") }
            public static var nameNewline: String { L10n.tr("hosts.doc.nameNewline") }
            public static var nameTooLong: String { L10n.tr("hosts.doc.nameTooLong") }
        }

        public enum Error {
            public static var applying: String { L10n.tr("hosts.error.applying") }
            public static func backup(_ detail: String) -> String { L10n.format("hosts.error.backup", detail) }
            public static func blockingIssues(_ count: Int) -> String { L10n.format("hosts.error.blockingIssues", Int64(count)) }
            public static var cancelled: String { L10n.tr("hosts.error.cancelled") }
            public static var conflicts: String { L10n.tr("hosts.error.conflicts") }
            public static var corruptState: String { L10n.tr("hosts.error.corruptState") }
            public static var emptyOutput: String { L10n.tr("hosts.error.emptyOutput") }
            public static var externalChange: String { L10n.tr("hosts.error.externalChange") }
            public static var notLoaded: String { L10n.tr("hosts.error.notLoaded") }
            public static func osascriptExit(_ status: Int32) -> String { L10n.format("hosts.error.osascriptExit", status) }
            public static func readFailed(_ detail: String) -> String { L10n.format("hosts.error.readFailed", detail) }
            public static func stateSave(_ detail: String) -> String { L10n.format("hosts.error.stateSave", detail) }
            public static var verifyMismatch: String { L10n.tr("hosts.error.verifyMismatch") }
            public static func writeFailed(_ detail: String) -> String { L10n.format("hosts.error.writeFailed", detail) }
        }

        public enum Tab {
            public static var content: String { L10n.tr("hosts.tab.content") }
            public static var diff: String { L10n.tr("hosts.tab.diff") }
            public static var effective: String { L10n.tr("hosts.tab.effective") }
        }

        public enum UI {
            public static var addLine: String { L10n.tr("hosts.ui.addLine") }
            public static func appliedToast(_ summary: String) -> String { L10n.format("hosts.ui.appliedToast", summary) }
            public static var applyA11y: String { L10n.tr("hosts.ui.applyA11y") }
            public static var applyNoticeDirect: String { L10n.tr("hosts.ui.applyNoticeDirect") }
            public static var applyNoticePrivileged: String { L10n.tr("hosts.ui.applyNoticePrivileged") }
            public static func applySummaryNotice(_ summary: String, _ notice: String) -> String {
                L10n.format("hosts.ui.applySummaryNotice", summary, notice)
            }
            public static var applyTitle: String { L10n.tr("hosts.ui.applyTitle") }
            public static func backedUpToast(_ name: String) -> String { L10n.format("hosts.ui.backedUpToast", name) }
            public static var backupNow: String { L10n.tr("hosts.ui.backupNow") }
            public static var backupsMenu: String { L10n.tr("hosts.ui.backupsMenu") }
            public static var baseLockedNote: String { L10n.tr("hosts.ui.baseLockedNote") }
            public static var baseOffConfirm: String { L10n.tr("hosts.ui.baseOffConfirm") }
            public static func baseOffMessage(_ title: String, _ count: Int) -> String {
                L10n.format("hosts.ui.baseOffMessage", title, Int64(count))
            }
            public static var baseOffTitle: String { L10n.tr("hosts.ui.baseOffTitle") }
            public static var baseOverlayHeader: String { L10n.tr("hosts.ui.baseOverlayHeader") }
            public static var baseTag: String { L10n.tr("hosts.ui.baseTag") }
            public static func bulkDisabledWarning(_ count: Int) -> String {
                L10n.format("hosts.ui.bulkDisabledWarning", Int64(count))
            }
            public static var bulkFormatFallback: String { L10n.tr("hosts.ui.bulkFormatFallback") }
            public static func bulkHeaderError(_ line: Int) -> String { L10n.format("hosts.ui.bulkHeaderError", Int64(line)) }
            public static var bulkHint: String { L10n.tr("hosts.ui.bulkHint") }
            public static func bulkLineError(_ line: Int, _ detail: String) -> String {
                L10n.format("hosts.ui.bulkLineError", Int64(line), detail)
            }
            public static var bulkMissingSection: String { L10n.tr("hosts.ui.bulkMissingSection") }
            public static func bulkSavedToast(_ count: Int) -> String { L10n.format("hosts.ui.bulkSavedToast", Int64(count)) }
            public static func bulkTitle(_ title: String) -> String { L10n.format("hosts.ui.bulkTitle", title) }
            public static var conflictConfirm: String { L10n.tr("hosts.ui.conflictConfirm") }
            public static var conflictDomainJoiner: String { L10n.tr("hosts.ui.conflictDomainJoiner") }
            public static func conflictMessage(_ sample: String, _ suffix: String) -> String {
                L10n.format("hosts.ui.conflictMessage", sample, suffix)
            }
            public static func conflictMore(_ count: Int) -> String { L10n.format("hosts.ui.conflictMore", Int64(count)) }
            public static var conflictTitle: String { L10n.tr("hosts.ui.conflictTitle") }
            public static func conflictsA11y(_ count: Int) -> String { L10n.format("hosts.ui.conflictsA11y", Int64(count)) }
            public static var conflictsExplainer: String { L10n.tr("hosts.ui.conflictsExplainer") }
            public static func conflictsHeader(_ count: Int) -> String { L10n.format("hosts.ui.conflictsHeader", Int64(count)) }
            public static var createFailed: String { L10n.tr("hosts.ui.createFailed") }
            public static var createSectionHint: String { L10n.tr("hosts.ui.createSectionHint") }
            public static var createSectionTitle: String { L10n.tr("hosts.ui.createSectionTitle") }
            public static var crossConflictLabel: String { L10n.tr("hosts.ui.crossConflictLabel") }
            public static var deleteLineMenu: String { L10n.tr("hosts.ui.deleteLineMenu") }
            public static var deleteSectionAction: String { L10n.tr("hosts.ui.deleteSectionAction") }
            public static func deleteSectionMessage(_ title: String, _ count: Int) -> String {
                L10n.format("hosts.ui.deleteSectionMessage", title, Int64(count))
            }
            public static var deleteSectionTitle: String { L10n.tr("hosts.ui.deleteSectionTitle") }
            public static var diffAdded: String { L10n.tr("hosts.ui.diffAdded") }
            public static var diffChanged: String { L10n.tr("hosts.ui.diffChanged") }
            public static var diffRemoved: String { L10n.tr("hosts.ui.diffRemoved") }
            public static func diffSameAsTarget(_ path: String) -> String { L10n.format("hosts.ui.diffSameAsTarget", path) }
            public static var disableLineA11y: String { L10n.tr("hosts.ui.disableLineA11y") }
            public static var disableSection: String { L10n.tr("hosts.ui.disableSection") }
            public static func disabledLinesShort(_ count: Int) -> String {
                L10n.format("hosts.ui.disabledLinesShort", Int64(count))
            }
            public static var disabledTag: String { L10n.tr("hosts.ui.disabledTag") }
            public static var dragHint: String { L10n.tr("hosts.ui.dragHint") }
            public static var editBulk: String { L10n.tr("hosts.ui.editBulk") }
            public static var editLineMenu: String { L10n.tr("hosts.ui.editLineMenu") }
            public static var editLineTitle: String { L10n.tr("hosts.ui.editLineTitle") }
            public static var enableLineA11y: String { L10n.tr("hosts.ui.enableLineA11y") }
            public static var enableSection: String { L10n.tr("hosts.ui.enableSection") }
            public static func entriesShort(_ count: Int) -> String { L10n.format("hosts.ui.entriesShort", Int64(count)) }
            public static func errorsA11y(_ count: Int) -> String { L10n.format("hosts.ui.errorsA11y", Int64(count)) }
            public static func externalBanner(_ path: String) -> String { L10n.format("hosts.ui.externalBanner", path) }
            public static var insertBelowMenu: String { L10n.tr("hosts.ui.insertBelowMenu") }
            public static var insertLineFailed: String { L10n.tr("hosts.ui.insertLineFailed") }
            public static var insertLineTitle: String { L10n.tr("hosts.ui.insertLineTitle") }
            public static func issueLine(_ section: String, _ line: Int, _ message: String) -> String {
                L10n.format("hosts.ui.issueLine", section, Int64(line), message)
            }
            public static func issuesHeader(_ errors: Int, _ warnings: Int) -> String {
                L10n.format("hosts.ui.issuesHeader", Int64(errors), Int64(warnings))
            }
            public static func issuesMore(_ count: Int) -> String { L10n.format("hosts.ui.issuesMore", Int64(count)) }
            public static var keepToolVersion: String { L10n.tr("hosts.ui.keepToolVersion") }
            public static var lastWinsHint: String { L10n.tr("hosts.ui.lastWinsHint") }
            public static var lineHint: String { L10n.tr("hosts.ui.lineHint") }
            public static var linePlaceholder: String { L10n.tr("hosts.ui.linePlaceholder") }
            public static func linesCount(_ count: Int) -> String { L10n.format("hosts.ui.linesCount", Int64(count)) }
            public static func mappingsCount(_ count: Int) -> String { L10n.format("hosts.ui.mappingsCount", Int64(count)) }
            public static var newOverlayA11y: String { L10n.tr("hosts.ui.newOverlayA11y") }
            public static var newSection: String { L10n.tr("hosts.ui.newSection") }
            public static var noBackups: String { L10n.tr("hosts.ui.noBackups") }
            public static var noEffective: String { L10n.tr("hosts.ui.noEffective") }
            public static var noMatchingDomain: String { L10n.tr("hosts.ui.noMatchingDomain") }
            public static var overlayTag: String { L10n.tr("hosts.ui.overlayTag") }
            public static var reimportConfirm: String { L10n.tr("hosts.ui.reimportConfirm") }
            public static var reimportMessage: String { L10n.tr("hosts.ui.reimportMessage") }
            public static func reimportTitle(_ path: String) -> String { L10n.format("hosts.ui.reimportTitle", path) }
            public static var reload: String { L10n.tr("hosts.ui.reload") }
            public static var renameDots: String { L10n.tr("hosts.ui.renameDots") }
            public static var renameFailed: String { L10n.tr("hosts.ui.renameFailed") }
            public static var renameSectionHint: String { L10n.tr("hosts.ui.renameSectionHint") }
            public static var renameSectionTitle: String { L10n.tr("hosts.ui.renameSectionTitle") }
            public static func restoreBackupItem(_ label: String, _ name: String) -> String {
                L10n.format("hosts.ui.restoreBackupItem", label, name)
            }
            public static func restoreBeforeApply(_ name: String) -> String { L10n.format("hosts.ui.restoreBeforeApply", name) }
            public static var restoreConfirm: String { L10n.tr("hosts.ui.restoreConfirm") }
            public static func restoreMessage(_ label: String, _ target: String) -> String {
                L10n.format("hosts.ui.restoreMessage", label, target)
            }
            public static var restoreTitle: String { L10n.tr("hosts.ui.restoreTitle") }
            public static func restoredToast(_ name: String) -> String { L10n.format("hosts.ui.restoredToast", name) }
            public static var searchPlaceholder: String { L10n.tr("hosts.ui.searchPlaceholder") }
            public static var sectionNamePlaceholder: String { L10n.tr("hosts.ui.sectionNamePlaceholder") }
            public static var sectionsHeader: String { L10n.tr("hosts.ui.sectionsHeader") }
            public static var selectSectionHint: String { L10n.tr("hosts.ui.selectSectionHint") }
            public static func statusApplying(_ path: String) -> String { L10n.format("hosts.ui.statusApplying", path) }
            public static func statusDetailCount(_ enabled: Int, _ total: Int, _ active: Int) -> String {
                L10n.format("hosts.ui.statusDetailCount", Int64(enabled), Int64(total), Int64(active))
            }
            public static func statusDetailExternal(_ path: String) -> String { L10n.format("hosts.ui.statusDetailExternal", path) }
            public static func statusDetailLastApplied(_ base: String, _ time: String) -> String {
                L10n.format("hosts.ui.statusDetailLastApplied", base, time)
            }
            public static var statusExternal: String { L10n.tr("hosts.ui.statusExternal") }
            public static func statusSynced(_ path: String) -> String { L10n.format("hosts.ui.statusSynced", path) }
            public static var updateLineFailed: String { L10n.tr("hosts.ui.updateLineFailed") }
            public static var validationErrorFallback: String { L10n.tr("hosts.ui.validationErrorFallback") }
            public static var waitingExternal: String { L10n.tr("hosts.ui.waitingExternal") }
            public static var warningFallback: String { L10n.tr("hosts.ui.warningFallback") }
            public static func warningsCount(_ count: Int) -> String { L10n.format("hosts.ui.warningsCount", Int64(count)) }
        }
    }

    // MARK: - Hotkey

    public enum Hotkey {
        public static func appMissing(_ key: String) -> String { L10n.format("hotkey.appMissing", key) }
        public static func conflict(_ display: String, _ status: Int32) -> String {
            L10n.format("hotkey.conflict", display, status)
        }
        public static func handlerFailed(_ status: Int32) -> String { L10n.format("hotkey.handlerFailed", status) }
        public static var handlerUnavailable: String { L10n.tr("hotkey.handlerUnavailable") }
        public static func hostsWriteFailed(_ detail: String) -> String { L10n.format("hotkey.hostsWriteFailed", detail) }
        public static func launchAppFailed(_ name: String, _ error: String) -> String {
            L10n.format("hotkey.launchAppFailed", name, error)
        }
        public static var missingModifier: String { L10n.tr("hotkey.missingModifier") }
        public static var thisSection: String { L10n.tr("hotkey.thisSection") }

        public enum Dispatch {
            public static var appDisabled: String { L10n.tr("hotkey.dispatch.appDisabled") }
            public static func appMissing(_ key: String) -> String { L10n.format("hotkey.dispatch.appMissing", key) }
            public static var clipboardFailed: String { L10n.tr("hotkey.dispatch.clipboardFailed") }
            public static func hostsAlreadyActive(_ title: String) -> String {
                L10n.format("hotkey.dispatch.hostsAlreadyActive", title)
            }
            public static var hostsBusy: String { L10n.tr("hotkey.dispatch.hostsBusy") }
            public static var hostsDisabled: String { L10n.tr("hotkey.dispatch.hostsDisabled") }
            public static var hostsMissing: String { L10n.tr("hotkey.dispatch.hostsMissing") }
            public static func hostsSelected(_ title: String) -> String { L10n.format("hotkey.dispatch.hostsSelected", title) }
            public static func launching(_ name: String) -> String { L10n.format("hotkey.dispatch.launching", name) }
            public static func otpCopied(_ label: String) -> String { L10n.format("hotkey.dispatch.otpCopied", label) }
            public static var otpDisabled: String { L10n.tr("hotkey.dispatch.otpDisabled") }
            public static func otpMissing(_ issuer: String) -> String { L10n.format("hotkey.dispatch.otpMissing", issuer) }
            public static func otpSecretMissing(_ label: String) -> String {
                L10n.format("hotkey.dispatch.otpSecretMissing", label)
            }
            public static func unknownTarget(_ key: String) -> String { L10n.format("hotkey.dispatch.unknownTarget", key) }
        }

        public enum Group {
            public static var panel: String { L10n.tr("hotkey.group.panel") }
            public static var hosts: String { L10n.tr("hotkey.group.hosts") }
            public static var otp: String { L10n.tr("hotkey.group.otp") }
            public static var app: String { L10n.tr("hotkey.group.app") }
        }

        public enum Orphan {
            public static var section: String { L10n.tr("hotkey.orphan.section") }
        }

        public enum Target {
            public static var hostsBase: String { L10n.tr("hotkey.target.hostsBase") }
            public static var hostsOverlay: String { L10n.tr("hotkey.target.hostsOverlay") }
            public static func otpMultiple(_ count: Int) -> String { L10n.format("hotkey.target.otpMultiple", Int64(count)) }
            public static var otpSingle: String { L10n.tr("hotkey.target.otpSingle") }
            public static var panel: String { L10n.tr("hotkey.target.panel") }
        }
    }

    // MARK: - Shortcuts Settings

    public enum Shortcuts {
        public static var add: String { L10n.tr("shortcuts.add") }
        public static var app: String { L10n.tr("shortcuts.app") }
        public static func conflict(_ combo: String, _ target: String) -> String {
            L10n.format("shortcuts.conflict", combo, target)
        }
        public static var doubleTap: String { L10n.tr("shortcuts.doubleTap") }
        public static func fallbackAvailable(_ combo: String) -> String {
            L10n.format("shortcuts.fallbackAvailable", combo)
        }
        public static var fallbackCombo: String { L10n.tr("shortcuts.fallbackCombo") }
        public static func inputMonitoringGranted(_ modifier: String) -> String {
            L10n.format("shortcuts.inputMonitoringGranted", modifier)
        }
        public static var inputMonitoringHint: String { L10n.tr("shortcuts.inputMonitoringHint") }
        public static func inputMonitoringMissing(_ combo: String) -> String {
            L10n.format("shortcuts.inputMonitoringMissing", combo)
        }
        public static var loadingApps: String { L10n.tr("shortcuts.loadingApps") }
        public static var modifier: String { L10n.tr("shortcuts.modifier") }
        public static var orphansHint: String { L10n.tr("shortcuts.orphansHint") }
        public static var pressKeys: String { L10n.tr("shortcuts.pressKeys") }
        public static var record: String { L10n.tr("shortcuts.record") }
        public static func registerFailed(_ combo: String) -> String { L10n.format("shortcuts.registerFailed", combo) }
        public static var rerecord: String { L10n.tr("shortcuts.rerecord") }
        public static var status: String { L10n.tr("shortcuts.status") }
        public static var summonMode: String { L10n.tr("shortcuts.summonMode") }
        public static var unset: String { L10n.tr("shortcuts.unset") }

        public enum Empty {
            public static var app: String { L10n.tr("shortcuts.empty.app") }
            public static var hosts: String { L10n.tr("shortcuts.empty.hosts") }
            public static var otp: String { L10n.tr("shortcuts.empty.otp") }
        }

        public enum Section {
            public static var lastAction: String { L10n.tr("shortcuts.section.lastAction") }
            public static var orphans: String { L10n.tr("shortcuts.section.orphans") }
            public static var summon: String { L10n.tr("shortcuts.section.summon") }
        }
    }

    // MARK: - OTP

    public enum OTP {
        public static func accountFallback(_ index: Int) -> String { L10n.format("otp.accountFallback", Int64(index)) }
        public static var addFailed: String { L10n.tr("otp.addFailed") }
        public static func addedNamed(_ name: String) -> String { L10n.format("otp.addedNamed", name) }
        public static var calibrate: String { L10n.tr("otp.calibrate") }
        public static var copiedDetail: String { L10n.tr("otp.copiedDetail") }
        public static var copyCode: String { L10n.tr("otp.copyCode") }
        public static func counterDetail(_ counter: Int) -> String { L10n.format("otp.counterDetail", Int64(counter)) }
        public static var deleteAccount: String { L10n.tr("otp.deleteAccount") }
        public static var deleteFailed: String { L10n.tr("otp.deleteFailed") }
        public static var deleteMessageLocal: String { L10n.tr("otp.deleteMessageLocal") }
        public static var deleteMessageSync: String { L10n.tr("otp.deleteMessageSync") }
        public static var deleteTitleDefault: String { L10n.tr("otp.deleteTitleDefault") }
        public static func deleteTitleNamed(_ name: String) -> String { L10n.format("otp.deleteTitleNamed", name) }
        public static func digits8(_ period: String) -> String { L10n.format("otp.digits8", period) }
        public static var emptyAccounts: String { L10n.tr("otp.emptyAccounts") }
        public static var noMatch: String { L10n.tr("otp.noMatch") }
        public static func periodSeconds(_ seconds: Int) -> String { L10n.format("otp.periodSeconds", Int64(seconds)) }
        public static var searchPlaceholder: String { L10n.tr("otp.searchPlaceholder") }
        public static func secretMissingRemoveTitle(_ name: String) -> String {
            L10n.format("otp.secretMissingRemoveTitle", name)
        }
        public static var unnamed: String { L10n.tr("otp.unnamed") }
        public static var unparseable: String { L10n.tr("otp.unparseable") }

        public enum Health {
            public static func denied(_ count: Int) -> String { L10n.format("otp.health.denied", Int64(count)) }
            public static func missing(_ count: Int) -> String { L10n.format("otp.health.missing", Int64(count)) }
        }

        public enum Import {
            public static var action: String { L10n.tr("otp.import.action") }
            public static func addedCount(_ count: Int) -> String { L10n.format("otp.import.addedCount", Int64(count)) }
            public static func allFailedCount(_ count: Int) -> String { L10n.format("otp.import.allFailedCount", Int64(count)) }
            public static var batchIncompleteLabel: String { L10n.tr("otp.import.batchIncompleteLabel") }
            public static func batchIncompleteReason(_ total: Int, _ received: Int) -> String {
                L10n.format("otp.import.batchIncompleteReason", Int64(total), Int64(received))
            }
            public static func batchMultiple(_ count: Int) -> String { L10n.format("otp.import.batchMultiple", Int64(count)) }
            public static func batchOne(_ total: Int, _ received: Int, _ remaining: Int) -> String {
                L10n.format("otp.import.batchOne", Int64(total), Int64(received), Int64(remaining))
            }
            public static var button: String { L10n.tr("otp.import.button") }
            public static var description: String { L10n.tr("otp.import.description") }
            public static func moreFailures(_ count: Int) -> String { L10n.format("otp.import.moreFailures", Int64(count)) }
            public static var noClipboardImage: String { L10n.tr("otp.import.noClipboardImage") }
            public static var noneAdded: String { L10n.tr("otp.import.noneAdded") }
            public static var pasteImage: String { L10n.tr("otp.import.pasteImage") }
            public static var pastedLabel: String { L10n.tr("otp.import.pastedLabel") }
            public static var pastedMissingLink: String { L10n.tr("otp.import.pastedMissingLink") }
            public static var pickImage: String { L10n.tr("otp.import.pickImage") }
            public static var pickNextQR: String { L10n.tr("otp.import.pickNextQR") }
            public static var placeholder: String { L10n.tr("otp.import.placeholder") }
            public static var title: String { L10n.tr("otp.import.title") }
        }

        public enum Keychain {
            public static var deleteFailed: String { L10n.tr("otp.keychain.deleteFailed") }
            public static func error(_ status: Int32) -> String { L10n.format("otp.keychain.error", status) }
            public static var mockWriteFailed: String { L10n.tr("otp.keychain.mockWriteFailed") }
            public static func orphanRefused(_ count: Int) -> String { L10n.format("otp.keychain.orphanRefused", Int64(count)) }
            public static var writeFailed: String { L10n.tr("otp.keychain.writeFailed") }
        }

        public enum Manual {
            public static var account: String { L10n.tr("otp.manual.account") }
            public static var digitsTitle: String { L10n.tr("otp.manual.digitsTitle") }
            public static func digitsValue(_ count: Int) -> String { L10n.format("otp.manual.digitsValue", Int64(count)) }
            public static var heading: String { L10n.tr("otp.manual.heading") }
            public static var issuer: String { L10n.tr("otp.manual.issuer") }
            public static var labelFallback: String { L10n.tr("otp.manual.labelFallback") }
            public static var noteLocal: String { L10n.tr("otp.manual.noteLocal") }
            public static var noteSync: String { L10n.tr("otp.manual.noteSync") }
            public static var secret: String { L10n.tr("otp.manual.secret") }
            public static var unparseable: String { L10n.tr("otp.manual.unparseable") }
        }

        public enum Migration {
            public static var batchLink: String { L10n.tr("otp.migration.batchLink") }
            public static var emptySecret: String { L10n.tr("otp.migration.emptySecret") }
            public static var encrypted: String { L10n.tr("otp.migration.encrypted") }
            public static var missingData: String { L10n.tr("otp.migration.missingData") }
            public static var noAccounts: String { L10n.tr("otp.migration.noAccounts") }
            public static var notLink: String { L10n.tr("otp.migration.notLink") }
            public static var truncated: String { L10n.tr("otp.migration.truncated") }
            public static func unsupportedAlgorithm(_ code: Int32) -> String {
                L10n.format("otp.migration.unsupportedAlgorithm", code)
            }
        }

        public enum Note {
            public static var action: String { L10n.tr("otp.note.action") }
            public static var message: String { L10n.tr("otp.note.message") }
            public static var placeholder: String { L10n.tr("otp.note.placeholder") }
            public static var title: String { L10n.tr("otp.note.title") }
        }

        public enum QR {
            public static var noBarcode: String { L10n.tr("otp.qr.noBarcode") }
            public static var unreadable: String { L10n.tr("otp.qr.unreadable") }
        }

        public enum Subtitle {
            public static func count(_ count: Int) -> String { L10n.format("otp.subtitle.count", Int64(count)) }
            public static func drift(_ base: String, _ sign: String, _ offset: Int) -> String {
                L10n.format("otp.subtitle.drift", base, sign, Int64(offset))
            }
        }

        public enum URI {
            public static func invalidDigits(_ digits: Int) -> String { L10n.format("otp.uri.invalidDigits", Int64(digits)) }
            public static func invalidPeriod(_ period: Int) -> String { L10n.format("otp.uri.invalidPeriod", Int64(period)) }
            public static var invalidSecret: String { L10n.tr("otp.uri.invalidSecret") }
            public static var missingCounter: String { L10n.tr("otp.uri.missingCounter") }
            public static var missingLabel: String { L10n.tr("otp.uri.missingLabel") }
            public static var missingSecret: String { L10n.tr("otp.uri.missingSecret") }
            public static var notOtpauth: String { L10n.tr("otp.uri.notOtpauth") }
            public static func unsupportedAlgorithm(_ raw: String) -> String { L10n.format("otp.uri.unsupportedAlgorithm", raw) }
            public static func unsupportedKind(_ raw: String) -> String { L10n.format("otp.uri.unsupportedKind", raw) }
        }
    }

    // MARK: - Permissions

    public enum Permissions {
        public static var granted: String { L10n.tr("permissions.granted") }
        public static var denied: String { L10n.tr("permissions.denied") }
        public static var notDetermined: String { L10n.tr("permissions.notDetermined") }
        public static var unavailable: String { L10n.tr("permissions.unavailable") }
        public static var openSettingsButton: String { L10n.tr("permissions.openSettingsButton") }
        public static var refresh: String { L10n.tr("permissions.refresh") }
        public static var request: String { L10n.tr("permissions.request") }

        public enum Files {
            public static var title: String { L10n.tr("permissions.files.title") }
            public static var detail: String { L10n.tr("permissions.files.detail") }
            public static var help: String { L10n.tr("permissions.files.help") }
        }

        public enum InputMonitoring {
            public static var title: String { L10n.tr("permissions.inputMonitoring.title") }
            public static var detail: String { L10n.tr("permissions.inputMonitoring.detail") }
        }
    }

    // MARK: - Quicklink

    public enum Quicklink {
        public static func deleteA11y(_ title: String) -> String { L10n.format("quicklink.deleteA11y", title) }
        public static var empty: String { L10n.tr("quicklink.empty") }
        public static var keywordField: String { L10n.tr("quicklink.keywordField") }
        public static var nameField: String { L10n.tr("quicklink.nameField") }
        public static var savedHeader: String { L10n.tr("quicklink.savedHeader") }
        public static var sectionNew: String { L10n.tr("quicklink.sectionNew") }
        public static var templateField: String { L10n.tr("quicklink.templateField") }

        public enum Error {
            public static func duplicateKeyword(_ keyword: String) -> String {
                L10n.format("quicklink.error.duplicateKeyword", keyword)
            }
            public static var emptyKeyword: String { L10n.tr("quicklink.error.emptyKeyword") }
            public static var emptyTitle: String { L10n.tr("quicklink.error.emptyTitle") }
            public static func invalidTemplate(_ reason: String) -> String {
                L10n.format("quicklink.error.invalidTemplate", reason)
            }
            public static var keywordWhitespace: String { L10n.tr("quicklink.error.keywordWhitespace") }
            public static var templateEmpty: String { L10n.tr("quicklink.error.templateEmpty") }
            public static var templateScheme: String { L10n.tr("quicklink.error.templateScheme") }
        }
    }

    // MARK: - Reminder

    public enum Reminder {
        public static var sevenDays: String { L10n.tr("reminder.7days") }
        public static var activeHeader: String { L10n.tr("reminder.activeHeader") }
        public static var bothDisabled: String { L10n.tr("reminder.bothDisabled") }
        public static var completeOnce: String { L10n.tr("reminder.completeOnce") }
        public static func countSuffix(_ prefix: String, _ count: Int) -> String {
            L10n.format("reminder.countSuffix", prefix, Int64(count))
        }
        public static func detailWindow(_ interval: String, _ start: String, _ end: String) -> String {
            L10n.format("reminder.detailWindow", interval, start, end)
        }
        public static var joinAnd: String { L10n.tr("reminder.joinAnd") }
        public static func off(_ label: String) -> String { L10n.format("reminder.off", label) }
        public static func outsideWindow(_ label: String) -> String { L10n.format("reminder.outsideWindow", label) }
        public static var pausedHeader: String { L10n.tr("reminder.pausedHeader") }
        public static var skipWeekendsTag: String { L10n.tr("reminder.skipWeekendsTag") }
        public static var snoozeButton: String { L10n.tr("reminder.snoozeButton") }
        public static func statA11y(_ title: String, _ completed: Int, _ target: Int) -> String {
            L10n.format("reminder.statA11y", title, Int64(completed), Int64(target))
        }
        public static func todayCount(_ count: Int) -> String { L10n.format("reminder.todayCount", Int64(count)) }

        public enum Label {
            public static var stand: String { L10n.tr("reminder.label.stand") }
            public static var water: String { L10n.tr("reminder.label.water") }
        }

        public enum Display {
            public static func hours(_ h: Int) -> String { L10n.format("reminder.display.hours", Int64(h)) }
            public static func hoursMinutes(_ h: Int, _ m: Int) -> String {
                L10n.format("reminder.display.hoursMinutes", Int64(h), Int64(m))
            }
            public static func inPrefix(_ value: String) -> String { L10n.format("reminder.display.inPrefix", value) }
            public static func minutes(_ m: Int) -> String { L10n.format("reminder.display.minutes", Int64(m)) }
            public static func nextPrefix(_ value: String) -> String { L10n.format("reminder.display.nextPrefix", value) }
            public static func tomorrow(_ time: String) -> String { L10n.format("reminder.display.tomorrow", time) }
            public static func weekday(_ zeroBasedSunToSat: Int) -> String {
                let idx = ((zeroBasedSunToSat % 7) + 7) % 7
                return L10n.tr("reminder.display.weekday.\(idx)")
            }
        }

        public enum Overlay {
            public static func autoDismiss(_ seconds: Int) -> String {
                L10n.format("reminder.overlay.autoDismiss", Int64(seconds))
            }
            public static var bodyStand: String { L10n.tr("reminder.overlay.body.stand") }
            public static var bodyWater: String { L10n.tr("reminder.overlay.body.water") }
            public static var complete: String { L10n.tr("reminder.overlay.complete") }
            public static func snoozeMinutes(_ minutes: Int) -> String {
                L10n.format("reminder.overlay.snoozeMinutes", Int64(minutes))
            }
            public static var titleStand: String { L10n.tr("reminder.overlay.title.stand") }
            public static var titleWater: String { L10n.tr("reminder.overlay.title.water") }
        }

        public enum Settings {
            public static var addFocus: String { L10n.tr("reminder.settings.addFocus") }
            public static var blacklistPlaceholder: String { L10n.tr("reminder.settings.blacklistPlaceholder") }
            public static var dndFooter: String { L10n.tr("reminder.settings.dndFooter") }
            public static var dndSection: String { L10n.tr("reminder.settings.dndSection") }
            public static func duplicateBlacklist(_ id: String) -> String {
                L10n.format("reminder.settings.duplicateBlacklist", id)
            }
            public static var emptyBlacklist: String { L10n.tr("reminder.settings.emptyBlacklist") }
            public static func focusDuplicate(_ text: String) -> String { L10n.format("reminder.settings.focusDuplicate", text) }
            public static var focusInvalid: String { L10n.tr("reminder.settings.focusInvalid") }
            public static func focusRow(_ range: String) -> String { L10n.format("reminder.settings.focusRow", range) }
            public static var interval: String { L10n.tr("reminder.settings.interval") }
            public static var invalidWindow: String { L10n.tr("reminder.settings.invalidWindow") }
            public static var menuCountdown: String { L10n.tr("reminder.settings.menuCountdown") }
            public static var preview: String { L10n.tr("reminder.settings.preview") }
            public static var screenDesc: String { L10n.tr("reminder.settings.screenDesc") }
            public static var screenSection: String { L10n.tr("reminder.settings.screenSection") }
            public static var skipWeekends: String { L10n.tr("reminder.settings.skipWeekends") }
            public static var snooze: String { L10n.tr("reminder.settings.snooze") }
            public static var windowEnd: String { L10n.tr("reminder.settings.windowEnd") }
            public static var windowStart: String { L10n.tr("reminder.settings.windowStart") }
        }
    }
}
