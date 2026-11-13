import MiscKitCore
import SwiftUI

/// 面板内的 hosts 工作区：段开关、逐行禁用、生效预览、变更 diff、应用与回滚。
struct HostsPane: View {
    @Bindable var store: HostsStore
    /// 选中哪一段 / 哪一行 / 看哪个页签。放在外面是因为 ↑↓ 只能由 LauncherView 的
    /// move() 路由，见 `HostsPaneModel` 顶部注释。
    @Bindable var model: HostsPaneModel

    @State private var search = ""
    @State private var pendingBaseOff: HostsSection?
    @State private var pendingRestore: HostsBackup?
    @State private var pendingReimport = false
    @State private var showApplyConfirm = false
    @State private var showConflictConfirm = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var bulkEditSection: HostsSection?
    @State private var bulkText = ""
    @State private var bulkFeedback: String?
    /// 拖拽排序：被拖拽的段浮起跟随手势，拖拽期间仅做视图位移，释放后提交顺序。
    @State private var draggingSectionID: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragOriginIndex: Int?
    @State private var dragTargetIndex: Int?
    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared
    @Environment(\.appLanguage) private var appLanguage

    static let contentHeight: CGFloat = 500

    // MARK: 编辑

    /// 段与行的编辑目标。用枚举而不是三个独立 bool，避免出现
    /// "同时开着改名框又开着删除框"这种两个 alert 抢一个 isPresented 的状态。
    @State private var sectionEdit: SectionEdit?
    @State private var sectionNameDraft = ""
    @State private var pendingSectionDelete: HostsSection?
    @State private var lineEdit: LineEdit?
    @State private var lineDraft = ""
    @State private var editFeedback: String?

    enum SectionEdit: Equatable {
        case create
        case rename(id: UUID, current: String)
    }

    enum LineEdit: Equatable {
        case edit(sectionID: UUID, index: Int)
        case insert(sectionID: UUID, at: Int?)   // nil = 加到段尾
    }

    private var selectedSection: HostsSection? {
        if let id = model.selectedSectionID,
           let match = store.sections.first(where: { $0.id == id }) {
            return match
        }
        return store.sections.first
    }

    private var filteredEntries: [HostsMapping] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return store.report.effective }
        return store.report.effective.filter {
            $0.domain.lowercased().contains(term)
                || $0.ip.lowercased().contains(term)
                || $0.sectionName.lowercased().contains(term)
        }
    }

    private var canApply: Bool {
        !store.isApplying
            && !store.externalChange
            && store.report.blockingIssues.isEmpty
            && !store.report.effective.isEmpty
    }

    var body: some View {
        let _ = appLanguage
        Group {
            if !store.hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.document.sections.isEmpty, let error = store.loadError {
                errorState(error)
            } else {
                loaded
            }
        }
        .frame(height: Self.contentHeight)
        .onAppear {
            store.ensureLoaded()
            if model.selectedSectionID == nil {
                model.selectedSectionID = store.sections.first?.id
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await store.refreshExternalStateAsync()
            }
        }
        .alert(L10n.Hosts.UI.baseOffTitle, isPresented: baseOffBinding) {
            Button(L10n.Common.cancel, role: .cancel) { pendingBaseOff = nil }
            Button(L10n.Hosts.UI.baseOffConfirm, role: .destructive) {
                if let section = pendingBaseOff {
                    store.setSectionEnabled(section.id, enabled: false)
                }
                pendingBaseOff = nil
            }
        } message: {
            Text(baseOffMessage)
        }
        .alert(L10n.Hosts.UI.reimportTitle(targetName), isPresented: $pendingReimport) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Hosts.UI.reimportConfirm) {
                do { try store.reimportFromDisk() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text(L10n.Hosts.UI.reimportMessage)
        }
        .alert(L10n.Hosts.UI.applyTitle, isPresented: $showApplyConfirm) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Common.apply) { performApply(acknowledgingConflicts: false) }
        } message: {
            Text(L10n.Hosts.UI.applySummaryNotice(store.report.diff.summary, applyNotice))
        }
        .alert(L10n.Hosts.UI.conflictTitle, isPresented: $showConflictConfirm) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Hosts.UI.conflictConfirm) { performApply(acknowledgingConflicts: true) }
        } message: {
            Text(conflictAlertMessage)
        }
        .alert(L10n.Hosts.UI.restoreTitle, isPresented: restoreBinding) {
            Button(L10n.Common.cancel, role: .cancel) { pendingRestore = nil }
            Button(L10n.Hosts.UI.restoreConfirm) {
                if let backup = pendingRestore { performRestore(backup) }
                pendingRestore = nil
            }
        } message: {
            Text(L10n.Hosts.UI.restoreMessage(backupDateText(pendingRestore?.date), targetName))
        }
        .alert(sectionEditTitle, isPresented: sectionEditBinding) {
            TextField(L10n.Hosts.UI.sectionNamePlaceholder, text: $sectionNameDraft)
            Button(L10n.Common.cancel, role: .cancel) { sectionEdit = nil; editFeedback = nil }
            Button(sectionEditSubmitLabel) { submitSectionEdit() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(editFeedback ?? sectionEditHint)
        }
        .alert(L10n.Hosts.UI.deleteSectionTitle, isPresented: sectionDeleteBinding) {
            Button(L10n.Common.cancel, role: .cancel) { pendingSectionDelete = nil }
            Button(L10n.Common.delete, role: .destructive) {
                if let section = pendingSectionDelete { store.deleteSection(section.id) }
                pendingSectionDelete = nil
            }
        } message: {
            Text(L10n.Hosts.UI.deleteSectionMessage(
                pendingSectionDelete?.name ?? "",
                pendingSectionDelete?.mappingLineCount ?? 0))
        }
        .alert(lineEditTitle, isPresented: lineEditBinding) {
            TextField(L10n.Hosts.UI.linePlaceholder, text: $lineDraft)
            Button(L10n.Common.cancel, role: .cancel) { lineEdit = nil; editFeedback = nil }
            Button(L10n.Common.save) { submitLineEdit() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(editFeedback ?? L10n.Hosts.UI.lineHint)
        }
        // 键盘路由过来的两个请求：LauncherView 只负责把键交进来，弹窗归本视图
        .onChange(of: model.requestLineEditor) { _, request in
            guard let request else { return }
            model.requestLineEditor = nil
            lineDraft = request.line
            editFeedback = nil
            lineEdit = .edit(sectionID: request.sectionID, index: request.index)
        }
        .onChange(of: model.requestBaseOff) { _, section in
            guard let section else { return }
            model.requestBaseOff = nil
            pendingBaseOff = section
        }
        .sheet(item: $bulkEditSection) { section in
            bulkEditor(section)
        }
        // → 展开/编辑，← 从段内容页退回。这两个键位没有别的归属，所以绑在 pane 里不冲突；
        // ↑↓ / ↵ / ⌘↵ 都走 LauncherView 已有的单一路由，不能在这里再绑一遍。
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                Button("") { _ = model.activate(store: store) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityHidden(true)
                Button("") { _ = model.collapse() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .accessibilityHidden(true)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .alert(L10n.Common.actionFailed, isPresented: errorBinding) {
            Button(L10n.Common.ok, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .symbolEffect(.drawOn, options: .nonRepeating)
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.successText)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Theme.successFill, in: Capsule())
                .padding(.bottom, 38)
                .transition(.opacity)
            }
        }
    }

    // MARK: 主体

    private var loaded: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.externalChange { externalBanner }
            HStack(alignment: .top, spacing: 0) {
                sectionList
                    .frame(width: 292)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 0.5)
                detail
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        .padding(.horizontal, Layout.Spacing.l)
        .padding(.top, Layout.Spacing.xs)
        .padding(.bottom, Layout.Spacing.s)
    }

    private var header: some View {
        HStack(spacing: Layout.Spacing.s) {
            Circle()
                .fill(store.externalChange ? Theme.warningText : Theme.successText)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
            }
            Spacer(minLength: Layout.Spacing.m)
            backupsMenu
            Button {
                sectionNameDraft = ""
                editFeedback = nil
                sectionEdit = .create
            } label: {
                Label(L10n.Hosts.UI.newSection, systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
            .disabled(store.isApplying || store.externalChange)
            .accessibilityLabel(L10n.Hosts.UI.newOverlayA11y)
            Button {
                pendingReimport = true
            } label: {
                Label(L10n.Hosts.UI.reload, systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
            .disabled(store.isApplying)
        }
        .frame(height: 32)
    }

    private var statusTitle: String {
        if store.isApplying { return L10n.Hosts.UI.statusApplying(targetName) }
        if store.externalChange { return L10n.Hosts.UI.statusExternal }
        return L10n.Hosts.UI.statusSynced(targetName)
    }

    /// 文案里的目标路径跟着 `HostsPaths` 走，别把 /etc/hosts 写死。
    private var targetName: String { store.paths.hostsFile.path }

    private var applyNotice: String {
        store.paths.requiresPrivilege
            ? L10n.Hosts.UI.applyNoticePrivileged
            : L10n.Hosts.UI.applyNoticeDirect
    }

    private var statusDetail: String {
        let enabled = store.report.enabledSectionCount
        let total = store.sections.count
        let count = store.report.effective.count
        if store.externalChange { return L10n.Hosts.UI.statusDetailExternal(targetName) }
        let base = L10n.Hosts.UI.statusDetailCount(enabled, total, count)
        if let applied = store.lastAppliedAt {
            return L10n.Hosts.UI.statusDetailLastApplied(base, backupDateText(applied))
        }
        return base
    }

    private var externalBanner: some View {
        HStack(spacing: Layout.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warningText)
            Text(L10n.Hosts.UI.externalBanner(targetName))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
            Spacer(minLength: Layout.Spacing.s)
            Button(L10n.Hosts.UI.reimportConfirm) { pendingReimport = true }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
            Button(L10n.Hosts.UI.keepToolVersion) { store.keepToolVersion() }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, Layout.Spacing.m)
        .frame(height: 34)
        .background(Theme.warningText.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                         style: .continuous))
    }

    // MARK: 段列表

    private var sectionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Hosts.UI.sectionsHeader)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
                Text(L10n.Hosts.UI.baseOverlayHeader)
                    .font(Type.micro)
                    .foregroundStyle(Theme.textBody)
            }
            .padding(.horizontal, Layout.Spacing.s)
            .frame(height: 22)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Layout.Metric.rowSpacing) {
                        ForEach(Array(store.sections.enumerated()), id: \.element.id) { index, section in
                            sectionRow(section, index: index)
                                .id(section.id)
                        }
                    }
                    .padding(.horizontal, Layout.Spacing.xs)
                    .padding(.vertical, Layout.Spacing.xs)
                }
                .scrollIndicators(.hidden)
                // 段多了或行多了都会把选中项顶出可视区，↑↓ 之后必须滚进来
                .onChange(of: model.selectedSectionID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }

            Text(L10n.Hosts.UI.dragHint)
                .font(Type.micro)
                .foregroundStyle(Theme.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.Spacing.s)
                .frame(height: 20)
        }
    }

    private func sectionRow(_ section: HostsSection, index: Int) -> some View {
        let isSelected = selectedSection?.id == section.id
        let errors = store.report.issues.filter {
            $0.sectionID == section.id && $0.severity == .error
        }.count
        let conflicts = store.report.conflicts.filter {
            $0.entries.contains { $0.sectionID == section.id }
        }.count

        return HStack(spacing: Layout.Spacing.s) {
            if section.isBase {
                Image(systemName: "lock.fill")
                    .font(Type.micro)
                    .foregroundStyle(Theme.decorationOnly)
                    .frame(width: 14)
            } else if store.isApplying || store.externalChange {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.decorationOnly.opacity(0.4))
                    .frame(width: 14)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.decorationOnly)
                    .frame(width: 14)
            }

            Toggle("", isOn: Binding(
                get: {
                    store.document.sections.first { $0.id == section.id }?.isEnabled
                        ?? section.isEnabled
                },
                set: { enabled in
                    if section.isBase && !enabled {
                        pendingBaseOff = section
                    } else {
                        store.setSectionEnabled(section.id, enabled: enabled)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button {
                model.selectedSectionID = section.id
                model.tab = .content
            } label: {
                HStack(spacing: Layout.Spacing.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(section.isEnabled ? Theme.tileText : Theme.decorationOnly)
                            .lineLimit(1)
                        Text(subtitle(for: section))
                            .font(Type.micro.monospacedDigit())
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if conflicts > 0 {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warningText)
                    .accessibilityLabel(L10n.Hosts.UI.conflictsA11y(conflicts))
            }
            if errors > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.errorText)
                    .accessibilityLabel(L10n.Hosts.UI.errorsA11y(errors))
            }
        }
        .padding(.horizontal, Layout.Spacing.s)
        .frame(height: 44)
        .modifier(SelectedRowGlass(selected: isSelected,
                                   cornerRadius: Layout.Metric.innerCornerRadius))
        .contextMenu {
            Button(section.isEnabled ? L10n.Hosts.UI.disableSection : L10n.Hosts.UI.enableSection) {
                if section.isBase && section.isEnabled {
                    pendingBaseOff = section
                } else {
                    store.setSectionEnabled(section.id, enabled: !section.isEnabled)
                }
            }
            if !section.isBase {
                Divider()
                Button(L10n.Common.moveUp) {
                    withAnimation(reorderAnimation) { store.moveSection(section.id, offset: -1) }
                }
                .disabled(index <= 1 || store.isApplying || store.externalChange)
                Button(L10n.Common.moveDown) {
                    withAnimation(reorderAnimation) { store.moveSection(section.id, offset: 1) }
                }
                .disabled(index >= store.sections.count - 1 || store.isApplying || store.externalChange)
                Divider()
                Button(L10n.Hosts.UI.renameDots) {
                    sectionNameDraft = section.name
                    editFeedback = nil
                    sectionEdit = .rename(id: section.id, current: section.name)
                }
                Button(L10n.Hosts.UI.deleteSectionAction, role: .destructive) { pendingSectionDelete = section }
            } else {
                Text(L10n.Hosts.UI.baseLockedNote)
                    .font(.system(size: 11))
            }
        }
        // 整行拖拽排序：被拖拽项跟随手势，其余行平滑让位，基座项锁定不动。
        .offset(y: dragOffsetY(index: index, id: section.id))
        .zIndex(draggingSectionID == section.id ? 1 : 0)
        .scaleEffect(draggingSectionID == section.id ? 1.02 : 1)
        .shadow(color: draggingSectionID == section.id ? Theme.chromeShadow : .clear,
                radius: 10, y: 5)
        .animation(liftAnimation, value: draggingSectionID == section.id)
        .animation(shiftAnimation, value: dragTargetIndex)
        .simultaneousGesture(dragReorderGesture(section, index: index))
    }

    /// 段行步长 = 行高 44 + 列表行距，与 `sectionRow` 的 frame 一致。
    private var sectionStep: CGFloat { 44 + Layout.Metric.rowSpacing }

    /// 计算拖拽时各行的垂直偏移量。
    private func dragOffsetY(index: Int, id: UUID) -> CGFloat {
        guard let draggingSectionID else { return 0 }
        if id == draggingSectionID { return dragTranslation }
        guard let origin = dragOriginIndex, let target = dragTargetIndex else { return 0 }
        if target > origin, index > origin, index <= target { return -sectionStep }
        if target < origin, index >= target, index < origin { return sectionStep }
        return 0
    }

    /// 拖拽手势：只更新视觉与目标槽位，不碰模型——中途改模型会重建行、掐断手势。
    private func dragReorderGesture(_ section: HostsSection, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard !section.isBase, !store.isApplying, !store.externalChange else { return }
                if draggingSectionID != section.id {
                    draggingSectionID = section.id
                    dragTranslation = 0
                    dragOriginIndex = index
                    dragTargetIndex = index
                }
                guard draggingSectionID == section.id else { return }
                dragTranslation = value.translation.height
                let raw = Double(dragOriginIndex ?? index)
                    + Double(value.translation.height / sectionStep)
                dragTargetIndex = min(max(Int(raw.rounded()), 1),
                                      max(store.sections.count - 1, 1))
            }
            .onEnded { _ in
                guard draggingSectionID == section.id else { return }
                commitSectionDrag(section.id)
            }
    }

    /// 松手：一次性提交顺序，同时收回浮起与位移。基座固定在 0，叠加段从 1 起算。
    private func commitSectionDrag(_ id: UUID) {
        let origin = dragOriginIndex
        let target = dragTargetIndex
        withAnimation(reorderAnimation) {
            if let origin, let target, target != origin {
                let overlays = store.sections.filter { !$0.isBase }
                if let overlayFrom = overlays.firstIndex(where: { $0.id == id }) {
                    store.moveSection(id, offset: max(target - 1, 0) - overlayFrom)
                }
            }
            draggingSectionID = nil
            dragTranslation = 0
            dragOriginIndex = nil
            dragTargetIndex = nil
        }
    }

    private var shiftAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.reorder, scale: settings.motionScale)
        return duration > 0 ? .spring(duration: duration, bounce: Layout.Motion.shiftBounce) : nil
    }

    private var liftAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.reorder, scale: settings.motionScale)
        return duration > 0 ? .spring(duration: duration, bounce: Layout.Motion.dropBounce) : nil
    }

    // MARK: 编辑的绑定与提交

    private var sectionEditBinding: Binding<Bool> {
        Binding(get: { sectionEdit != nil }, set: { if !$0 { sectionEdit = nil; editFeedback = nil } })
    }

    private var sectionDeleteBinding: Binding<Bool> {
        Binding(get: { pendingSectionDelete != nil },
                set: { if !$0 { pendingSectionDelete = nil } })
    }

    private var lineEditBinding: Binding<Bool> {
        Binding(get: { lineEdit != nil }, set: { if !$0 { lineEdit = nil; editFeedback = nil } })
    }

    private var isCreatingSection: Bool {
        if case .create = sectionEdit { return true }
        return false
    }

    private var sectionEditTitle: String {
        isCreatingSection ? L10n.Hosts.UI.createSectionTitle : L10n.Hosts.UI.renameSectionTitle
    }
    private var sectionEditSubmitLabel: String {
        isCreatingSection ? L10n.Common.create : L10n.Common.save
    }

    private var sectionEditHint: String {
        isCreatingSection
            ? L10n.Hosts.UI.createSectionHint
            : L10n.Hosts.UI.renameSectionHint
    }

    private var lineEditTitle: String {
        if case .insert = lineEdit { return L10n.Hosts.UI.insertLineTitle }
        return L10n.Hosts.UI.editLineTitle
    }

    private func submitSectionEdit() {
        let name = sectionNameDraft.trimmingCharacters(in: .whitespaces)
        if let problem = store.sectionNameProblem(name, ignoring: currentRenameID) {
            editFeedback = problem      // 原地报错，不关框，让用户改完再按一次
            return
        }
        switch sectionEdit {
        case .create:
            if store.addSection(named: name) == nil {
                editFeedback = L10n.Hosts.UI.createFailed
                return
            }
        case .rename(let id, _):
            if !store.renameSection(id, to: name) {
                editFeedback = L10n.Hosts.UI.renameFailed
                return
            }
        case nil:
            return
        }
        sectionEdit = nil
        editFeedback = nil
    }

    private var currentRenameID: UUID? {
        if case .rename(let id, _) = sectionEdit { return id }
        return nil
    }

    private func submitLineEdit() {
        guard let lineEdit else { return }
        let text = lineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch lineEdit {
        case .edit(let id, let index):
            if !store.updateLine(sectionID: id, lineIndex: index, to: text) {
                editFeedback = L10n.Hosts.UI.updateLineFailed
                return
            }
        case .insert(let id, let at):
            // 空内容当作"取消插入"，别留一个空行占着禁用下标
            if text.isEmpty { self.lineEdit = nil; return }
            if !store.insertLine(text, sectionID: id, at: at) {
                editFeedback = L10n.Hosts.UI.insertLineFailed
                return
            }
        }
        self.lineEdit = nil
        editFeedback = nil
    }

    private func subtitle(for section: HostsSection) -> String {
        var parts = [section.isBase ? L10n.Hosts.UI.baseTag : L10n.Hosts.UI.overlayTag]
        parts.append(L10n.Hosts.UI.entriesShort(section.mappingLineCount))
        let disabled = section.disabledMappingCount
        if disabled > 0 { parts.append(L10n.Hosts.UI.disabledLinesShort(disabled)) }
        return parts.joined(separator: " · ")
    }

    // MARK: 右侧详情

    private var detail: some View {
        VStack(spacing: Layout.Spacing.s) {
            HStack(spacing: Layout.Spacing.xs) {
                ForEach(HostsTab.allCases) { item in
                    tabButton(item)
                }
                Spacer(minLength: Layout.Spacing.s)
                if model.tab == .effective {
                    searchField
                }
            }
            .frame(height: 26)

            Group {
                switch model.tab {
                case .effective: effectiveDetail
                case .content: contentDetail
                case .diff: diffDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.leading, Layout.Spacing.m)
        .padding(.top, Layout.Spacing.xs)
    }

    private func tabButton(_ item: HostsTab) -> some View {
        Button {
            model.tab = item
        } label: {
            Text(item.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.tab == item ? Theme.chipSelectedText : Theme.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(model.tab == item ? Theme.accent : Theme.chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(Type.micro)
                .foregroundStyle(Theme.decorationOnly)
            TextField(L10n.Hosts.UI.searchPlaceholder, text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
        }
        .padding(.horizontal, 8)
        .frame(width: 196, height: 24)
        .background(Theme.chipFill, in: Capsule())
    }

    // MARK: 生效预览

    private var effectiveDetail: some View {
        VStack(spacing: 0) {
            if filteredEntries.isEmpty {
                placeholder(search.isEmpty ? L10n.Hosts.UI.noEffective : L10n.Hosts.UI.noMatchingDomain)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            effectiveRow(entry)
                            Rectangle()
                                .fill(Theme.hairline.opacity(0.35))
                                .frame(height: 0.5)
                        }
                    }
                    .padding(.horizontal, Layout.Spacing.xs)
                }
                .scrollIndicators(.hidden)
            }
            HStack {
                Text("\(filteredEntries.count) / \(store.report.effective.count)")
                    .font(Type.micro.monospacedDigit())
                    .foregroundStyle(Theme.textBody)
                    .contentTransition(.numericText())
                    .animation(rollAnimation,
                               value: "\(filteredEntries.count)/\(store.report.effective.count)")
                Spacer()
                Text(L10n.Hosts.UI.lastWinsHint)
                    .font(Type.micro)
                    .foregroundStyle(Theme.textBody)
            }
            .padding(.horizontal, Layout.Spacing.xs)
            .frame(height: 20)
        }
    }

    private func effectiveRow(_ entry: HostsMapping) -> some View {
        let isConflict = store.report.conflicts.contains { $0.domain == entry.domain }
        return HStack(spacing: Layout.Spacing.s) {
            highlightedDomain(entry.domain)
                .font(.system(size: 12))
                .lineLimit(1)
            if isConflict {
                Image(systemName: "arrow.triangle.branch")
                    .font(Type.micro)
                    .foregroundStyle(Theme.warningText)
                    .accessibilityLabel(L10n.Hosts.UI.crossConflictLabel)
            }
            Text(entry.sectionName)
                .font(Type.micro)
                .foregroundStyle(Theme.textBody)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Theme.chipFill, in: Capsule())
            Spacer(minLength: Layout.Spacing.s)
            Text(entry.ip)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, Layout.Spacing.xs)
        .frame(height: 28)
    }

    private func highlightedDomain(_ domain: String) -> Text {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              let range = domain.range(of: term, options: .caseInsensitive) else {
            return Text(domain)
        }
        let head = Text(String(domain[..<range.lowerBound]))
        let hit = Text(String(domain[range])).foregroundStyle(Theme.accent)
        let tail = Text(String(domain[range.upperBound...]))
        return Text("\(head)\(hit)\(tail)")
    }

    // MARK: 段内容

    @ViewBuilder
    private var contentDetail: some View {
        if let section = selectedSection {
            VStack(spacing: 0) {
                HStack(spacing: Layout.Spacing.s) {
                    Text(section.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(section.isBase ? L10n.Hosts.UI.baseTag : L10n.Hosts.UI.overlayTag)
                        .font(Type.micro)
                        .foregroundStyle(Theme.textBody)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Theme.chipFill, in: Capsule())
                    if !section.isEnabled {
                        Text(L10n.Hosts.UI.disabledTag)
                            .font(Type.micro)
                            .foregroundStyle(Theme.warningText)
                    }
                    Spacer()
                    Button {
                        bulkText = section.lines.joined(separator: "\n")
                        bulkFeedback = nil
                        bulkEditSection = section
                    } label: {
                        Label(L10n.Hosts.UI.editBulk, systemImage: "square.and.pencil")
                            .font(Type.meta)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.secondaryText)
                    .disabled(store.externalChange || store.isApplying)
                    Text(L10n.Hosts.UI.mappingsCount(section.mappingLineCount))
                        .font(Type.micro.monospacedDigit())
                        .foregroundStyle(Theme.textBody)
                }
                .padding(.horizontal, Layout.Spacing.xs)
                .frame(height: 24)

                Button {
                    lineDraft = ""
                    editFeedback = nil
                    lineEdit = .insert(sectionID: section.id, at: nil)
                } label: {
                    Label(L10n.Hosts.UI.addLine, systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .disabled(store.externalChange)
                .padding(.horizontal, Layout.Spacing.xs)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { index, line in
                                lineRow(section, index: index, line: line)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, Layout.Spacing.xs)
                        .padding(.bottom, Layout.Spacing.s)
                    }
                    .scrollIndicators(.hidden)
                    // 一行 hosts 常有上百条，↑↓ 到底部时选中行必须在视口里
                    .onChange(of: model.selectedLineIndex) { _, index in
                        guard let index else { return }
                        proxy.scrollTo(index)
                    }
                }
            }
        } else {
            placeholder(L10n.Hosts.UI.selectSectionHint)
        }
    }

    @ViewBuilder
    private func lineRow(_ section: HostsSection, index: Int, line: String) -> some View {
        let info = HostsLineParser.parse(line)
        let disabled = section.disabledLines.contains(index)
        if info.isBlank {
            Color.clear.frame(height: 5)
        } else if info.isComment {
            HStack(spacing: Layout.Spacing.s) {
                Text("\(index + 1)")
                    .font(Type.mono(.micro))
                    .foregroundStyle(Theme.decorationOnly.opacity(0.6))
                    .frame(width: 22, alignment: .trailing)
                Text(line.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
        } else {
            HStack(spacing: Layout.Spacing.s) {
                Text("\(index + 1)")
                    .font(Type.mono(.micro))
                    .foregroundStyle(Theme.decorationOnly.opacity(0.7))
                    .frame(width: 22, alignment: .trailing)

                if info.isMapping {
                    Button {
                        store.toggleLine(sectionID: section.id, lineIndex: index)
                    } label: {
                        Image(systemName: disabled ? "circle" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(disabled ? Theme.decorationOnly : Theme.successText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(disabled ? L10n.Hosts.UI.enableLineA11y : L10n.Hosts.UI.disableLineA11y)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }

                Text(line.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(disabled ? Theme.decorationOnly : Theme.secondaryText)
                    .strikethrough(disabled, color: Theme.decorationOnly)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Layout.Spacing.xs)
                if info.hasError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(Type.micro)
                        .foregroundStyle(Theme.errorText)
                        .accessibilityLabel(info.issues.first?.message ?? L10n.Hosts.UI.validationErrorFallback)
                } else if !info.issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Type.micro)
                        .foregroundStyle(Theme.warningText)
                        .accessibilityLabel(info.issues.first?.message ?? L10n.Hosts.UI.warningFallback)
                }
            }
            .frame(height: 22)
            .opacity(disabled ? 0.55 : 1)
            // 键盘选中态与段行用同一层玻璃 pill，不新造一套视觉、也不铺不透明灰
            .modifier(SelectedRowGlass(selected: model.selectedLineIndex == index, cornerRadius: 6))
            .contextMenu {
                Button(L10n.Hosts.UI.editLineMenu) {
                    lineDraft = line
                    editFeedback = nil
                    lineEdit = .edit(sectionID: section.id, index: index)
                }
                Button(L10n.Hosts.UI.insertBelowMenu) {
                    lineDraft = ""
                    editFeedback = nil
                    lineEdit = .insert(sectionID: section.id, at: index + 1)
                }
                Divider()
                Button(L10n.Hosts.UI.deleteLineMenu, role: .destructive) {
                    store.deleteLine(sectionID: section.id, lineIndex: index)
                }
            }
        }
    }

    // MARK: 变更

    private var diffDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.Spacing.m) {
                if !store.report.conflicts.isEmpty { conflictsBlock }
                if !store.report.issues.isEmpty { issuesBlock }
                diffGroup(L10n.Hosts.UI.diffAdded, items: store.report.diff.added, color: Theme.successText, prefix: "+")
                diffGroup(L10n.Hosts.UI.diffRemoved, items: store.report.diff.removed, color: Theme.errorText, prefix: "−")
                diffGroup(L10n.Hosts.UI.diffChanged, items: store.report.diff.changed, color: Theme.warningText, prefix: "~")
                if store.report.diff.isEmpty && store.report.conflicts.isEmpty
                    && store.report.issues.isEmpty {
                    placeholder(L10n.Hosts.UI.diffSameAsTarget(targetName))
                        .frame(height: 120)
                }
            }
            .padding(.horizontal, Layout.Spacing.xs)
            .padding(.bottom, Layout.Spacing.s)
        }
        .scrollIndicators(.hidden)
    }

    private var conflictsBlock: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warningText)
                Text(L10n.Hosts.UI.conflictsHeader(store.report.conflicts.count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warningText)
                Spacer()
            }
            Text(L10n.Hosts.UI.conflictsExplainer)
                .font(Type.micro)
                .foregroundStyle(Theme.textBody)
            ForEach(store.report.conflicts) { conflict in
                HStack(alignment: .top, spacing: Layout.Spacing.xs) {
                    Text(conflict.domain)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                    Text(conflict.summary)
                        .font(Type.micro)
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Layout.Spacing.s)
        .background(Theme.warningText.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                         style: .continuous))
    }

    private var issuesBlock: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.errorText)
                Text(L10n.Hosts.UI.issuesHeader(store.report.blockingIssues.count, store.report.warningCount))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            ForEach(store.report.issues.prefix(20)) { issue in
                HStack(alignment: .top, spacing: Layout.Spacing.xs) {
                    Image(systemName: issue.severity == .error
                          ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(Type.micro)
                        .foregroundStyle(issue.severity == .error
                                         ? Theme.errorText : Theme.warningText)
                    Text(L10n.Hosts.UI.issueLine(issue.sectionName, issue.lineNumber, issue.message))
                        .font(Type.micro)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            if store.report.issues.count > 20 {
                Text(L10n.Hosts.UI.issuesMore(store.report.issues.count - 20))
                    .font(Type.micro)
                    .foregroundStyle(Theme.textBody)
            }
        }
    }

    @ViewBuilder
    private func diffGroup(_ title: String, items: [HostsDiffItem],
                           color: Color, prefix: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                    Text("\(items.count)")
                        .font(Type.micro.monospacedDigit())
                        .foregroundStyle(Theme.textBody)
                    Spacer()
                }
                ForEach(items) { item in
                    HStack(spacing: Layout.Spacing.xs) {
                        Text(prefix)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color)
                            .frame(width: 10)
                        Text(item.domain)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: Layout.Spacing.xs)
                        if let old = item.oldIP {
                            Text(old)
                                .font(Type.mono(.micro))
                                .foregroundStyle(Theme.textBody)
                                .strikethrough(item.newIP != nil)
                        }
                        if let new = item.newIP {
                            if item.oldIP != nil {
                                Image(systemName: "arrow.right")
                                    .font(Type.micro)
                                    .foregroundStyle(Theme.decorationOnly)
                            }
                            Text(new)
                                .font(Type.mono(.micro))
                                .foregroundStyle(color)
                        }
                    }
                    .frame(height: 18)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textBody)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: Layout.Spacing.s) {
            Text(L10n.Hosts.UI.mappingsCount(store.report.effective.count))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.textBody)
                .contentTransition(.numericText())
                .animation(rollAnimation, value: store.report.effective.count)
            if !store.report.blockingIssues.isEmpty {
                Label(L10n.Hosts.UI.errorsA11y(store.report.blockingIssues.count), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.errorText)
            } else if store.report.warningCount > 0 {
                Label(L10n.Hosts.UI.warningsCount(store.report.warningCount), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warningText)
            }
            if store.externalChange {
                Text(L10n.Hosts.UI.waitingExternal)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.warningText)
            }
            Spacer(minLength: Layout.Spacing.s)
            if store.isApplying {
                ProgressView()
                    .controlSize(.mini)
            }
            Button {
                requestApply()
            } label: {
                Text(L10n.Common.apply)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(canApply ? Theme.chipSelectedText : Theme.secondaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 24)
                    .background(canApply ? Theme.accent : Theme.chipFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canApply)
            .accessibilityLabel(L10n.Hosts.UI.applyA11y)
        }
        .frame(height: 30)
    }

    private var backupsMenu: some View {
        Menu {
            Button(L10n.Hosts.UI.backupNow) {
                do {
                    let backup = try store.createBackup()
                    showToast(L10n.Hosts.UI.backedUpToast(byteText(backup.byteCount)))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Divider()
            if let last = store.lastApplyBackup {
                Button(L10n.Hosts.UI.restoreBeforeApply(backupDateText(last.date))) {
                    pendingRestore = last
                }
                Divider()
            }
            if store.backups.isEmpty {
                Text(L10n.Hosts.UI.noBackups)
            } else {
                ForEach(store.backups) { backup in
                    Button(L10n.Hosts.UI.restoreBackupItem(backupDateText(backup.date), byteText(backup.byteCount))) {
                        pendingRestore = backup
                    }
                }
            }
        } label: {
            Label(L10n.Hosts.UI.backupsMenu, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.secondaryText)
        .disabled(store.isApplying)
    }

    // MARK: 动作

    private func requestApply() {
        guard canApply else { return }
        if store.report.conflicts.isEmpty {
            showApplyConfirm = true
        } else {
            showConflictConfirm = true
        }
    }

    private func performApply(acknowledgingConflicts: Bool) {
        let pinned = PanelHost.controller?.model.previewPinned ?? false
        PanelHost.controller?.model.previewPinned = true
        Task { @MainActor in
            defer { PanelHost.controller?.model.previewPinned = pinned }
            do {
                let result = try await store.apply(
                    acknowledgingConflicts: acknowledgingConflicts)
                showToast(L10n.Hosts.UI.appliedToast(result.diff.summary))
            } catch let error as HostsError {
                if case .conflictsRequireConfirmation = error {
                    showConflictConfirm = true
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performRestore(_ backup: HostsBackup) {
        let pinned = PanelHost.controller?.model.previewPinned ?? false
        PanelHost.controller?.model.previewPinned = true
        Task { @MainActor in
            defer { PanelHost.controller?.model.previewPinned = pinned }
            do {
                try await store.restore(backup)
                showToast(L10n.Hosts.UI.restoredToast(backupDateText(backup.date)))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private var reorderAnimation: Animation {
        .easeInOut(duration: a11y.motionDuration(Layout.Motion.reorder, scale: settings.motionScale))
    }

    private var rollAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.numericRoll, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }

    @ViewBuilder
    private func bulkEditor(_ section: HostsSection) -> some View {
        let lineCount = bulkText.isEmpty ? 0
            : bulkText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").count
        VStack(alignment: .leading, spacing: Layout.Spacing.m) {
            Text(L10n.Hosts.UI.bulkTitle(section.name))
                .font(Type.row.weight(.semibold))
            Text(L10n.Hosts.UI.bulkHint)
                .font(Type.micro)
                .foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)
            if !section.disabledLines.isEmpty {
                Text(L10n.Hosts.UI.bulkDisabledWarning(section.disabledLines.count))
                    .font(Type.micro)
                    .foregroundStyle(Theme.warningText)
            }
            TextEditor(text: $bulkText)
                .font(Type.mono(.body))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.previewFill,
                            in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                                 style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                          style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: Layout.Spacing.s) {
                Text(L10n.Hosts.UI.linesCount(lineCount))
                    .font(Type.micro.monospacedDigit())
                    .foregroundStyle(Theme.decorationOnly)
                Spacer()
                if let bulkFeedback {
                    Text(bulkFeedback)
                        .font(Type.micro)
                        .foregroundStyle(Theme.errorText)
                        .lineLimit(2)
                }
                Button(L10n.Common.cancel) {
                    bulkEditSection = nil
                    bulkFeedback = nil
                }
                Button(L10n.Common.save) { saveBulk(section) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Layout.Spacing.xl)
        .frame(width: 560, height: 460)
    }

    private func saveBulk(_ section: HostsSection) {
        let normalized = bulkText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#--------") {
                bulkFeedback = L10n.Hosts.UI.bulkHeaderError(offset + 1)
                return
            }
            let info = HostsLineParser.parse(line)
            if info.hasError {
                bulkFeedback = L10n.Hosts.UI.bulkLineError(
                    offset + 1, info.issues.first?.message ?? L10n.Hosts.UI.bulkFormatFallback)
                return
            }
        }
        guard store.replaceLines(sectionID: section.id, with: lines) else {
            bulkFeedback = L10n.Hosts.UI.bulkMissingSection
            return
        }
        bulkEditSection = nil
        bulkFeedback = nil
        showToast(L10n.Hosts.UI.bulkSavedToast(lines.count))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Layout.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warningText)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button(L10n.Common.retry) { store.load() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 绑定与文案

    private var baseOffBinding: Binding<Bool> {
        Binding(get: { pendingBaseOff != nil },
                set: { if !$0 { pendingBaseOff = nil } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }

    private var baseOffMessage: String {
        let count = max(0, (pendingBaseOff?.mappingLineCount ?? 0)
            - (pendingBaseOff?.disabledMappingCount ?? 0))
        return L10n.Hosts.UI.baseOffMessage(pendingBaseOff?.name ?? "", count)
    }

    private var conflictAlertMessage: String {
        let names = store.report.conflicts.prefix(5).map(\.domain)
            .joined(separator: L10n.Hosts.UI.conflictDomainJoiner)
        let more = store.report.conflicts.count > 5
            ? L10n.Hosts.UI.conflictMore(store.report.conflicts.count)
            : ""
        return L10n.Hosts.UI.conflictMessage(names, more)
    }

    private func backupDateText(_ date: Date?) -> String {
        guard let date else { return L10n.Common.unknownTime }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .shortened, locale: appLanguage.locale))
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

