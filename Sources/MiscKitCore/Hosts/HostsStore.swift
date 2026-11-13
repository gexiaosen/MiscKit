import CryptoKit
import Foundation
import Observation

// MARK: - 路径与错误

public struct HostsPaths: Sendable {
    public let hostsFile: URL
    public let supportDirectory: URL

    public init(hostsFile: URL = HostsPaths.defaultHostsFile,
                supportDirectory: URL = HostsPaths.defaultSupportDirectory) {
        self.hostsFile = hostsFile
        self.supportDirectory = supportDirectory
    }

    public static var defaultHostsFile: URL {
        if let override = ProcessInfo.processInfo.environment["MISCKIT_HOSTS_FILE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "/etc/hosts")
    }

    public static var defaultSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MISCKIT_HOSTS_SUPPORT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AppStoragePaths.subdirectory("Hosts")
    }

    public var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }
    public var backupsDirectory: URL {
        supportDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public var requiresPrivilege: Bool {
        let path = hostsFile.standardizedFileURL.path
        let resolved = hostsFile.resolvingSymlinksInPath().path
        return path == "/etc/hosts" || resolved == "/private/etc/hosts"
    }
}

public enum HostsError: LocalizedError {
    case notLoaded
    case cancelled
    case externalChangeDetected
    case conflictsRequireConfirmation
    case blocked(String)
    case readFailed(String)
    case writeFailed(String)
    case verificationFailed
    case backupFailed(String)
    case stateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return L10n.Hosts.Error.notLoaded
        case .cancelled:
            return L10n.Hosts.Error.cancelled
        case .externalChangeDetected:
            return L10n.Hosts.Error.externalChange
        case .conflictsRequireConfirmation:
            return L10n.Hosts.Error.conflicts
        case .blocked(let reason):
            return reason
        case .readFailed(let reason):
            return L10n.Hosts.Error.readFailed(reason)
        case .writeFailed(let reason):
            return L10n.Hosts.Error.writeFailed(reason)
        case .verificationFailed:
            return L10n.Hosts.Error.verifyMismatch
        case .backupFailed(let reason):
            return L10n.Hosts.Error.backup(reason)
        case .stateFailed(let reason):
            return L10n.Hosts.Error.stateSave(reason)
        }
    }
}

// MARK: - 备份

public struct HostsBackup: Identifiable, Equatable, Sendable {
    public let name: String
    public let url: URL
    public let date: Date
    public let byteCount: Int

    public var id: String { name }

    /// 文件名里带 reason：hosts-日期-时间-reason-随机.bak。
    public var isApplyBackup: Bool { name.contains("-apply-") }
}

struct HostsBackupStore: Sendable {
    let directory: URL
    let limit: Int

    init(directory: URL, limit: Int = 10) {
        self.directory = directory
        self.limit = limit
    }

    func create(data: Data, reason: String, date: Date = Date()) throws -> HostsBackup {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let suffix = UUID().uuidString.prefix(6)
            let name = "hosts-\(formatter.string(from: date))-\(reason)-\(suffix).bak"
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            prune()
            return HostsBackup(name: name, url: url, date: date, byteCount: data.count)
        } catch {
            throw HostsError.backupFailed(error.localizedDescription)
        }
    }

    func list() -> [HostsBackup] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "bak" }
            .compactMap { url -> HostsBackup? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                               .fileSizeKey])
                guard let date = values?.contentModificationDate else { return nil }
                return HostsBackup(name: url.lastPathComponent, url: url, date: date,
                                   byteCount: values?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
    }

    func data(for backup: HostsBackup) throws -> Data {
        do {
            return try Data(contentsOf: backup.url)
        } catch {
            throw HostsError.backupFailed(error.localizedDescription)
        }
    }

    private func prune() {
        let all = list()
        guard all.count > limit else { return }
        for backup in all.dropFirst(limit) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }
}

// MARK: - 原子写

struct HostsWriter: Sendable {
    let fileURL: URL
    let requiresPrivilege: Bool

    init(paths: HostsPaths) {
        self.fileURL = paths.hostsFile
        self.requiresPrivilege = paths.requiresPrivilege
    }

    func write(_ content: Data) async throws {
        if requiresPrivilege {
            try await writePrivileged(content)
        } else {
            try writeLocally(content)
        }
    }

    /// 普通文件路径（测试/调试覆盖）：同目录临时文件 → fsync → rename。
    private func writeLocally(_ content: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".misckit-hosts-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: temp, options: [])
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()

            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            try FileManager.default.setAttributes([.posixPermissions: mode],
                                                  ofItemAtPath: temp.path)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw HostsError.writeFailed(error.localizedDescription)
        }
    }

    /// 需要管理员时：同目录（/etc）临时文件 → sync → rename → 同一授权内刷新 DNS。
    /// 不动用常驻 root helper，每次应用一次授权弹窗。
    /// ⚠ 刷新缓存只是锦上添花：写盘成功后它失败不能把整次应用判成失败
    /// （macOS 26 把 dscacheutil 从 /usr/sbin 挪到 /usr/bin，旧路径写死会让"已写入"报成失败）。
    private func writePrivileged(_ content: Data) async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-hosts-\(UUID().uuidString).txt")
        do {
            try content.write(to: temp, options: [])
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw HostsError.writeFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        let shell = Self.privilegedShellCommand(tempPath: temp.path)
        let script = "do shell script \"\(Self.appleScriptEscape(shell))\" with administrator privileges"

        let result = try await Self.runOsascript(script)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("User canceled") || message.contains("-128") {
                throw HostsError.cancelled
            }
            throw HostsError.writeFailed(
                message.isEmpty ? L10n.Hosts.Error.osascriptExit(result.status) : message
            )
        }
    }

    /// 管理员脚本：写盘三步在 `set -e` 下任何一步失败都算失败；
    /// DNS 刷新则是"存在才跑、失败不算错"——写盘已经成功后它没有资格把整次应用判红。
    static func privilegedShellCommand(tempPath: String) -> String {
        [
            "set -e",
            "/usr/bin/install -m 644 -o root -g wheel \(shellQuoted(tempPath)) '/etc/.hosts.misckit.tmp'",
            "/bin/sync",
            "/bin/mv -f '/etc/.hosts.misckit.tmp' '/etc/hosts'",
            "if [ -x /usr/bin/dscacheutil ]; then /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true; "
                + "elif [ -x /usr/sbin/dscacheutil ]; then /usr/sbin/dscacheutil -flushcache >/dev/null 2>&1 || true; fi",
            "/usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true",
        ].joined(separator: "; ")
    }

    /// 单引号安全引用。路径现在来自 `temporaryDirectory` + UUID（不含引号），
    /// 但这层不该依赖调用方的自觉：Shell 层单引号一旦被路径里的 `'` 提前闭合，
    /// 余下内容就成了新命令，而 `appleScriptEscape` 只转义 `\` 与 `"`，管不到这一层。
    /// 转义规则是 POSIX 的 `'\''`：闭合 → 转义单引号 → 重开。
    static func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runOsascript(_ script: String) async throws
        -> (status: Int32, output: String, error: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                throw HostsError.writeFailed(error.localizedDescription)
            }
            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus,
                    String(decoding: outputData, as: UTF8.self),
                    String(decoding: errorData, as: UTF8.self))
        }.value
    }
}

// MARK: - 持久化状态

struct HostsState: Codable {
    var schemaVersion: Int
    var document: HostsDocument
    var lastKnownHash: String
    var acknowledgedExternalHash: String?
    var importedAt: Date
    var appliedAt: Date?
    var lastApplyBackupName: String?
}

// MARK: - 服务

public struct HostsApplyResult: Sendable {
    public let diff: HostsDiff
    public let backupName: String
}

@MainActor
@Observable
public final class HostsStore {
    public static let shared = HostsStore()

    public let paths: HostsPaths
    public private(set) var document = HostsDocument.empty
    public private(set) var report = HostsReport.empty
    public private(set) var backups: [HostsBackup] = []
    public private(set) var externalChange = false
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var isApplying = false
    public private(set) var loadError: String?
    public private(set) var lastAppliedAt: Date?
    public private(set) var lastApplyBackupName: String?

    private var state: HostsState?
    private var diskText = ""
    private var lastObservedDiskHash: String?
    private var lastBuiltDocument: HostsDocument?
    private let writer: HostsWriter
    private let backupStore: HostsBackupStore

    public init(paths: HostsPaths = HostsPaths()) {
        self.paths = paths
        self.writer = HostsWriter(paths: paths)
        self.backupStore = HostsBackupStore(directory: paths.backupsDirectory)
    }

    public var sections: [HostsSection] { document.orderedSections }

    public var lastApplyBackup: HostsBackup? {
        if let name = lastApplyBackupName,
           let match = backups.first(where: { $0.name == name }), match.isApplyBackup {
            return match
        }
        return backups.first(where: \.isApplyBackup)
    }

    // MARK: 载入

    public func ensureLoaded() {
        guard !hasLoaded, !isLoading else { return }
        load()
    }

    public func load() {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let disk = try readHosts()
            diskText = String(decoding: disk, as: UTF8.self)
            let hash = Self.hash(disk)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stateExists = FileManager.default.fileExists(atPath: paths.stateFile.path)
            if stateExists {
                if let data = try? Data(contentsOf: paths.stateFile),
                   let saved = try? decoder.decode(HostsState.self, from: data),
                   saved.schemaVersion == 1 {
                    state = saved
                    document = saved.document
                    lastAppliedAt = saved.appliedAt
                    lastApplyBackupName = saved.lastApplyBackupName
                    externalChange = hash != saved.lastKnownHash
                        && hash != saved.acknowledgedExternalHash
                } else {
                    // 损坏状态不能静默覆盖：保留一份 state.broken.json 方便排查，再从磁盘重导并提示错误。
                    let broken = paths.supportDirectory.appendingPathComponent("state.broken.json")
                    try? FileManager.default.removeItem(at: broken)
                    try? FileManager.default.copyItem(at: paths.stateFile, to: broken)
                    try importDocument(text: diskText, hash: hash)
                    loadError = L10n.Hosts.Error.corruptState
                }
            } else {
                try importDocument(text: diskText, hash: hash)
            }

            backups = backupStore.list()
            report = HostsReport.build(document: document, currentText: diskText)
            lastObservedDiskHash = hash
            lastBuiltDocument = document
            hasLoaded = true
        } catch {
            loadError = error.localizedDescription
            hasLoaded = true
        }
    }

    /// 低频比对：面板可见时每几秒调一次就够，不做文件系统监听。
    public func refreshExternalState() {
        guard hasLoaded, !isApplying else { return }
        guard let disk = try? readHosts() else { return }
        let hash = Self.hash(disk)
        externalChange = hash != state?.lastKnownHash
            && hash != state?.acknowledgedExternalHash
        guard hash != lastObservedDiskHash || lastBuiltDocument != document else { return }
        let text = String(decoding: disk, as: UTF8.self)
        diskText = text
        lastObservedDiskHash = hash
        lastBuiltDocument = document
        report = HostsReport.build(document: document, currentText: text)
    }

    /// 后台刷新：把读盘、SHA256 与 report 构建放到后台，避免轮询拖慢主线程。
    public func refreshExternalStateAsync() async {
        guard hasLoaded, !isApplying else { return }
        let hostsFile = paths.hostsFile
        let doc = document
        let prevHash = lastObservedDiskHash
        let prevDoc = lastBuiltDocument
        let lastKnown = state?.lastKnownHash
        let ackHash = state?.acknowledgedExternalHash

        let result: (text: String, hash: String, external: Bool, report: HostsReport?)? =
            await Task.detached(priority: .utility) {
                guard let disk = try? Data(contentsOf: hostsFile) else { return nil }
                let hash = Self.hash(disk)
                let external = hash != lastKnown && hash != ackHash
                if hash == prevHash && prevDoc == doc {
                    return ("", hash, external, nil)
                }
                let text = String(decoding: disk, as: UTF8.self)
                let built = HostsReport.build(document: doc, currentText: text)
                return (text, hash, external, built)
            }.value

        guard let result, !isApplying else { return }
        externalChange = result.external
        if let built = result.report {
            diskText = result.text
            lastObservedDiskHash = result.hash
            lastBuiltDocument = doc
            report = built
        }
    }

    public func reimportFromDisk() throws {
        let disk = try readHosts()
        let text = String(decoding: disk, as: UTF8.self)
        let hash = Self.hash(disk)
        try importDocument(text: text, hash: hash)
        diskText = text
        lastObservedDiskHash = hash
        lastBuiltDocument = document
        backups = backupStore.list()
        report = HostsReport.build(document: document, currentText: text)
    }

    /// 外部改动但用户决定继续用工具内版本：记下这次外部 hash，不再反复提示；
    /// 应用时仍会在 diff 里列出将覆盖的内容。
    public func keepToolVersion() {
        guard let disk = try? readHosts() else { return }
        state?.acknowledgedExternalHash = Self.hash(disk)
        persistState()
        externalChange = false
    }

    // MARK: 编辑

    public func setSectionEnabled(_ id: UUID, enabled: Bool) {
        guard let index = document.sections.firstIndex(where: { $0.id == id }) else { return }
        guard document.sections[index].isEnabled != enabled else { return }
        document.sections[index].isEnabled = enabled
        persistAndRebuild()
    }

    /// 「只切这一段」：基座常开 + 指定叠加段开，其余叠加段关。
    /// 返回 false 表示目标段不存在或本来就是这个状态（这时不该白弹一次授权窗）。
    @discardableResult
    public func selectSectionExclusive(_ id: UUID) -> Bool {
        guard hasLoaded, document.sections.contains(where: { $0.id == id }) else { return false }
        let alreadySet = document.sections.allSatisfy { $0.isBase || $0.id == id ? $0.isEnabled : !$0.isEnabled }
        guard !alreadySet else { return false }
        for index in document.sections.indices {
            document.sections[index].isEnabled = document.sections[index].isBase
                || document.sections[index].id == id
        }
        persistAndRebuild()
        return true
    }

    public func toggleLine(sectionID: UUID, lineIndex: Int) {
        guard let index = document.sections.firstIndex(where: { $0.id == sectionID }),
              document.sections[index].lines.indices.contains(lineIndex),
              HostsLineParser.parse(document.sections[index].lines[lineIndex]).isMapping
        else { return }
        if document.sections[index].disabledLines.contains(lineIndex) {
            document.sections[index].disabledLines.remove(lineIndex)
        } else {
            document.sections[index].disabledLines.insert(lineIndex)
        }
        persistAndRebuild()
    }

    // MARK: 段与行的编辑

    /// 给 UI 做实时校验用；`addSection` / `renameSection` 内部走同一份规则，
    /// 不会出现"提示放行、提交被拒"的两套判断。
    public func sectionNameProblem(_ raw: String, ignoring id: UUID? = nil) -> String? {
        HostsDocument.nameProblem(raw, in: document.sections, ignoring: id)
    }

    /// 新建叠加段。名字不合法返回 nil（原因先问 `sectionNameProblem`）。
    public func addSection(named rawName: String) -> UUID? {
        guard hasLoaded else { return nil }
        var copy = document
        guard let id = copy.addSection(named: rawName) else { return nil }
        document = copy
        persistAndRebuild()
        return id
    }

    /// 改名。会连标题行一起改写，否则下次从文件重新导入时长回旧名、状态丢光。
    @discardableResult
    public func renameSection(_ id: UUID, to rawName: String) -> Bool {
        guard hasLoaded else { return false }
        var copy = document
        guard copy.renameSection(id: id, to: rawName) else { return false }
        document = copy
        persistAndRebuild()
        return true
    }

    /// 删段。基座删不掉（返回 false），要停用基座请走勾选 + 二次确认那条路。
    @discardableResult
    public func deleteSection(_ id: UUID) -> Bool {
        guard hasLoaded else { return false }
        var copy = document
        guard copy.removeSection(id: id) else { return false }
        document = copy
        persistAndRebuild()
        return true
    }

    @discardableResult
    public func updateLine(sectionID: UUID, lineIndex: Int, to line: String) -> Bool {
        guard hasLoaded else { return false }
        var copy = document
        guard copy.updateLine(in: sectionID, at: lineIndex, to: line) else { return false }
        document = copy
        persistAndRebuild()
        return true
    }

    @discardableResult
    public func insertLine(_ line: String, sectionID: UUID, at index: Int? = nil) -> Bool {
        guard hasLoaded else { return false }
        var copy = document
        guard copy.insertLine(line, in: sectionID, at: index) else { return false }
        document = copy
        persistAndRebuild()
        return true
    }

    @discardableResult
    public func replaceLines(sectionID: UUID, with lines: [String]) -> Bool {
        guard hasLoaded else { return false }
        var copy = document
        guard copy.replaceLines(in: sectionID, with: lines) else { return false }
        document = copy
        persistAndRebuild()
        return true
    }

    /// 手动备份当前磁盘 hosts（不是工具里尚未应用的编辑内容），和自动备份共用 10 份额度。
    @discardableResult
    public func createBackup() throws -> HostsBackup {
        guard hasLoaded else { throw HostsError.notLoaded }
        guard !isApplying else { throw HostsError.blocked(L10n.Hosts.Error.applying) }
        let disk = try readHosts()
        let backup = try backupStore.create(data: disk, reason: "manual")
        backups = backupStore.list()
        return backup
    }

    @discardableResult
    public func deleteLine(sectionID: UUID, lineIndex: Int) -> Bool {
        guard hasLoaded else { return false }
        var copy = document
        guard copy.deleteLine(in: sectionID, at: lineIndex) else { return false }
        document = copy
        persistAndRebuild()
        return true
    }

    /// 拖拽排序：`targetID` 为落点段；落到基座等同放到叠加段最前。
    public func moveSection(_ id: UUID, before targetID: UUID?) {
        guard let source = document.sections.first(where: { $0.id == id }), !source.isBase else {
            return
        }
        let bases = document.sections.filter(\.isBase)
        var overlays = document.sections.filter { !$0.isBase }
        guard let from = overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = overlays.remove(at: from)

        var destination = overlays.count
        if let targetID,
           let target = document.sections.first(where: { $0.id == targetID }) {
            if target.isBase {
                destination = 0
            } else if let index = overlays.firstIndex(where: { $0.id == targetID }) {
                destination = index
            }
        }
        overlays.insert(item, at: min(max(destination, 0), overlays.count))
        document.sections = bases + overlays
        persistAndRebuild()
    }

    /// 按一格挪动：直接在叠加段数组里换位。
    /// 以前借 `moveSection(_:before:)` 实现，但目标项在被拖项移除后下标会前移，
    /// "插到下一项之前"等于插回原位——下移是个 no-op（拖拽时表现为一路往上跳）。
    public func moveSection(_ id: UUID, offset: Int) {
        guard let source = document.sections.first(where: { $0.id == id }), !source.isBase else {
            return
        }
        let bases = document.sections.filter(\.isBase)
        var overlays = document.sections.filter { !$0.isBase }
        guard let from = overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = overlays.remove(at: from)
        let destination = min(max(from + offset, 0), overlays.count)
        overlays.insert(item, at: destination)
        document.sections = bases + overlays
        persistAndRebuild()
    }

    // MARK: 应用与回滚

    public func apply(acknowledgingConflicts: Bool = false) async throws -> HostsApplyResult {
        guard !isApplying else { throw HostsError.blocked(L10n.Hosts.Error.applying) }
        guard hasLoaded, var state else { throw HostsError.notLoaded }

        isApplying = true
        defer {
            isApplying = false
            backups = backupStore.list()
        }

        let disk = try readHosts()
        let text = String(decoding: disk, as: UTF8.self)
        diskText = text
        let hash = Self.hash(disk)
        externalChange = hash != state.lastKnownHash
            && hash != state.acknowledgedExternalHash
        let current = HostsReport.build(document: document, currentText: text)
        report = current

        if externalChange { throw HostsError.externalChangeDetected }
        if !current.blockingIssues.isEmpty {
            throw HostsError.blocked(L10n.Hosts.Error.blockingIssues(current.blockingIssues.count))
        }
        if !current.conflicts.isEmpty && !acknowledgingConflicts {
            throw HostsError.conflictsRequireConfirmation
        }
        if current.effective.isEmpty {
            throw HostsError.blocked(L10n.Hosts.Error.emptyOutput)
        }

        let rendered = document.rendered()
        let data = Data(rendered.utf8)
        let backup = try backupStore.create(data: disk, reason: "apply")
        try await writer.write(data)

        let readBack = try readHosts()
        guard readBack == data else { throw HostsError.verificationFailed }

        let appliedHash = Self.hash(data)
        state.document = document
        state.lastKnownHash = appliedHash
        state.acknowledgedExternalHash = nil
        state.appliedAt = Date()
        state.lastApplyBackupName = backup.name
        self.state = state
        persistState()

        lastAppliedAt = state.appliedAt
        lastApplyBackupName = backup.name
        diskText = rendered
        lastObservedDiskHash = appliedHash
        lastBuiltDocument = document
        externalChange = false
        report = HostsReport.build(document: document, currentText: rendered)
        return HostsApplyResult(diff: current.diff, backupName: backup.name)
    }

    public func restore(_ backup: HostsBackup) async throws {
        guard !isApplying else { throw HostsError.blocked(L10n.Hosts.Error.applying) }
        guard var state else { throw HostsError.notLoaded }

        isApplying = true
        defer {
            isApplying = false
            backups = backupStore.list()
        }

        let content = try backupStore.data(for: backup)
        let current = try readHosts()
        let safety = try backupStore.create(data: current, reason: "restore")
        try await writer.write(content)

        let readBack = try readHosts()
        guard readBack == content else { throw HostsError.verificationFailed }

        let restoredHash = Self.hash(content)
        let text = String(decoding: content, as: UTF8.self)
        document = Self.normalized(HostsDocument.parse(text))
        state.document = document
        state.lastKnownHash = restoredHash
        state.acknowledgedExternalHash = nil
        state.appliedAt = Date()
        state.lastApplyBackupName = safety.name
        self.state = state
        persistState()

        lastAppliedAt = state.appliedAt
        lastApplyBackupName = safety.name
        diskText = text
        lastObservedDiskHash = restoredHash
        lastBuiltDocument = document
        externalChange = false
        report = HostsReport.build(document: document, currentText: text)
    }

    // MARK: 内部

    private func readHosts() throws -> Data {
        do {
            return try Data(contentsOf: paths.hostsFile)
        } catch {
            throw HostsError.readFailed(error.localizedDescription)
        }
    }

    private func importDocument(text: String, hash: String) throws {
        let parsed = Self.normalized(HostsDocument.parse(text))
        document = parsed
        let imported = HostsState(schemaVersion: 1, document: parsed,
                                  lastKnownHash: hash, acknowledgedExternalHash: nil,
                                  importedAt: Date(), appliedAt: nil,
                                  lastApplyBackupName: nil)
        state = imported
        lastAppliedAt = nil
        lastApplyBackupName = nil
        externalChange = false
        persistState()
    }

    private static func normalized(_ document: HostsDocument) -> HostsDocument {
        guard document.sections.isEmpty else { return document }
        var copy = document
        copy.sections = [HostsSection(name: "共用", isBase: true)]
        return copy
    }

    private func persistAndRebuild() {
        state?.document = document
        persistState()
        lastBuiltDocument = document
        report = HostsReport.build(document: document, currentText: diskText)
    }

    private func persistState() {
        guard let state else { return }
        do {
            try FileManager.default.createDirectory(
                at: paths.supportDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: paths.stateFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: paths.stateFile.path)
        } catch {
            loadError = HostsError.stateFailed(error.localizedDescription).localizedDescription
        }
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
