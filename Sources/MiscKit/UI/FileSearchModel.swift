import AppKit
import Observation
import os
import MiscKitCore

/// 文件模式的状态机：输入去抖、在途查询取消、范围/类型/排序切换与选择。
@MainActor
@Observable
final class FileSearchModel {
    private(set) var items: [FileItem] = []
    private(set) var total = 0
    private(set) var isTruncated = false
    /// 索引给的总数被封顶时只作下界用，底栏说「1000+」而不是一个假精确值。
    private(set) var totalIsExact = true
    private(set) var notice: String?
    /// 删除这类动作的结果另占一格：`notice` 每次查询都会被服务端覆盖，混进去就是一条闪没的提示。
    private(set) var actionNotice: String?
    private(set) var isSearching = false
    private(set) var currentQuery = ""
    var selection = 0
    var category: FileCategory = .all

    /// 多选集合（批量删除等），存 FileItem.id（路径）而不是下标，结果刷新后不会错位。
    private(set) var selectedIDs: Set<FileItem.ID> = []
    private var selectionAnchor: Int?

    let settings = FileSearchSettings.shared

    /// 限制单次展示的最大行数，保证响应性能与滚动流畅。
    /// 300 行由 `LazyVStack` 懒渲染；真正决定首屏的是上面的 fast 段，不是这个上限。
    static let resultLimit = 300

    private var searchTask: Task<Void, Never>?
    private var fastPreviewTask: Task<Void, Never>?
    private var dragGuardTask: Task<Void, Never>?
    private var generation = 0
    /// 记录一次键入从 `update` 到 fast 首屏落地的耗时；只用于 `file.firstFast` 面包屑。
    private var firstFastStartedAt: Date?
    private var firstFastLoggedToken = 0
    private var lastTapAt: Date?
    private var tapBurst = 0
    private let service = FileSearchService.shared
    private let fileLog = Logger(subsystem: "app.misckit.launcher", category: "files")

    /// 验收用：`MISCKIT_DEBUG_FILE_CATEGORY=folder` 让面板直接以某个类型打开。
    init() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_FILE_CATEGORY"],
           let value = FileCategory(rawValue: raw) {
            category = value
        }
        #endif
        observeIndexPhase()
    }

    var selectedItem: FileItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    var selectedCount: Int { selectedIDs.count }
    var hasMultiSelection: Bool { !selectedIDs.isEmpty }
    var selectedItems: [FileItem] { items.filter { selectedIDs.contains($0.id) } }

    func isMultiSelected(_ index: Int) -> Bool {
        items.indices.contains(index) && selectedIDs.contains(items[index].id)
    }

    /// 普通单击仍是打开文件：先回到单选，再清掉多选。
    func prepareOpen(at index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        selectionAnchor = index
        selectedIDs.removeAll()
    }

    func toggleSelection(at index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        selectionAnchor = index
        let id = items[index].id
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func extendSelection(to index: Int) {
        guard items.indices.contains(index) else { return }
        let anchor = min(max(selectionAnchor ?? selection, 0), items.count - 1)
        selectionAnchor = anchor
        selection = index
        for position in min(anchor, index)...max(anchor, index) {
            selectedIDs.insert(items[position].id)
        }
    }

    func selectAll() {
        guard !items.isEmpty else { return }
        if selectionAnchor == nil { selectionAnchor = 0 }
        selectedIDs = Set(items.map(\.id))
    }

    func clearMultiSelection() {
        selectedIDs.removeAll()
        selectionAnchor = nil
    }

    func isFileQuery(_ raw: String) -> Bool {
        FileQueryParser(aliases: FileAliasStore.shared.aliases).isFileMode(raw)
    }

    func update(query: String) {
        currentQuery = query
        actionNotice = nil
        selection = 0
        clearMultiSelection()
        // 索引就绪时查询走 SQLite，Spotlight 探针纯属白烧 I/O：
        // 它扫的是整盘 `Applications`，一次 1.5 秒上限，正好和按键抢磁盘。
        if !FileIndex.shared.isReady { service.prewarmSpotlightAvailability() }
        firstFastStartedAt = Date()
        // fast 段只查等值 + 前缀，0.02–1ms；先立即上屏，body/count 仍然等 50ms。
        // 这样连续键入不会把包含段/计数提前，首屏也不用再白等一个去抖窗口。
        let delay: Duration = isKeywordSearch() ? .milliseconds(50) : .zero
        schedule(delay: delay)
        scheduleFastPreview(token: generation, query: query)
    }

    func deactivate() {
        searchTask?.cancel()
        searchTask = nil
        fastPreviewTask?.cancel()
        fastPreviewTask = nil
        isSearching = false
    }

    func move(_ delta: Int) {
        selection = ListSelection.move(current: selection, delta: delta, count: items.count)
    }

    /// 连点诊断：崩溃栈是 SwiftUI 命中测试里的系统帧（无业务帧），要定位就得知道
    /// 崩前最后一下点的是什么、距上次多少毫秒、连到第几下。只记状态，不记查询词与文件名。
    func noteTap(kind: String, to: String) {
        let now = Date()
        let gap = lastTapAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        tapBurst = gap >= 0 && gap < 1200 ? tapBurst + 1 : 1
        lastTapAt = now
        Breadcrumbs.event("file.tap", ["kind": kind, "to": to, "gap": String(gap),
                                       "burst": String(tapBurst), "results": String(items.count)])
    }

    /// 右键菜单动作：只记动作与规模，不记文件名；用来判断右键习惯是否值得保留。
    func noteMenu(_ action: String) {
        Breadcrumbs.event("file.menu", ["action": action, "results": String(items.count),
                                        "multi": String(selectedCount)])
    }

    func selectCategory(_ value: FileCategory) {
        noteTap(kind: "chip", to: value.rawValue)
        guard category != value else { return }
        category = value
        selection = 0
        rerun()
    }

    func selectSort(_ value: FileSort) {
        noteTap(kind: "sort", to: value.rawValue)
        guard settings.sort != value else { return }
        settings.sort = value
        rerun()
    }

    func selectScope(_ value: FileScope) {
        noteTap(kind: "scope", to: value.rawValue)
        if value == .folders, settings.directories.isEmpty {
            chooseDirectory()
            return
        }
        guard settings.scope != value else { return }
        settings.scope = value
        rerun()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.Files.Picker.prompt
        panel.message = L10n.Files.Picker.message
        panel.level = PanelHost.pickerLevel
        PanelHost.controller?.model.dragGuard = true
        // 启动器面板本身是 nonactivating；不先激活 App，系统选择器会出现一段时间
        // 但点不动（第一次点击只是把 App 叫到前台）。选择器是真正的模态，激活它是对的。
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            Task { @MainActor in
                PanelHost.controller?.model.dragGuard = false
                defer { PanelHost.controller?.show() }
                guard let self, response == .OK else { return }
                for url in panel.urls { self.settings.addDirectory(url) }
                self.settings.scope = .folders
                self.rerun()
            }
        }
    }

    func beginDragGuard() {
        dragGuardTask?.cancel()
        PanelHost.controller?.model.dragGuard = true
        dragGuardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            PanelHost.controller?.model.dragGuard = false
            self?.dragGuardTask = nil
        }
    }

    func cancelDragGuard() {
        dragGuardTask?.cancel()
        dragGuardTask = nil
        PanelHost.controller?.model.dragGuard = false
    }

    func setViewMode(_ value: FileViewMode) {
        settings.viewMode = value
    }

    func removeDirectory(_ url: URL) {
        settings.removeDirectory(url)
        rerun()
    }

    /// 右键批量动作（拷贝、移到废纸篓）的作用对象：勾了多选且这一行在集合里就整组走，否则只走这一行。
    /// 两个动作共用这一条判法，免得它们对「多选」的理解分叉。
    func menuTargets(for item: FileItem, index: Int) -> [FileItem] {
        if selectedCount > 1, isMultiSelected(index) { return selectedItems }
        return [item]
    }

    /// `⌘C` 的作用对象：走与右键「拷贝」同一条判定，两个入口对多选的理解不许分叉。
    func keyboardCopyTargets() -> [FileItem] {
        guard let item = selectedItem else { return [] }
        return menuTargets(for: item, index: selection)
    }

    /// 只进废纸篓，不就地抹掉：误点还能从访达捞回来，跳过了"彻底删除"这条不可逆的路。
    func trash(_ targets: [FileItem]) {
        guard !targets.isEmpty else { return }
        var failures: [String] = []
        var moved: [FileItem] = []
        var landed: [String] = []
        for item in targets {
            var destination: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
                moved.append(item)
                // 记下真正落点：重名时系统会改名（"x 2"），事后按原名去废纸篓找不到会误判"没删"。
                landed.append("\(item.url.path)->\(destination?.path ?? "?")")
            } catch {
                failures.append("\"\(item.name)\": \(error.localizedDescription)")
            }
        }
        audit(targets: targets, moved: moved, failures: failures, landed: landed)
        if failures.isEmpty {
            actionNotice = moved.count > 1 ? L10n.Files.Trash.movedMany(moved.count) : L10n.Files.Trash.movedOne
        } else if !moved.isEmpty {
            actionNotice = L10n.Files.Trash.partialFailure(moved.count, failures.count, failures.joined(separator: "; "))
        } else {
            actionNotice = L10n.Files.Trash.failedNone(failures.joined(separator: "; "))
        }
        let movedIDs = Set(moved.map(\.id))
        items.removeAll { movedIDs.contains($0.id) }
        total = max(total - moved.count, items.count)
        selection = min(selection, max(items.count - 1, 0))
        clearMultiSelection()
        // 不再 rerun：索引行这会儿可能还在，重查会把慢半拍的结果盖回列表里。
        Task {
            await FileIndex.shared.forget(moved.map(\.url))
        }
    }

    /// 删除留痕：事后要能一句话回答"到底是不是这个功能删的、落到哪儿去了"。
    /// 记完整路径与系统给的真实落点（重名会被改名），路径最多列 20 条，多的报余数。
    private func audit(targets: [FileItem], moved: [FileItem], failures: [String], landed: [String]) {
        let shown = landed.prefix(20).joined(separator: " ")
        let rest = landed.count > 20 ? "+\(landed.count - 20)项未列 " : ""
        let failed = failures.isEmpty ? "" : " 失败：\(failures.joined(separator: " "))"
        // 使用 default 日志级别，确保系统控制台及终端无需附加参数即可直接读取。
        fileLog.log("移到废纸篓 输入=\(targets.count, privacy: .public) 成功=\(moved.count, privacy: .public) 查询=\"\(self.currentQuery, privacy: .public)\" \(shown, privacy: .public)\(rest, privacy: .public)\(failed, privacy: .public)")
    }

    func togglePin(_ item: FileItem) {
        FileHistoryStore.shared.togglePin(item.url)
        if case .browse = parsedKind() { rerun() }
    }

    func isPinned(_ item: FileItem) -> Bool {
        FileHistoryStore.shared.isPinned(item.url)
    }

    func setAlias(_ name: String, for item: FileItem) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            if let existing = FileAliasStore.shared.alias(for: item.url) {
                FileAliasStore.shared.remove(existing)
            }
        } else {
            FileAliasStore.shared.set(clean, for: item.url)
        }
        rerun()
    }

    func alias(for item: FileItem) -> String? {
        FileAliasStore.shared.alias(for: item.url)
    }

    func primaryAction(for item: FileItem) -> ToolAction {
        .openFile(item.url)
    }

    var countText: String {
        guard isTruncated else { return L10n.Files.Count.exact(total) }
        return totalIsExact
            ? L10n.Files.Count.truncated(total, items.count)
            : L10n.Files.Count.many(total, items.count)
    }

    var highlightTerm: String? {
        if case .search(let term) = parsedKind() {
            return FileSearchSyntax.parse(term).highlightTerm
        }
        return nil
    }

    /// 索引进度优先于普通提示；索引就绪后自动消失。
    var displayNotice: String? {
        let parts = [FileIndex.shared.statusNotice, notice, actionNotice].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    // MARK: 查询调度

    private func rerun() {
        schedule(delay: .zero)
    }

    private func schedule(delay: Duration) {
        searchTask?.cancel()
        fastPreviewTask?.cancel()
        service.cancelPendingQueries()
        generation += 1
        let token = generation
        let query = currentQuery
        isSearching = true
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.run(query: query, token: token)
        }
    }

    /// 键入后不等 50ms 去抖，先把只在 SQLite 快段的等值/前缀结果贴上。
    /// 空结果不在这里落地：否则每敲一个中间状态都会闪一下空态，等 `run` 的 fast 再判。
    private func scheduleFastPreview(token: Int, query: String) {
        guard token == generation, isKeywordSearch(query), FileIndex.shared.isReady else { return }
        let request = FileSearchRequest(text: query, category: category,
                                        scope: settings.scope,
                                        directories: settings.directories,
                                        sort: settings.sort,
                                        limit: Self.resultLimit)
        fastPreviewTask = Task { [weak self] in
            guard let self else { return }
            guard let fast = await self.service.searchFast(request) else { return }
            guard token == self.generation, !Task.isCancelled else { return }
            if !fast.items.isEmpty {
                self.applyFast(fast)
                self.noteFirstFast(token: token)
            }
        }
    }

    /// 首屏埋点只到「fast 结果已应用到 model」，不含 SwiftUI 下一帧渲染；
    /// 不记查询词，只记长度与毫秒，避免把剪贴板带入的文本写进日志。
    private func noteFirstFast(token: Int) {
        guard token == generation, firstFastLoggedToken != token,
              let started = firstFastStartedAt else { return }
        firstFastLoggedToken = token
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Breadcrumbs.event("file.firstFast", [
            "ms": String(ms),
            "termLen": String(currentQuery.count),
            "sort": settings.sort.rawValue,
        ])
    }

    private func run(query: String, token: Int) async {
        let request = FileSearchRequest(text: query, category: category,
                                        scope: settings.scope,
                                        directories: settings.directories,
                                        sort: settings.sort,
                                        limit: Self.resultLimit)

        // 索引就绪时走三段：fast 先上屏，body 补包含段，count 只更新底栏。
        // 快段为空时不拿空列表覆盖旧结果，等 body 明确返回空再说，避免输入过程中闪空。
        if isKeywordSearch(query), FileIndex.shared.isReady,
           let fast = await service.searchFast(request) {
            guard token == generation, !Task.isCancelled else { return }
            applyFast(fast)
            noteFirstFast(token: token)
            if !fast.isTruncated { return }

            if let body = await service.searchBody(request) {
                guard token == generation, !Task.isCancelled else { return }
                applyBody(body)
                // body 已经把三段跑完且没到上限，total 就是精确值，不必再扫一遍计数。
                if !body.isTruncated { return }
            } else {
                // 补全段失败时不要继续拿计数去改底栏：列表还只是前缀，底栏说“1000+”
                // 会让人以为包含段的结果已经进来了。保持快段的下界即可。
                return
            }
            if let count = await service.searchCount(request) {
                guard token == generation, !Task.isCancelled else { return }
                applyCount(count)
            }
            return
        }

        let response = await service.search(request)
        guard token == generation, !Task.isCancelled else { return }
        applyComplete(response)
    }

    private func applyFast(_ response: FileSearchResponse) {
        guard !response.items.isEmpty else {
            // 前缀/等值没命中，不代表包含段也没有；保留旧列表，让“搜索中”继续。
            // 但如果快段已经确定到底（通配/时间排序），空就是空，直接落空态。
            if response.isTruncated {
                isSearching = true
            } else {
                applyBody(response)
            }
            return
        }
        if response.items != items { items = response.items }
        total = response.total
        isTruncated = response.isTruncated
        totalIsExact = response.totalIsExact
        notice = response.notice
        isSearching = false
        // 快段只是最终结果的前缀：这里不裁多选集合，否则 body 追加回来的
        // 已选项会因为“暂时不在快段里”被误删。等 body/complete 再裁。
        reconcileSelection(pruneSelectedIDs: false)
    }

    private func applyBody(_ response: FileSearchResponse) {
        if response.items != items { items = response.items }
        total = response.total
        isTruncated = response.isTruncated
        totalIsExact = response.totalIsExact
        notice = response.notice
        isSearching = false
        reconcileSelection()
    }

    private func applyCount(_ response: FileSearchResponse) {
        // 计数段只动底栏；列表仍以 body 为准。
        total = response.total
        totalIsExact = response.totalIsExact
        isTruncated = !response.totalIsExact || response.total > items.count
    }

    private func applyComplete(_ response: FileSearchResponse) {
        if response.items != items { items = response.items }
        total = response.total
        isTruncated = response.isTruncated
        totalIsExact = response.totalIsExact
        notice = response.notice
        isSearching = false
        reconcileSelection()
    }

    private func reconcileSelection(pruneSelectedIDs: Bool = true) {
        selection = min(selection, max(items.count - 1, 0))
        let visibleIDs = Set(items.map(\.id))
        if pruneSelectedIDs {
            selectedIDs.formIntersection(visibleIDs)
        }
        if let anchor = selectionAnchor {
            selectionAnchor = items.isEmpty ? nil : min(anchor, items.count - 1)
        }
    }

    private func isKeywordSearch() -> Bool {
        isKeywordSearch(currentQuery)
    }

    private func isKeywordSearch(_ query: String) -> Bool {
        if case .search = FileQueryParser(aliases: FileAliasStore.shared.aliases).parse(query) {
            return true
        }
        return false
    }

    private func parsedKind() -> FileQuery {
        FileQueryParser(aliases: FileAliasStore.shared.aliases).parse(currentQuery)
    }

    /// 索引从构建中切到就绪时，用索引结果替换掉之前的 Spotlight 兜底结果。
    private func observeIndexPhase() {
        withObservationTracking {
            _ = FileIndex.shared.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeIndexPhase()
                if FileIndex.shared.isReady, self.isKeywordSearch() {
                    self.rerun()
                }
            }
        }
    }

    /// 供 LauncherView 计算高度；不依赖实际行渲染。
    var visibleRowCount: Int {
        min(max(items.count, 1), Layout.Metric.maxVisibleFileRows)
    }

    private func isSplit(panelWidth: CGFloat) -> Bool {
        settings.viewMode == .split && panelWidth >= Layout.Metric.previewBreakpoint
    }

    func contentHeight(panelWidth: CGFloat) -> CGFloat {
        let rows = Layout.listHeight(rows: visibleRowCount, verticalPadding: Layout.Spacing.s)
        let body = isSplit(panelWidth: panelWidth)
            ? max(rows, Layout.Metric.filePreviewMinHeight)
            : rows
        var height = Layout.Metric.fileChipsHeight + Layout.Metric.filePaneGap
        height += body
        height += Layout.Metric.filePaneGap + Layout.Metric.fileFooterHeight
        height += Layout.Spacing.s
        if displayNotice != nil {
            height += Layout.Metric.fileNoticeHeight + Layout.Metric.filePaneGap
        }
        return height
    }
}
