import AppKit
import os

public enum ActionError: LocalizedError {
    case applicationNotFound(String)
    case launchFailed(String, String)
    case terminalFailed(String)
    case openFailed(String)
    case meetingNotInstalled
    case meetingNeedsPaste
    case clipboardFailed
    case otpCodeUnavailable
    case appNotRunning(String)
    case appDidNotQuit(String)
    case urlRejected(String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let name):
            return L10n.Actions.appMissing(name)
        case .launchFailed(let name, let reason):
            return L10n.Actions.launchFailed(name, reason)
        case .terminalFailed(let reason):
            return L10n.Actions.terminalFailed(reason)
        case .openFailed(let path):
            return L10n.Actions.fileOpenFailed(path)
        case .meetingNotInstalled:
            // 兜底不报「无法打开」，号码已经在剪贴板里
            return L10n.Actions.tencentMeetingUnavailable
        case .clipboardFailed:
            return L10n.Actions.clipboardFailed
        case .otpCodeUnavailable:
            return L10n.Actions.otpSecretMissing
        case .appNotRunning(let name):
            return L10n.Actions.appNotRunning(name)
        case .appDidNotQuit(let name):
            return L10n.Actions.quitTimedOut(name)
        case .urlRejected(let url):
            return L10n.Actions.invalidURL(url)
        case .meetingNeedsPaste:
            return L10n.Actions.meetingJoinFailed
        }
    }
}

/// 所有结果行的唯一执行出口。视图只负责调用，不再各自拼 AppKit 调用。
@MainActor
public enum ActionDispatcher {
    private static let launchLog = Logger(subsystem: "app.misckit.launcher", category: "launch")

    public static func perform(_ action: ToolAction) async throws {
        switch action {
        case .none, .openTool, .editAppAlias, .prefillQuery:
            return

        case .systemAction(let code):
            _ = try await SystemControl.performAsync(code)

        case .openURL(let url):
            guard NSWorkspace.shared.open(url) else {
                throw ActionError.urlRejected(url.absoluteString)
            }

        case .openDictionary(let word):
            let encoded = word.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? word
            guard let url = URL(string: "dict://\(encoded)"), NSWorkspace.shared.open(url) else {
                throw ActionError.urlRejected("dict://\(word)")
            }

        case .copy(let text):
            guard ClipboardGuard.shared.write(text) else {
                throw ActionError.clipboardFailed
            }

        case .copySecret(let text):
            guard ClipboardGuard.shared.copySecret(text) else {
                throw ActionError.clipboardFailed
            }

        case .copyOTP(let accountID):
            guard let account = OTPStore.shared.accounts.first(where: { $0.id == accountID }),
                  let code = OTPStore.shared.code(for: account) else {
                throw ActionError.otpCodeUnavailable
            }
            guard ClipboardGuard.shared.copySecret(code) else {
                throw ActionError.clipboardFailed
            }
            if account.kind == .hotp { OTPStore.shared.advanceCounter(account) }

        case .copyItems(let urls):
            guard ClipboardGuard.shared.copyFiles(urls) else {
                throw ActionError.clipboardFailed
            }

        case .quitApp(let appID):
            _ = try runningApp(appID).terminate()

        case .forceQuitApp(let appID):
            _ = try runningApp(appID).forceTerminate()

        case .relaunchApp(let url, let appID):
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                isSameApp($0, appID: appID) && !$0.isTerminated
            }) {
                let pid = app.processIdentifier
                app.terminate()
                // 没退干净就再拉一次，单例机制会把新实例挡回来，看着像"重启没反应"。
                // 等不到就取消：它多半弹了保存提示，这时候硬拉等于替人做了决定。
                guard await Self.exited(pid: pid) else {
                    throw ActionError.appDidNotQuit(displayName(for: appID))
                }
            }
            try await perform(.launchApp(url: url, appID: appID))

        case .openFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ActionError.openFailed(url.lastPathComponent)
            }
            guard NSWorkspace.shared.open(url) else {
                throw ActionError.openFailed(url.lastPathComponent)
            }
            FileHistoryStore.shared.recordOpen(url)

        case .openInTerminal(let url):
            let directory = Self.directoryTarget(for: url)
            try await openTerminalAsync(at: directory)
            FileHistoryStore.shared.recordOpen(url)

        case .reveal(let url):
            guard let url else { return }
            let target = FileManager.default.fileExists(atPath: url.path)
                ? url
                : url.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])

        case .joinMeeting(let code):
            // 先复制再入会：scheme 没被接住时用户手上就有号码，不会卡在提示上。
            ClipboardGuard.shared.write(code)
            if let url = TencentMeeting.joinURL(code: code), NSWorkspace.shared.open(url) {
                return
            }
            let installed = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: TencentMeeting.bundleID)
            if let appURL = installed {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: appURL,
                                                                  configuration: configuration)
                throw ActionError.meetingNeedsPaste
            }
            throw ActionError.meetingNotInstalled

        case .launchApp(let url, let appID):
            let name = url.deletingPathExtension().lastPathComponent
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ActionError.applicationNotFound(name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url,
                                                                 configuration: configuration)
            } catch {
                throw ActionError.launchFailed(name, error.localizedDescription)
            }
            AppIndex.shared.recordLaunch(appID)
            guard !(await Self.vanished(appID: appID)) else {
                // 第一发没等到窗口，多半是瞬时状态：上一个实例还没退干净、LaunchServices 冷
                // 启动、刚换过包。隔 400 毫秒自动再拉一次，别让人手动点第二遍。
                try? await Task.sleep(for: .milliseconds(400))
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url,
                                                                     configuration: configuration)
                } catch {
                    throw ActionError.launchFailed(name, error.localizedDescription)
                }
                guard !(await Self.vanished(appID: appID)) else {
                    // 两发都没等到窗口：只有写进日志，不弹窗。这类失败多半是目标 App 自己的
                    // 决定（单例、企业策略）或用户随手关掉，弹一次只会打扰人。
                    Self.launchLog.log("两发都没等到窗口 目标=\(name, privacy: .public)")
                    return
                }
                return
            }
        }
    }

    /// 没有 CFBundleIdentifier 的应用，id 是包路径（见 `AppScanner.makeApp`）。
    /// 判活只按 bundleIdentifier 找会永远找不到，把正常拉起误判成"起不来"并白白再拉一次。
    nonisolated static func matchesAppID(bundleID: String?, bundleURL: URL?, appID: String) -> Bool {
        if let bundleID, bundleID == appID { return true }
        guard let bundleURL else { return false }
        return bundleURL.standardizedFileURL.path == appID
    }

    private static func isSameApp(_ app: NSRunningApplication, appID: String) -> Bool {
        matchesAppID(bundleID: app.bundleIdentifier, bundleURL: app.bundleURL, appID: appID)
    }

    private static func runningApp(_ appID: String) throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            isSameApp($0, appID: appID) && !$0.isTerminated
        }) else {
            throw ActionError.appNotRunning(displayName(for: appID))
        }
        return app
    }

    private static func displayName(for appID: String) -> String {
        AppIndex.shared.app(withID: appID)?.name ?? appID
    }

    /// 判活沿用 `kill(pid, 0)`：`isTerminated` 和 runningApplications 的登记都滞后。
    private static func exited(pid: pid_t) async -> Bool {
        guard pid > 0 else { return true }
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }

    /// 等它出现、再盯 1.2 秒：进程真没了、又从没到过前台、也不是把前台交接给一个已在跑的
    /// 单例实例，才算"它起不来"。判活一律用 `kill(pid, 0)`——`isTerminated` 与
    /// `runningApplications` 的登记都滞后，几百毫秒的进程从中途采样会误判成"活着"。
    /// **到过前台就不再算失败**：那是正常开过、被用户（或它自己）关掉的，不该弹报错。
    private static func vanished(appID: String) async -> Bool {
        var pid: pid_t = 0
        for _ in 0..<20 {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                isSameApp($0, appID: appID) && !$0.isTerminated && $0.processIdentifier > 0
            }) {
                pid = app.processIdentifier
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard pid > 0 else { return true }
        var wasFront = false
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == pid
            }), app.isActive {
                wasFront = true
            }
            if kill(pid, 0) != 0 { break }
        }
        guard kill(pid, 0) != 0 else { return false }
        guard !wasFront else { return false }
        return !NSWorkspace.shared.runningApplications.contains {
            isSameApp($0, appID: appID) && !$0.isTerminated && kill($0.processIdentifier, 0) == 0
        }
    }

    nonisolated public static func openTerminal(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", directory.path]
        do {
            try process.run()
        } catch {
            throw ActionError.terminalFailed(error.localizedDescription)
        }
    }

    public static func openTerminalAsync(at directory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try openTerminal(at: directory)
        }.value
    }

    public static func directoryTarget(for url: URL) -> URL {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true ? url : url.deletingLastPathComponent()
    }
}
