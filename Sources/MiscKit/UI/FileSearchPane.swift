import AppKit
import MiscKitCore
import SwiftUI
import UniformTypeIdentifiers

/// 文件模式：筛选 chips + 范围 + 结果列表/分栏 + 计数与排序。
struct FileSearchPane: View {
    @Bindable var model: FileSearchModel
    let panelWidth: CGFloat
    let onAction: (ToolAction) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @State private var aliasTarget: FileItem?
    @State private var aliasText = ""
    @State private var showingAliasEditor = false
    @State private var showingScopeSettings = false
    @State private var pendingTrash: [FileItem]?
    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared
    /// 首屏级联：新一批结果出现时给行添加递延入场动画
    @State private var rowStaggerArmed = true

    private var isSplit: Bool {
        model.settings.viewMode == .split
            && panelWidth >= Layout.Metric.previewBreakpoint
    }

    private var canSplit: Bool {
        panelWidth >= Layout.Metric.previewBreakpoint
    }

    private var rowRevealDuration: TimeInterval {
        a11y.motionDuration(Layout.Motion.rowReveal, scale: settings.motionScale)
    }

    private var staggerStepSeconds: TimeInterval {
        a11y.motionDuration(Layout.Motion.staggerStep, scale: settings.motionScale)
    }

    private var rollAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.numericRoll, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }

    private var listHeight: CGFloat {
        let rows = Layout.listHeight(rows: model.visibleRowCount, verticalPadding: Layout.Spacing.s)
        return isSplit ? max(rows, Layout.Metric.filePreviewMinHeight) : rows
    }

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: Layout.Metric.filePaneGap) {
            toolbar
            if let notice = model.displayNotice {
                noticeBar(notice)
            }
            HStack(alignment: .top, spacing: 0) {
                resultArea
                if isSplit {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 0.5, height: listHeight)
                    FilePreviewPane(item: model.selectedItem)
                        .frame(width: Layout.Metric.previewWidth, height: listHeight)
                }
            }
            footer
        }
        .padding(.bottom, Layout.Spacing.s)
        .onDisappear { model.cancelDragGuard() }
        // 级联入场窗口：结果非空时触发递延入场，窗口期后恢复正常
        .task(id: model.items.isEmpty) {
            guard !model.items.isEmpty else { rowStaggerArmed = true; return }
            try? await Task.sleep(for: .seconds(Layout.Motion.staggerWindow))
            guard !Task.isCancelled else { return }
            rowStaggerArmed = false
        }
        .alert(L10n.Files.Alias.title, isPresented: $showingAliasEditor) {
            TextField(L10n.Files.Alias.placeholder, text: $aliasText)
            Button(L10n.Common.cancel, role: .cancel) { aliasTarget = nil }
            Button(L10n.Common.save) {
                if let target = aliasTarget {
                    model.setAlias(aliasText, for: target)
                }
                aliasTarget = nil
            }
        }
        .sheet(isPresented: $showingScopeSettings) {
            FileScopeSettingsSheet(model: model)
        }
        .alert(L10n.Files.Trash.confirmTitle, isPresented: trashBinding) {
            Button(L10n.Common.cancel, role: .cancel) { pendingTrash = nil }
            Button(L10n.Files.Context.trash, role: .destructive) {
                if let targets = pendingTrash { model.trash(targets) }
                pendingTrash = nil
            }
        } message: {
            Text(trashMessage)
        }
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } })
    }

    /// 列出前 5 项并截断超长名称，避免批量确认弹窗内容过宽。
    private var trashMessage: String {
        guard let targets = pendingTrash, let first = targets.first else { return "" }
        let scope: String
        if targets.count == 1 {
            scope = "\"\(first.name)\""
        } else {
            let listed = targets.prefix(5)
                .map { "\"\($0.name.count > 24 ? String($0.name.prefix(24)) + "…" : $0.name)\"" }
                .joined(separator: " ")
            scope = L10n.Files.Trash.manyScope(listed, targets.count)
        }
        let inside = targets.contains(where: \.isDirectory) ? L10n.Files.Trash.includingContents : ""
        return L10n.Files.Trash.message(scope, inside)
    }

    // MARK: 顶部 chips + 范围

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(FileCategory.allCases) { category in
                chip(category)
            }
            Spacer(minLength: Layout.Spacing.s)
            scopeSettingsButton
        }
        .frame(height: Layout.Metric.fileChipsHeight)
        .padding(.horizontal, Layout.Spacing.l)
    }

    private func chip(_ category: FileCategory) -> some View {
        let selected = model.category == category
        return Button {
            model.selectCategory(category)
        } label: {
            Text(category.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Theme.chipSelectedText : Theme.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(selected ? Theme.accent : Theme.chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var scopeSettingsButton: some View {
        Button {
            showingScopeSettings = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                Text(L10n.Files.Settings.button)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Theme.chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Files.Settings.a11y)
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(notice)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, Layout.Spacing.l)
        .frame(height: Layout.Metric.fileNoticeHeight)
    }

    // MARK: 结果列表

    private var resultArea: some View {
        // 同启动器的结果列表：可视 7 行而结果更多时，↑↓ 必须把选中项滚进视口
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.Metric.rowSpacing) {
                    if model.items.isEmpty {
                        Text(model.isSearching ? L10n.Files.searching : L10n.Launcher.noMatch)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textBody)
                            .padding(.horizontal, Layout.SpacingValue.rowPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Layout.Metric.rowHeight)
                    } else {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            FileResultRow(item: item,
                                          index: index,
                                          isActive: index == model.selection,
                                          isMultiSelected: model.isMultiSelected(index),
                                          isPinned: model.isPinned(item),
                                          highlightTerm: model.highlightTerm,
                                          onSelect: { handleClick(at: index, item: item) },
                                          onOpen: { open(at: index, item: item) },
                                          onDragStarted: { model.beginDragGuard() })
                            .id(item.id)
                            .modifier(RowReveal(
                                delay: {
                                    guard rowStaggerArmed else { return nil }
                                    return Double(min(index, 8)) * staggerStepSeconds
                                },
                                duration: rowRevealDuration,
                                offset: Layout.Spacing.xs))
                            .contextMenu { contextMenu(for: item, index: index) }
                        }
                    }
                }
                .padding(.horizontal, Layout.Metric.listInset)
                .padding(.vertical, Layout.Spacing.xs)
            }
            .frame(height: listHeight)
            .scrollIndicators(.hidden)
            .onChange(of: model.selection) { _, target in
                guard model.items.indices.contains(target) else { return }
                proxy.scrollTo(model.items[target].id)
            }
        }
    }

    /// 普通单击只选中，右侧预览跟着走；打开留给双击/回车/⌘N。
    /// Button 拿不到事件修饰键，读当前按键状态即可区分 ⌘/⇧ 多选。
    private func handleClick(at index: Int, item: FileItem) {
        model.noteTap(kind: "row", to: String(index))
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            model.toggleSelection(at: index)
        } else if flags.contains(.shift) {
            model.extendSelection(to: index)
        } else {
            model.prepareOpen(at: index)
        }
    }

    private func open(at index: Int, item: FileItem) {
        model.prepareOpen(at: index)
        onAction(model.primaryAction(for: item))
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem, index: Int) -> some View {
        Button(L10n.RowAction.open) {
            model.noteMenu("open")
            onAction(.openFile(item.url))
        }
        Button(L10n.RowAction.reveal) {
            model.noteMenu("reveal")
            onAction(.reveal(item.url))
        }
        // 拷贝的是文件本身（不是文字），到访达/微信 ⌘V 就是复制这些项目。
        let targets = model.menuTargets(for: item, index: index)
        Button(targets.count > 1 ? L10n.Files.Context.copyMany(targets.count) : L10n.Files.Context.copy) {
            model.noteMenu(targets.count > 1 ? "copyMany" : "copy")
            onAction(.copyItems(targets.map(\.url)))
        }
        Button(L10n.RowAction.copyPath) {
            model.noteMenu("copyPath")
            onAction(.copy(item.url.path))
        }
        Button(L10n.RowAction.terminal) {
            model.noteMenu("openInTerminal")
            onAction(.openInTerminal(item.url))
        }
        Divider()
        let pinned = model.isPinned(item)
        Button(pinned ? L10n.Files.Context.unpin : L10n.Files.Context.pin) {
            model.noteMenu(pinned ? "unpin" : "pin")
            model.togglePin(item)
        }
        if item.isDirectory {
            Button(model.alias(for: item) == nil ? L10n.Files.Alias.set : L10n.Files.Alias.edit) {
                model.noteMenu("alias")
                aliasTarget = item
                aliasText = model.alias(for: item) ?? ""
                showingAliasEditor = true
            }
        }
        Divider()
        Button(targets.count > 1 ? L10n.Files.Context.trashMany(targets.count) : L10n.Files.Context.trash,
               role: .destructive) {
            model.noteMenu(targets.count > 1 ? "trashMany" : "trash")
            pendingTrash = targets
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: Layout.Spacing.m) {
            Text(model.isSearching ? L10n.Files.searching : model.countText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textBody)
                .contentTransition(.numericText())
                .animation(rollAnimation, value: model.countText)
            if model.selectedCount > 0 {
                Text(L10n.Files.selectedCount(model.selectedCount))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: Layout.Spacing.s)
            sortMenu
            if canSplit {
                viewToggle
            }
        }
        .frame(height: Layout.Metric.fileFooterHeight)
        .padding(.horizontal, Layout.Spacing.l)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FileSort.allCases) { sort in
                Button {
                    model.selectSort(sort)
                } label: {
                    if model.settings.sort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(Type.micro)
                Text(model.settings.sort.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var viewToggle: some View {
        HStack(spacing: 2) {
            viewButton(.list, symbol: "list.bullet", help: L10n.Files.ViewMode.list)
            viewButton(.split, symbol: "rectangle.split.2x1", help: L10n.Files.ViewMode.split)
        }
    }

    private func viewButton(_ mode: FileViewMode, symbol: String, help: String) -> some View {
        let selected = model.settings.viewMode == mode
        return Button {
            model.setViewMode(mode)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                .frame(width: 22, height: 20)
                .background(selected ? Theme.keycapFill.opacity(0.8) : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        // 避免在非激活状态面板触发 AppKit tooltip 命中测试异常，此处仅保留无障碍标签。
        .accessibilityLabel(help)
    }

}

// MARK: - 结果行

private struct FileResultRow: View {
    let item: FileItem
    let index: Int
    let isActive: Bool
    let isMultiSelected: Bool
    let isPinned: Bool
    let highlightTerm: String?
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDragStarted: () -> Void
    @Environment(\.showsShortcutHints) private var showsShortcutHints
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        let _ = appLanguage
        Button {
            // 键盘 ⌘N 触发时 currentEvent 是 keyDown；鼠标单击只负责选中，第二下才打开。
            // 双击别再挂 TapGesture(count:2)：它和行上的 onDrag 抢手势，鼠标稍微动一点
            // 第二下就被当成拖拽起手，表现成"有时候双击没反应"。系统给的 clickCount
            // 尊重「连按速度」设置，也不会被拖拽判成第一下。
            let event = NSApp.currentEvent
            if event?.type == .keyDown || (event?.clickCount ?? 1) >= 2 {
                onOpen()
            } else {
                onSelect()
            }
        } label: {
            HStack(spacing: Layout.Spacing.m) {
                FileThumbnailView(url: item.url, isDirectory: item.isDirectory)
                VStack(alignment: .leading, spacing: 2) {
                    highlightedTitle
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Text(FilePathDisplay.abbreviated(item.url))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Layout.Spacing.s)
                if item.needsDownload {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warningText)
                        .accessibilityLabel(L10n.Files.iCloudNotDownloaded)
                }
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(Type.micro)
                        .foregroundStyle(Theme.decorationOnly)
                }
                if isMultiSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel(L10n.Files.selected)
                }
                if showsShortcutHints { keycap }
            }
            .padding(.horizontal, Layout.SpacingValue.rowPadding)
            .frame(height: Layout.Metric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 多选是"用户勾中的一组"，保留强调色铺底；键盘指向那一行改用玻璃 pill
        .background(isMultiSelected ? Theme.multiSelectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: Layout.Metric.rowCornerRadius,
                                         style: .continuous))
        .modifier(SelectedRowGlass(selected: isActive))
        .modifier(RowShortcutModifier(index: index))
        .onDrag {
            onDragStarted()
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
    }

    @ViewBuilder
    private var keycap: some View {
        if let digit = ResultTile.digit(for: index) {
            Text("⌘\(digit)")
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.keycapText.opacity(0.8))
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Theme.keycapFill.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var highlightedTitle: Text {
        guard let term = highlightTerm, !term.isEmpty,
              let range = item.name.range(of: term, options: .caseInsensitive) else {
            return Text(item.name)
        }
        let head = Text(String(item.name[..<range.lowerBound]))
        let hit = Text(String(item.name[range])).foregroundStyle(Theme.accent)
        let tail = Text(String(item.name[range.upperBound...]))
        return Text("\(head)\(hit)\(tail)")
    }
}

// MARK: - 右侧属性表

private struct FilePreviewPane: View {
    let item: FileItem?
    @Environment(\.appLanguage) private var appLanguage
    @State private var childCount: Int?

    var body: some View {
        let _ = appLanguage
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.Spacing.m) {
                        header(item)
                        VStack(alignment: .leading, spacing: 7) {
                            property(L10n.Files.Preview.path, FilePathDisplay.abbreviated(item.url), selectable: true)
                            if item.isDirectory {
                                property(L10n.Files.Preview.itemsCount, childCount.map(String.init) ?? "…")
                            }
                            property(L10n.Files.Preview.kind, kind(item))
                            property(L10n.Files.Preview.created, date(item.creationDate))
                            property(L10n.Files.Preview.modified, date(item.modificationDate))
                            property(L10n.Files.Preview.lastOpened, date(item.lastUsedDate))
                            if !item.contentTypeTree.isEmpty {
                                property(L10n.Files.Preview.typeTree,
                                         item.contentTypeTree.prefix(6).joined(separator: " › "),
                                         multiline: true)
                            }
                        }
                    }
                    .padding(.horizontal, Layout.Spacing.m)
                    .padding(.vertical, Layout.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .task(id: item.id) { await loadChildCount(item) }
            } else {
                Text(L10n.Files.Preview.selectPrompt)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textBody)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.previewFill)
    }

    private func header(_ item: FileItem) -> some View {
        HStack(spacing: Layout.Spacing.s) {
            FileThumbnailView(url: item.url, isDirectory: item.isDirectory, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Text(kind(item))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textBody)
            }
        }
    }

    private func property(_ label: String, _ value: String,
                          selectable: Bool = false, multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Layout.Spacing.s) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textBody)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(multiline ? 4 : 1)
                .truncationMode(.middle)
                .modifier(SelectableModifier(selectable: selectable))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kind(_ item: FileItem) -> String {
        if item.isDirectory { return L10n.Files.Preview.folderKind }
        if let type = item.contentType.flatMap(UTType.init),
           let description = type.localizedDescription {
            return description
        }
        return item.contentType ?? (item.url.pathExtension.isEmpty ? L10n.Files.Preview.fileKind : item.url.pathExtension.uppercased())
    }

    private func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .numeric, time: .shortened)
    }

    private func loadChildCount(_ item: FileItem) async {
        childCount = nil
        guard item.isDirectory else { return }
        let path = item.url.path
        let count = await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(atPath: path).count)
        }.value
        guard !Task.isCancelled else { return }
        childCount = count
    }
}

/// `.textSelection` 的 enabled/disabled 是两个不同类型，不能放进三元表达式。
private struct SelectableModifier: ViewModifier {
    let selectable: Bool

    func body(content: Content) -> some View {
        if selectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

/// 文件搜索范围设置：只筛查询，不动索引根目录。
private struct FileScopeSettingsSheet: View {
    @Bindable var model: FileSearchModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage

    private var scopeBinding: Binding<FileScope> {
        Binding(get: { model.settings.scope },
                set: { model.selectScope($0) })
    }

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: Layout.Spacing.l) {
            HStack {
                Text(L10n.Files.Settings.a11y)
                    .font(Type.row.weight(.semibold))
                Spacer()
                Button(L10n.Common.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Picker(L10n.Files.Scope.heading, selection: scopeBinding) {
                Text(L10n.Files.Scope.mac).tag(FileScope.mac)
                Text(L10n.Files.Scope.foldersOnly).tag(FileScope.folders)
            }
            .pickerStyle(.segmented)
            .id("picker-file-scope-\(appLanguage.resolved.rawValue)")

            Text(L10n.Files.Scope.description)
                .font(Type.micro)
                .foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Layout.Spacing.s) {
                Text(L10n.Files.Scope.folders)
                    .font(Type.meta.weight(.medium))
                if model.settings.directories.isEmpty {
                    Text(L10n.Files.Scope.empty)
                        .font(Type.micro)
                        .foregroundStyle(Theme.textBody)
                } else {
                    ScrollView {
                        VStack(spacing: Layout.Spacing.xs) {
                            ForEach(model.settings.directories, id: \.path) { url in
                                HStack(spacing: Layout.Spacing.s) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Theme.secondaryText)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent)
                                            .font(Type.body)
                                            .lineLimit(1)
                                        Text(url.path)
                                            .font(Type.micro)
                                            .foregroundStyle(Theme.textBody)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: Layout.Spacing.s)
                                    Button(L10n.Common.remove, role: .destructive) {
                                        model.removeDirectory(url)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .frame(height: 34)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                Button(L10n.Files.Scope.addFolder) { model.chooseDirectory() }
                    .buttonStyle(.borderless)
            }
            .padding(Layout.Spacing.m)
            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                                            style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(Layout.Spacing.xl)
        .frame(width: 460, height: 330)
    }
}
