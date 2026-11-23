import AppKit
import MiscKitCore
import SwiftUI
import UniformTypeIdentifiers

/// OTP 工作区：分组列表 + 剩余时间进度环 + 点一下就复制。
/// 时间用 `TimelineView` 自己走，不额外起计时器；密钥永远只从 `OTPStore` 取。
struct OTPPane: View {
    static let contentHeight: CGFloat = 420

    /// 键盘选中态由 `LauncherView` 持有（↑↓ 要经它路由），这里只画与响应
    let model: OTPWorkspaceModel
    @State private var store = OTPStore.shared
    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared
    @Environment(\.appLanguage) private var appLanguage
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var failure: String?
    @State private var showImport = false
    @State private var importText = ""
    @State private var importResult: String?
    @State private var importFailures: [OTPFailure] = []
    @State private var importBatches: [Int: OTPMigration.BatchProgress] = [:]
    @State private var isImporting = false
    @State private var pendingDelete: OTPAccount?
    @State private var missingSecretAccount: OTPAccount?
    @State private var noteTarget: OTPAccount?
    @State private var noteDraft = ""
    @State private var manualIssuer = ""
    @State private var manualAccount = ""
    @State private var manualSecret = ""
    /// 首次 onAppear 紧跟在第一次渲染之后，而那一轮已经把钥匙串敲过了；
    /// 只有"离开再回来"才值得给被拒的授权一次重试，否则一次打开会弹两轮框。
    @State private var hasAppeared = false
    @State private var manualDigits = 6

    /// 拖拽只携带账户 id；搜索态下可见列表是过滤后的，落点下标对不上全量顺序，
    /// 所以搜索时禁止重排（与上移/下移同一道闸，只在这一个地方判）。
    private var canReorder: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: Layout.Spacing.s) {
            header
            if let notice = store.healthNotice { noticeBar(notice, warning: true) }
            // 导入/删除失败必须看得见，否则用户只会以为"点了没反应"
            if let error = store.lastError { noticeBar(error, warning: false) }
            if let failure { noticeBar(failure, warning: false) }
            list
            footer
        }
        .padding(.horizontal, Layout.Spacing.l)
        .padding(.vertical, Layout.Spacing.s)
        .frame(height: Self.contentHeight, alignment: .top)
        .sheet(isPresented: $showImport) { importSheet }
        // 搜索词决定可见列表，也就决定 ↑↓ 该落在哪：同步给模型，界面是唯一来源
        .onChange(of: query) { _, value in model.query = value }
        .onChange(of: model.copyRequest) { _, _ in
            if let account = model.selected(in: store) { copy(account) }
        }
        .onChange(of: model.noteRequest) { _, _ in
            if let account = model.selected(in: store) { requestNote(account) }
        }
        // 验收用：直接停在导入弹窗上，检查"弹窗会不会把面板一起带走"；
        // 过滤器用来把排在末尾的 seed 账户拉到可见区
        .onAppear {
            model.query = query
            if hasAppeared { store.refreshSecrets() }
            hasAppeared = true
            #if DEBUG
            if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OTP_SHEET"] == "1" {
                showImport = true
            }
            if let preset = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OTP_FILTER"],
               !preset.isEmpty {
                query = preset
            }
            #endif
        }
        .alert(deleteTitle, isPresented: deleteBinding) {
            Button(L10n.Common.cancel, role: .cancel) { pendingDelete = nil }
            Button(L10n.Common.delete, role: .destructive) {
                if let account = pendingDelete { remove(account) }
                pendingDelete = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            L10n.OTP.secretMissingRemoveTitle(missingSecretAccount?.displayName ?? ""),
            isPresented: missingSecretBinding
        ) {
            Button(L10n.Common.cancel, role: .cancel) { missingSecretAccount = nil }
            Button(L10n.Common.remove, role: .destructive) {
                if let account = missingSecretAccount {
                    store.removeFromListIfSecretMissing(account)
                }
                missingSecretAccount = nil
            }
        }
        .alert(L10n.OTP.Note.title, isPresented: noteBinding) {
            TextField(L10n.OTP.Note.placeholder, text: $noteDraft)
            Button(L10n.Common.save) {
                if let account = noteTarget { store.updateNote(noteDraft, for: account.id) }
                noteTarget = nil
            }
            Button(L10n.Common.clear, role: .destructive) {
                if let account = noteTarget { store.updateNote(nil, for: account.id) }
                noteTarget = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { noteTarget = nil }
        } message: {
            Text(L10n.OTP.Note.message)
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var missingSecretBinding: Binding<Bool> {
        Binding(get: { missingSecretAccount != nil }, set: { if !$0 { missingSecretAccount = nil } })
    }

    private var noteBinding: Binding<Bool> {
        Binding(get: { noteTarget != nil }, set: { if !$0 { noteTarget = nil } })
    }

    /// 删除确认弹窗标题。
    private var deleteTitle: String {
        guard let account = pendingDelete else { return L10n.OTP.deleteTitleDefault }
        return L10n.OTP.deleteTitleNamed(account.displayName)
    }

    /// 账户名已在标题展示，正文说明具体操作影响范围。
    private var deleteMessage: String {
        guard pendingDelete != nil else { return "" }
        if store.synchronizesToCloud {
            return L10n.OTP.deleteMessageSync
        }
        return L10n.OTP.deleteMessageLocal
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: Layout.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Tools.OTP.titleRow)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textBody)
                    .contentTransition(.numericText())
                    .animation(rollAnimation, value: subtitle)
            }
            Spacer(minLength: Layout.Spacing.m)
            Button(L10n.OTP.Import.button) { showImport = true }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .frame(height: 34)
    }

    private var subtitle: String {
        let base = store.accounts.isEmpty ? L10n.OTP.emptyAccounts : L10n.OTP.Subtitle.count(store.accounts.count)
        guard store.driftOffset != 0 else { return base }
        let sign = store.driftOffset > 0 ? "+" : "−"
        return L10n.OTP.Subtitle.drift(base, sign, Int(abs(store.driftOffset)))
    }

    private func noticeBar(_ text: String, warning: Bool) -> some View {
        HStack(spacing: Layout.Spacing.s) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(warning ? Theme.warningText : Theme.errorText)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.Spacing.m)
        .frame(height: 40)
        .background(warning ? Theme.warningFill : Theme.errorFill,
                    in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                         style: .continuous))
    }

    // MARK: 列表

    private var visible: [OTPAccount] { store.visibleAccounts(matching: query) }

    private var list: some View {
        // 配合 ScrollViewReader，让键盘快捷键选中的项自动保持在可视范围内。
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.Metric.rowSpacing) {
                if store.accounts.isEmpty {
                    emptyState
                } else if visible.isEmpty {
                    Text(L10n.OTP.noMatch)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textBody)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Layout.SpacingValue.rowPadding)
                        .frame(height: Layout.Metric.rowHeightCompact)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        ForEach(groups, id: \.issuer) { bucket in
                            groupHeader(bucket.issuer)
                            ForEach(Array(bucket.accounts.enumerated()), id: \.element.id) { _, account in
                                OTPAccountRow(account: account, store: store,
                                              now: timeline.date,
                                              index: flatIndex(of: account),
                                              isSelected: model.selectedID == account.id,
                                              isCopied: copiedID == account.id,
                                              canReorder: canReorder,
                                              requestNote: { requestNote($0) },
                                              requestDelete: { pendingDelete = $0 }) {
                                    // 鼠标点一下也要把选中对齐，否则 ↑↓ 会从看不见的地方接着走
                                    model.select(account)
                                    copy(account)
                                }
                                .id(account.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Layout.Metric.listInset)
        }
        .frame(maxHeight: .infinity)
        .scrollIndicators(.hidden)
        .onChange(of: model.selectedID) { _, selected in
            guard let selected else { return }
            proxy.scrollTo(selected, anchor: .center)
        }
        }
    }

    /// 搜索时不再分组，直接一列；没搜索才按 issuer 分组。
    private var groups: [(issuer: String, accounts: [OTPAccount])] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return [(issuer: "", accounts: visible)]
        }
        return store.grouped
    }

    private func flatIndex(of account: OTPAccount) -> Int? {
        guard let position = visible.firstIndex(where: { $0.id == account.id }) else { return nil }
        return position < 10 ? position : nil
    }

    private func groupHeader(_ issuer: String) -> some View {
        issuer.isEmpty ? AnyView(EmptyView()) : AnyView(
            Text(issuer)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textBody)
                .padding(.horizontal, Layout.SpacingValue.rowPadding)
                .padding(.top, Layout.Spacing.xs)
                // TimelineView 会把子视图按自身默认对齐方式摆放；显式撑满再左对齐，
                // 避免分组标题被居中到列表中线。
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.s) {
            Text(L10n.OTP.emptyAccounts)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(Layout.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.previewFill,
                    in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                         style: .continuous))
    }

    // MARK: 底部：搜索 + 校准

    private var footer: some View {
        HStack(spacing: Layout.Spacing.m) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.decorationOnly)
                TextField(L10n.OTP.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, Layout.Spacing.s)
            .frame(height: 24)
            .background(Theme.chipFill, in: Capsule())
            .frame(maxWidth: 260)

            Spacer(minLength: Layout.Spacing.s)
            driftControl
        }
        .frame(height: 28)
    }

    private var rollAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.numericRoll, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }

    private var driftControl: some View {
        HStack(spacing: 6) {
            Text(L10n.OTP.calibrate)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Stepper(value: $store.driftOffset, in: -120...120, step: 5) {
                Text("\(Int(store.driftOffset))s")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(store.driftOffset == 0 ? Theme.decorationOnly : Theme.accent)
                    .frame(width: 42, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(rollAnimation, value: store.driftOffset)
            }
            .controlSize(.mini)
        }
    }

    // MARK: 动作

    /// 删除失败要看得见：钥匙串拒绝时条目留在列表里，用户必须知道为什么没删掉。
    private func remove(_ account: OTPAccount) {
        switch store.deleteWithStatus(account) {
        case .deleted:
            failure = nil
            if copiedID == account.id { copiedID = nil }
        case .secretMissing:
            failure = nil
            missingSecretAccount = account
        case .failed:
            failure = store.lastError ?? L10n.OTP.deleteFailed
        }
    }

    private func requestNote(_ account: OTPAccount) {
        noteDraft = account.note ?? ""
        noteTarget = account
    }

    private func copy(_ account: OTPAccount) {
        guard let code = store.code(for: account) else {
            failure = L10n.Actions.otpSecretMissing
            return
        }
        if ClipboardGuard.shared.copySecret(code) {
            copiedID = account.id
            failure = nil
            if account.kind == .hotp { store.advanceCounter(account) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if copiedID == account.id { copiedID = nil }
            }
        } else {
            failure = L10n.Actions.clipboardFailed
        }
    }

    // MARK: 导入

    /// 只把没齐的批次拿出来；已经齐了的批次不再占提示位。
    private var incompleteBatches: [OTPMigration.BatchProgress] {
        importBatches.values
            .filter { !$0.isComplete }
            .sorted { $0.batchID < $1.batchID }
    }

    private var batchNotice: String? {
        let missing = incompleteBatches
        guard !missing.isEmpty else { return nil }
        if missing.count == 1 {
            let batch = missing[0]
            let have = batch.indexes.count
            return L10n.OTP.Import.batchOne(batch.size, have, batch.size - have)
        }
        return L10n.OTP.Import.batchMultiple(missing.count)
    }

    private var wantsNextQR: Bool { !incompleteBatches.isEmpty }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.m) {
            Text(L10n.OTP.Import.title)
                .font(.system(size: 13, weight: .semibold))
            Text(L10n.OTP.Import.description)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $importText)
                .font(.system(size: 11))
                .frame(height: 120)
                .overlay(alignment: .topLeading) {
                    // 空 TextEditor 里什么都没有，用户会以为没粘上：给个占位提示
                    if importText.isEmpty {
                        Text(L10n.OTP.Import.placeholder)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.decorationOnly)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                          style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5))
            if let importResult {
                Text(importResult)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let batchNotice {
                HStack(spacing: 5) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                    Text(batchNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !importFailures.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(importFailures.prefix(3).enumerated()), id: \.offset) { _, failure in
                        Text("· \(failure.displayText)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.errorText)
                    }
                    if importFailures.count > 3 {
                        Text(L10n.OTP.Import.moreFailures(importFailures.count - 3))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(wantsNextQR ? L10n.OTP.Import.pickNextQR : L10n.OTP.Import.pickImage) { pickImage() }
                    .disabled(isImporting)
                Button(L10n.OTP.Import.pasteImage) {
                    Task { @MainActor in await pasteImage() }
                }
                .disabled(isImporting)
                Spacer()
                Button(L10n.Common.cancel) { closeImport() }
                Button(L10n.OTP.Import.action) { submitText() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImporting || importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            manualSection
        }
        .padding(Layout.Spacing.l)
        .frame(width: 460)
        // 从聊天/文件夹直接把二维码图片拖进来，不用先落盘再点选图
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !isImporting else { return false }
            Task { @MainActor in await importImages(urls) }
            return true
        }
    }

    // MARK: 手工录入

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.s) {
            Text(L10n.OTP.Manual.heading)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: Layout.Spacing.s) {
                TextField(L10n.OTP.Manual.issuer, text: $manualIssuer)
                TextField(L10n.OTP.Manual.account, text: $manualAccount)
            }
            .font(.system(size: 11))
            .textFieldStyle(.roundedBorder)
            HStack(spacing: Layout.Spacing.s) {
                SecureField(L10n.OTP.Manual.secret, text: $manualSecret)
                    .font(.system(size: 11).monospaced())
                    .textFieldStyle(.roundedBorder)
                Picker(L10n.OTP.Manual.digitsTitle, selection: $manualDigits) {
                    Text(L10n.OTP.Manual.digitsValue(6)).tag(6)
                    Text(L10n.OTP.Manual.digitsValue(8)).tag(8)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .id("picker-otp-digits-\(appLanguage.resolved.rawValue)")
                Button(L10n.Common.add) { submitManual() }
            }
            Text(store.synchronizesToCloud
                 ? L10n.OTP.Manual.noteSync
                 : L10n.OTP.Manual.noteLocal)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submitManual() {
        let outcome = OTPManualEntry.entry(issuer: manualIssuer, account: manualAccount,
                                           secret: manualSecret, digits: manualDigits)
        switch outcome {
        case .success(let entry):
            let label = entry.account.displayName
            guard store.add(entry) else {
                importFailures = [OTPFailure(label: label,
                                             reason: store.lastError ?? L10n.OTP.addFailed)]
                importResult = nil
                return
            }
            manualIssuer = ""
            manualAccount = ""
            manualSecret = ""
            importFailures = []
            importResult = L10n.OTP.addedNamed(label)
        case .failure(let error):
            // label 只取名字，绝不含密钥
            let name = manualIssuer.trimmingCharacters(in: .whitespaces).isEmpty
                ? manualAccount.trimmingCharacters(in: .whitespaces)
                : manualIssuer.trimmingCharacters(in: .whitespaces)
            importFailures = [OTPFailure(label: name.isEmpty ? L10n.OTP.Manual.labelFallback : name,
                                         reason: error.errorDescription ?? L10n.OTP.Manual.unparseable)]
            importResult = nil
        }
    }

    private func closeImport() {
        showImport = false
        importText = ""
        importResult = nil
        importFailures = []
        importBatches = [:]
        manualIssuer = ""
        manualAccount = ""
        manualSecret = ""
        manualDigits = 6
    }

    private func submitText() {
        let parsed = OtpAuthURI.parseBatchDetailed(importText)
        let result = store.importEntries(parsed.entries)
        report(added: result.added,
               failures: parsed.failures + result.failures,
               unread: [],
               batches: parsed.batches)
        if result.added > 0 { importText = "" }
    }

    private func pickImage() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.level = PanelHost.pickerLevel
        // 同上：先激活 App，否则选择器首帧会点不动。
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { @MainActor in await importImages(urls) }
    }

    /// 拖进来的和选进来的都走这一条：逐张解，解不动的点名说清，别混进"失败原因"里。
    private func importImages(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        var added = 0
        var failures: [OTPFailure] = []
        var unreadable: [String] = []
        var batches: [OTPMigration.BatchProgress] = []
        for url in urls {
            switch await OTPQRReader.readAsync(url: url) {
            case .success(let parsed):
                let result = store.importEntries(parsed.entries)
                added += result.added
                failures.append(contentsOf: result.failures + parsed.failures)
                batches.append(contentsOf: parsed.batches)
            case .failure(let error):
                unreadable.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        report(added: added, failures: failures, unread: unreadable, batches: batches)
    }

    private func pasteImage() async {
        guard !isImporting else { return }
        let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]
        guard let image = images?.first else {
            report(added: 0, failures: [],
                   unread: [L10n.OTP.Import.noClipboardImage],
                   batches: [])
            return
        }
        isImporting = true
        defer { isImporting = false }

        switch await OTPQRReader.readAsync(image: image) {
        case .success(let parsed):
            let result = store.importEntries(parsed.entries)
            report(added: result.added, failures: result.failures + parsed.failures,
                   unread: [], batches: parsed.batches)
        case .failure(let error):
            report(added: 0, failures: [], unread: [error.localizedDescription], batches: [])
        }
    }

    /// 成功数 + 读不出的文件一次说全。`summary(added:)` 会读 `importFailures`，所以先赋值再调。
    private func report(added: Int, failures: [OTPFailure], unread: [String],
                        batches: [OTPMigration.BatchProgress]) {
        importFailures = failures
        mergeBatches(batches)
        var parts: [String] = []
        if added > 0 { parts.append(summary(added: added)) }
        parts.append(contentsOf: unread)
        if parts.isEmpty {
            parts.append(failures.isEmpty ? L10n.OTP.Import.noneAdded : L10n.OTP.Import.allFailedCount(failures.count))
        }
        importResult = parts.joined(separator: " ")
    }

    /// 同一组导出的多张图会分别解析；按 batchID 合并，才知道是"缺一张"还是"其实齐了"。
    private func mergeBatches(_ reports: [OTPMigration.BatchProgress]) {
        for report in reports {
            if var existing = importBatches[report.batchID] {
                existing.size = max(existing.size, report.size)
                existing.indexes.formUnion(report.indexes)
                importBatches[report.batchID] = existing
            } else {
                importBatches[report.batchID] = report
            }
        }
    }

    /// 成功数一句话，失败另起行写原因。先赋 `importFailures` 再调这里。
    private func summary(added: Int) -> String {
        if added > 0 { return L10n.OTP.Import.addedCount(added) }
        return importFailures.isEmpty ? L10n.OTP.Import.noneAdded : L10n.OTP.Import.allFailedCount(importFailures.count)
    }
}

/// 单行：左键复制，右侧进度环表示本周期剩余时间；右键菜单给备注、上下移和删除。
private struct OTPAccountRow: View {
    let account: OTPAccount
    let store: OTPStore
    let now: Date
    let index: Int?
    let isSelected: Bool
    let isCopied: Bool
    let canReorder: Bool
    let requestNote: (OTPAccount) -> Void
    let requestDelete: (OTPAccount) -> Void
    let action: () -> Void

    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared
    @Environment(\.appLanguage) private var appLanguage

    /// 验证码每 30 秒整体换一次：用数字滚动交代"新码到位"，倒计时秒数不做（每秒 16 行太吵）
    private var rollAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.numericRoll, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }


    var body: some View {
        let _ = appLanguage
        let code = store.code(for: account, date: now)
        let remaining = store.secondsRemaining(for: account, date: now)
        Button(action: action) {
            HStack(spacing: Layout.Spacing.m) {
                ResultTile(symbol: account.algorithm.rawValue == "SHA1" ? "number.square" : "shield.lefthalf.filled",
                           index: index ?? -1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.Spacing.s)
                Text(code ?? "—")
                    .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(code == nil ? Theme.decorationOnly : Theme.tileText)
                    .contentTransition(.numericText())
                    .animation(rollAnimation, value: code)
                ring(remaining)
            }
            .padding(.horizontal, Layout.SpacingValue.rowPadding)
            .frame(height: Layout.Metric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isCopied ? Theme.successFill : .clear,
                    in: RoundedRectangle(cornerRadius: Layout.Metric.rowCornerRadius,
                                         style: .continuous))
        // 键盘选中 = 和其余四张列表同一层玻璃 pill；刚复制过的那条另有绿底
        .modifier(SelectedRowGlass(selected: isSelected))
        // ⌘1..9 直接复制对应行；第 10 行往后不再挂快捷键，避免与 ⌘0 撞车
        .modifier(RowShortcutModifier(index: index ?? 99))
        .dropDestination(for: String.self) { items, _ in
            guard canReorder, let raw = items.first,
                  let dragged = UUID(uuidString: raw), dragged != account.id else { return false }
            store.move(dragged, before: account.id)
            return true
        }
        .contextMenu {
            Button(L10n.OTP.copyCode) { action() }
            Button(L10n.OTP.Note.action) { requestNote(account) }
            Divider()
            Button(L10n.Common.moveUp) { shift(by: -1) }.disabled(canMoveUp == false)
            Button(L10n.Common.moveDown) { shift(by: 1) }.disabled(canMoveDown == false)
            Divider()
            Button(L10n.OTP.deleteAccount, role: .destructive) { requestDelete(account) }
        }
    }

    /// 拖拽落点与上下移都只认全量顺序；搜索态下可见列表是过滤后的，一律禁用。
    private var position: Int? {
        store.accounts.firstIndex(where: { $0.id == account.id })
    }

    private var canMoveUp: Bool { canReorder && (position ?? 0) > 0 }

    private var canMoveDown: Bool {
        guard canReorder, let position else { return false }
        return position < store.accounts.count - 1
    }

    private func shift(by offset: Int) {
        guard let position, canReorder else { return }
        let neighbour = position + offset
        guard store.accounts.indices.contains(neighbour) else { return }
        if offset < 0 {
            store.move(account.id, before: store.accounts[neighbour].id)
        } else {
            store.move(store.accounts[neighbour].id, before: account.id)
        }
    }

    private var detail: String {
        if account.kind == .hotp { return noteAppended(L10n.OTP.counterDetail(Int(clamping: account.counter))) }
        if isCopied { return L10n.OTP.copiedDetail }
        let period = L10n.OTP.periodSeconds(account.period)
        let base = account.digits == 8 ? L10n.OTP.digits8(period) : period
        return noteAppended(base)
    }

    private func noteAppended(_ base: String) -> String {
        guard let note = account.note, !note.isEmpty else { return base }
        return "\(base) · \(note)"
    }

    @ViewBuilder
    private func ring(_ remaining: Int?) -> some View {
        if let remaining, account.kind == .totp {
            ZStack {
                Circle()
                    .stroke(Theme.chipFill, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(1, account.period)))
                    .stroke(remaining <= 5 ? Theme.errorText : Theme.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        }
    }
}
