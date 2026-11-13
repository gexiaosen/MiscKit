import MiscKitCore
import SwiftUI

/// 视图被 hosting view 强持有，而 controller 又持有窗口：直接存强引用会成环
/// （controller → window → hosting view → LauncherView → controller），谁都释放不掉。
/// 视图只借用宿主，宿主活着视图才可能被渲染，所以弱引用不会真的丢。
final class PanelHandle {
    weak var panel: (any PanelControlling)?

    init(_ panel: any PanelControlling) {
        self.panel = panel
    }
}

/// 初始态只有输入框；输入后才在下方出现结果行。
/// 输入框固定 750×60 点（2x 屏 1500×120 像素）、半圆（胶囊）圆角，不随内容改变自身尺寸。
struct LauncherView: View {
    @State private var model: PanelModel
    @State private var selection: Int = 0
    @State private var commandHeld = false
    @State private var fileModel = FileSearchModel()
    @FocusState private var searchFocused: Bool

    private let panelHandle: PanelHandle
    private var panel: (any PanelControlling)? { panelHandle.panel }
    @State private var settings: AppSettings
    /// 系统的减少透明度 / 减少动态效果 / 增加对比度三个开关，见 Core 的 AccessibilityPreferences
    @State private var a11y = AccessibilityPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    private enum PinnedWorkspace: Equatable {
        case file, hosts, reminder, otp, calc
    }

    /// 点了功能入口行后钉在对应工作区，Esc 返回命令列表。
    @State private var pinnedWorkspace: PinnedWorkspace?
    /// 点了稿纸动作行后钉在计算工作区。↑↓ 与 ⌘D/⌘R 都要经它转给稿纸。
    @State private var calcModel = CalcModel()
    /// hosts 工作区的选中状态（段 / 行 / 页签），由这里持有好让 ↑↓ 能路由
    @State private var hostsModel = HostsPaneModel()
    /// OTP 工作区的选中状态，同上：`↵` 复制、`⌘↵` 编辑备注
    @State private var otpModel = OTPWorkspaceModel()
    @State private var actionError: String?
    @State private var aliasTarget: AliasTarget?
    @State private var aliasText = ""
    @State private var showingAliasEditor = false
    /// 有文件正被拖到面板上，用来画那一圈高亮
    /// 级联入场：列表刚出现时给各行递增延迟动画，窗口期过后停止递延
    @State private var rowStaggerArmed = true
    /// 列表内容的真实高度。行高不固定（词典释义会换行），面板高度只能量出来，不能按行数猜。
    @State private var listContentHeight: CGFloat = 0

    init(panel: any PanelControlling, settings: AppSettings = .shared) {
        self.panelHandle = PanelHandle(panel)
        self._settings = State(initialValue: settings)
        self._model = State(initialValue: panel.model)
    }

    private var query: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isExpanded: Bool { !query.isEmpty }

    private var isHostsMode: Bool {
        isExpanded && pinnedWorkspace == .hosts
    }

    private var isReminderMode: Bool {
        isExpanded && pinnedWorkspace == .reminder
    }

    private var isOTPMode: Bool {
        isExpanded && pinnedWorkspace == .otp
    }

    private var isCalcMode: Bool {
        isExpanded && pinnedWorkspace == .calc
    }

    /// 功能开关的唯一取数点。闸在 `ToolRegistry`，视图不许自己读 `disabledTools` 数组 ——
    /// 那样「关没关」就有了两处判，改一处另一处还当它开着。
    private func on(_ tool: ToolID) -> Bool { ToolRegistry.shared.isEnabled(tool) }

    /// 文件模式：关键词 `file`/`文件`、路径样式输入、目录别名，或用户点了「搜索文件」行。
    /// 功能被关掉时整条不成立 —— 路径输入和别名是注册表管不到的旁路，只能在这里断。
    private var isFileMode: Bool {
        let allowFiles = pinnedWorkspace == nil || pinnedWorkspace == .file
        return isExpanded && allowFiles
            && on(Self.filesToolID)
            && (pinnedWorkspace == .file || fileModel.isFileQuery(query))
    }

    private var results: [ToolResult] {
        guard isExpanded, !isFileMode, !isHostsMode, !isReminderMode, !isOTPMode,
              !isCalcMode else { return [] }
        return ToolRegistry.shared.rankedResults(for: MatchInput(text: query))
    }

    var body: some View {
        @Bindable var model = model
        let _ = settings.language

        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: isExpanded ? Layout.Metric.panelGap : 0) {
                searchField($model.query)
                if isExpanded {
                    contentArea
                }
            }
            // 固定顶边、只长下沿：窗口先一次到位，可见形状在窗口内缓动展开。
            // 逐帧改窗口会让 NSHostingView 的布局落后于 frame，输入框会跟着跳。
            .frame(width: model.panelWidth, height: model.revealHeight, alignment: .topLeading)
            // 底衬使用原生玻璃效果，不叠加多余不透明材质或遮罩。
            .background {
                // 开「降低透明度」时不能再用玻璃：HIG 要求此时窗口背景不透明。
                // 语义色本身随外观与「增加对比度」变，所以这里不手写任何色值。
                if a11y.panelShouldBeOpaque {
                    Theme.dimColor(for: colorScheme).opacity(1)
                }
            }
            .glassEffect(Theme.panelGlass, in: panelShape)
            .overlay(panelShape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .clipShape(panelShape)
            // 出现/消失由 PanelController 用整窗 alpha 统一淡出：
            // 视图层再叠一层透明度会让文字（vibrancy）与玻璃分层合成，收起前文字闪一下。
            .animation(model.isVisible ? revealAnimation : nil, value: model.revealHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.isVisible) {
            if model.isVisible {
                prefillFromClipboardIfNeeded()
                searchFocused = true
            }
        }
        // 级联入场窗口：仅在列表初次出现时触发递延渐入动画，连续输入时不再重复触发。
        .task(id: isExpanded) {
            guard isExpanded else { rowStaggerArmed = true; return }
            try? await Task.sleep(for: .seconds(Layout.Motion.staggerWindow))
            guard !Task.isCancelled else { return }
            rowStaggerArmed = false
        }
        .task(id: settings.disabledTools) {
            // 关掉正钉着的工作区要当场退出那一页：否则面板停在一张不该继续存在的页上，
            // Esc 阶梯也照旧模式退，用户看到的是「关了还能用」。
            switch pinnedWorkspace {
            case .hosts where !on(Self.hostsToolID): exitWorkspace()
            case .reminder where !on(Self.reminderToolID): exitWorkspace()
            case .otp where !on(Self.otpToolID): exitWorkspace()
            case .calc where !on(Self.calcToolID): exitWorkspace()
            case .file where !on(Self.filesToolID): exitWorkspace()
            default: break
            }
        }
        .onExitCommand {
            // 面板失焦时 AppKit 也会补一个 cancel：那时既不是用户按的 Esc，
            // 也不该退出模式（关掉了"失焦自动隐藏"更是如此）。
            guard panel?.isKeyWindow == true else {
                debugTrace("cancel ignored (not key)")
                return
            }
            debugTrace("cancel handled pinned=\(String(describing: pinnedWorkspace))")
            // 先取"按下这一刻"的读数：模型里的字数和画面里那串字的字数不一致，
            // 说明用户看到的字和阶梯判断的字不是同一份（阶梯是在模型上走的）。
            let fieldLenBefore = ((NSApp.keyWindow?.firstResponder as? NSTextView)?.string ?? "").count
            let modelLenBefore = model.query.count
            // 多选先用 Esc 清掉；从动作行进来的文件/hosts 模式再退回命令列表，最后才关闭。
            let rung: String
            if fileModel.hasMultiSelection {
                fileModel.clearMultiSelection()
                rung = "multi"
            } else if let pinnedWorkspace {
                switch pinnedWorkspace {
                case .hosts: rung = "hosts"
                case .reminder: rung = "reminder"
                case .otp: rung = "otp"
                case .calc: rung = "calc"
                case .file: rung = "file"
                }
                exitWorkspace()
            } else if !model.query.isEmpty {
                // 只剩输入框还带着字：Esc 先把字清掉回初始态，面板不关。
                // 清空会让 task(id: model.query) 把选中行归零，这里不重复设。
                model.query = ""
                rung = "clear"
            } else {
                panel?.hide()
                rung = "close"
            }
            traceEsc(rung, modelLen: modelLenBefore, fieldLen: fieldLenBefore)
        }
        // model.query 是 @Observable 属性，onChange(of:) 实测不触发；task(id:) 可靠。
        .task(id: model.query) {
            if let pinnedWorkspace, pinnedWorkspace != .file {
                if query.isEmpty {
                    exitWorkspace()
                }
                return
            }
            selection = 0
            syncFileMode(model.query)
        }
        .onAppear {
            panel?.setContentHeight(measuredHeight)
            searchFocused = true
            commandHeld = NSEvent.modifierFlags.contains(.command)
            openDebugPaneIfNeeded()
        }
        .onModifierKeysChanged(mask: .command) { _, new in
            commandHeld = new.contains(.command)
        }
        .environment(\.showsShortcutHints, commandHeld)
        .environment(\.appLanguage, settings.language)
        .environment(\.locale, settings.language.locale)
        // 同一轮输入会连着改几次高度；等 40ms 合并，窗口只拉伸一次。
        .task(id: measuredHeight) {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            panel?.setContentHeight(measuredHeight)
        }
        .background(arrowNavigation)
        .alert(L10n.Common.actionFailed, isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button(L10n.Common.ok, role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert(L10n.Launcher.Alias.title, isPresented: $showingAliasEditor) {
            TextField(L10n.Launcher.Alias.placeholder, text: $aliasText)
            Button(L10n.Common.cancel, role: .cancel) { aliasTarget = nil }
            Button(L10n.Common.save) {
                if let target = aliasTarget {
                    let values = aliasText
                        .split(whereSeparator: { $0 == "," || $0 == "，" })
                        .map(String.init)
                    AppIndex.shared.setAliases(values, for: target.appID)
                }
                aliasTarget = nil
            }
        } message: {
            Text(L10n.Launcher.Alias.message(aliasTarget?.name ?? ""))
        }
    }

    // MARK: 形状

    /// 行入场时长与级联步长：都走同一个减少动态效果/倍率出口，归零时行直接出现。
    private var rowRevealDuration: TimeInterval {
        a11y.motionDuration(Layout.Motion.rowReveal, scale: settings.motionScale)
    }

    private var staggerStepSeconds: TimeInterval {
        a11y.motionDuration(Layout.Motion.staggerStep, scale: settings.motionScale)
    }

    /// 展开曲线：起步快、收尾柔，且不过冲（窗口高度就是目标高度，过冲会被裁掉）。
    /// 开「减少动态效果」时时长归零：Apple 的清单点名要减少 zoom/scale 与撑高动画，
    /// 只留淡入 —— 缩放本身由 scaleEffect 与 0 时长共同消掉，不再单独判断。
    private var revealAnimation: Animation {
        .timingCurve(0.16, 0.92, 0.24, 1,
                     duration: a11y.motionDuration(Layout.Motion.resize, scale: settings.motionScale))
    }

    /// 收起与展开共用同一个圆角，展开时形状只沿纵向拉伸。
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.Metric.panelRadius, style: .continuous)
    }

    // MARK: 输入行

    /// 固定尺寸、无前后图标、文字左对齐且垂直居中；左边距让开半圆端头。
    /// 自定义绘制提示词：避免系统 TextField placeholder 随视口滚动被移出可见范围。
    /// 字号放在容器上：两层共用同一个字号，提示词与输入文字之间不会错位。
    private func searchField(_ binding: Binding<String>) -> some View {
        ZStack(alignment: .leading) {
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .padding(.leading, Layout.Metric.barTextInset)
                .padding(.trailing, Layout.Metric.barTextInset)
                .focused($searchFocused)
                .onSubmit { performCurrentSelection() }
                .accessibilityLabel(settings.placeholderText)
            if binding.wrappedValue.isEmpty {
                hintLayer
            }
        }
        .font(.system(size: 22, weight: .regular))
        .frame(width: model.panelWidth, height: Layout.Metric.barHeight, alignment: .leading)
    }

    /// 绑定为空不等于输入栏无内容：输入法组合拼音阶段仅存在于字段编辑器中，需结合 fieldEditor 判定以避免提示词与拼音重叠。
    private var hintLayer: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if fieldEditor?.string.isEmpty ?? true {
                Text(settings.placeholderText)
                    .padding(.leading, Layout.Metric.barTextInset)
                    .padding(.trailing, Layout.Metric.barTextInset)
                    .foregroundStyle(Theme.searchHint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: 结果区

    /// 内容区形态：只用来给"换工作区"一个共同节拍，不参与路由判断。
    private enum ContentMode: Equatable {
        case results, empty, hosts, reminder, otp, calc, files
    }

    private var contentMode: ContentMode {
        if isHostsMode { return .hosts }
        if isReminderMode { return .reminder }
        if isOTPMode { return .otp }
        if isCalcMode { return .calc }
        if isFileMode { return .files }
        return results.isEmpty ? .empty : .results
    }

    private var workspaceAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.workspaceSwitch, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }

    @ViewBuilder
    private var contentArea: some View {
        contentBody
            // 面包屑：换内容形态时留一条状态快照（频率低，只在真正换页时触发）
            .task(id: contentMode) {
                Breadcrumbs.event("panel.mode", [
                    "mode": String(describing: contentMode),
                    "queryLen": String(query.count),
                    "results": String(results.count),
                    "selection": String(selection),
                    "visible": model.isVisible ? "1" : "0",
                    "reveal": String(format: "%.0f", model.revealHeight),
                ])
            }
            // 换工作区时新旧内容短暂共存：新内容淡入并上移 4pt，旧内容淡出
            .id(contentMode)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: Layout.Spacing.xs)),
                removal: .opacity))
            .animation(workspaceAnimation, value: contentMode)
    }

    @ViewBuilder
    private var contentBody: some View {
        if isHostsMode {
            HostsPane(store: HostsStore.shared, model: hostsModel)
        } else if isReminderMode {
            ReminderPane()
        } else if isOTPMode {
            OTPPane(model: otpModel)
        } else if isCalcMode {
            CalcPane(model: calcModel)
        } else if isFileMode {
            FileSearchPane(model: fileModel,
                           panelWidth: model.panelWidth,
                           onAction: { action in execute(action) })
        } else if results.isEmpty {
            Text(L10n.Launcher.noMatch)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.Spacing.xl)
                .frame(height: Layout.Metric.rowHeightCompact)
        } else {
            // 可视区只有 8 行，结果上限是 30 行：方向键必须把选中项滚进视口，
            // 否则第 9 行起"选中的是看不见的东西"。anchor 不传（默认 nil），
            // 交给 SwiftUI 滚到刚好露出；传 .center 会让每一下都重新居中，画面乱跳。
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.Metric.rowSpacing) {
                        ForEach(Array(results.enumerated()), id: \.element.key) { index, result in
                            ResultRow(result: result, isSelected: index == selection, index: index) {
                                selection = index
                                perform(result)
                            }
                            .id(result.key)
                            .modifier(RowReveal(
                                delay: {
                                    guard rowStaggerArmed else { return nil }
                                    return Double(min(index, 8)) * staggerStepSeconds
                                },
                                duration: rowRevealDuration,
                                offset: Layout.Spacing.xs))
                            .contextMenu { rowContextMenu(for: result) }
                        }
                    }
                    .padding(.horizontal, Layout.Metric.listInset)
                    .padding(.bottom, Layout.Metric.listBottomInset)
                    // 词典等多行结果行高不固定，测量真实内容高度自适应，超出上限后再允许滚动。
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        listContentHeight = height
                    }
                }
                .frame(height: rowAreaHeight, alignment: .top)
                .scrollIndicators(.hidden)
                .onChange(of: selection) { _, target in
                    guard results.indices.contains(target) else { return }
                    proxy.scrollTo(results[target].key)
                }
            }
        }
    }

    /// 唤起时带入 5 秒内复制的新剪贴板内容。
    /// 冲突规则：以面板现有内容为主，剪贴板预填不覆盖已有输入。
    private func prefillFromClipboardIfNeeded() {
        guard settings.prefillFromClipboard else { return }
        // 同步补看一次剪贴板：轮询是 1 秒一拍，复制后立刻唤起时上一拍还没观测到这次变化，
        // 会被当成"年龄未知/太旧"而漏带；补这一拍后第一次唤出就能带上。
        ClipboardWatch.shared.poll()
        if let text = ClipboardWatch.shared.prefillText(
            barIsInitial: model.query.isEmpty && pinnedWorkspace == nil) {
            Breadcrumbs.event("panel.prefill", ["len": String(text.count)])
            model.query = text
        }
    }

    /// 方向键走无修饰键的按钮绑定：TextField 会吃掉 ↑↓，按钮不会。
    private var arrowNavigation: some View {
        VStack(spacing: 0) {
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .accessibilityHidden(true)
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .accessibilityHidden(true)
            Button("") { revealSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHidden(true)
            if isFileMode {
                // ⌘C / ⌘A 先让给输入框：有选中文字时是"复制文字"，有输入文字时是"全选文字"；
                // 没有可作用的文字才落到文件上。否则这两个键会被隐藏按钮全局劫持，
                // 文件搜索时连选中输入框里的字都做不到。
                Button("") { copyWithTextPriority() }
                    .keyboardShortcut("c", modifiers: .command)
                    .accessibilityHidden(true)
                Button("") { selectAllWithTextPriority() }
                    .keyboardShortcut("a", modifiers: .command)
                    .accessibilityHidden(true)
                // 输入框里永远可能有字，文件全选需要一个专属出口
                Button("") { fileModel.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func revealSelection() {
        if isHostsMode {
            // ⌘↵ = 勾选/取消该段，或临时禁用/恢复该行。关基座仍走视图里的二次确认。
            // 关基座要二次确认：模型挂 requestBaseOff，HostsPane 复用它已有的确认框
            _ = hostsModel.toggleFocused(store: HostsStore.shared)
            return
        }
        if isOTPMode {
            // ⌘↵ = 编辑备注（无害）。**删除不挂任何快捷键**：它要连钥匙串一起抹掉、
            // 且不可恢复，不该挂在最顺手的组合键上 —— 与 hosts「应用」同一条原则。
            _ = otpModel.requestNote(in: OTPStore.shared)
            return
        }
        if isFileMode {
            guard let item = fileModel.selectedItem else { return }
            execute(.openInTerminal(item.url))
            return
        }
        guard results.indices.contains(selection), let url = results[selection].iconURL else { return }
        Task { @MainActor in
            do {
                try await ActionDispatcher.perform(.reveal(url))
                panel?.hide()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// 输入框（field editor）优先：
    /// - ⌘C：有选中文字就复制文字，否则拷贝文件本身（与右键「拷贝」同一条判定，多选整组）；
    /// - ⌘A：输入框有文字就全选文字，为空时全选文件。
    private var fieldEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private func copyWithTextPriority() {
        if let editor = fieldEditor, editor.selectedRange().length > 0 {
            editor.copy(nil)
        } else {
            copySelectedFiles()
        }
    }

    private func selectAllWithTextPriority() {
        if let editor = fieldEditor, !editor.string.isEmpty {
            editor.selectAll(nil)
        } else {
            fileModel.selectAll()
        }
    }

    private func copySelectedFiles() {
        let targets = fileModel.keyboardCopyTargets()
        guard !targets.isEmpty else { return }
        execute(.copyItems(targets.map(\.url)))
    }

    private func move(_ delta: Int) {
        if isCalcMode {
            calcModel.move(delta)
            return
        }
        if isHostsMode {
            // 段列表走行选段、段内容页走行选行；跳过空行，否则 ↑↓ 会停在没信息的位置
            hostsModel.move(by: delta, store: HostsStore.shared)
            return
        }
        if isReminderMode { return }
        if isOTPMode {
            otpModel.move(by: delta, in: OTPStore.shared)
            return
        }
        if isFileMode {
            fileModel.move(delta)
            return
        }
        selection = ListSelection.move(current: selection, delta: delta, count: results.count)
    }

    private func syncFileMode(_ raw: String) {
        if let pinnedWorkspace, pinnedWorkspace != .file {
            fileModel.deactivate()
            return
        }
        // 「文件」关掉后连查询都不该再发：界面看不见它，索引却在每次击键后跑一遍，
        // 那既不是"关掉了"，也白占 130ms 防抖后的那次搜索。
        guard on(Self.filesToolID) else {
            fileModel.deactivate()
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if pinnedWorkspace == .file { pinnedWorkspace = nil }
            fileModel.deactivate()
            return
        }
        if pinnedWorkspace == .file || fileModel.isFileQuery(trimmed) {
            fileModel.update(query: trimmed)
        } else {
            fileModel.deactivate()
        }
    }

    private func enterWorkspace(_ target: PinnedWorkspace) {
        debugTrace("enter \(target)")
        pinnedWorkspace = target
        selection = 0
        if target == .file {
            fileModel.update(query: query)
        } else {
            fileModel.deactivate()
        }
        // 点击按钮后把焦点还给输入框，用户不用再点一次才能继续输入。
        searchFocused = true
    }

    private func exitWorkspace() {
        debugTrace("exit \(String(describing: pinnedWorkspace))")
        if pinnedWorkspace == .file {
            fileModel.deactivate()
        } else if pinnedWorkspace == .otp {
            // 下次进来从第一条开始，不停在已经不存在或看不见的选中项上
            otpModel.clear()
        }
        pinnedWorkspace = nil
        selection = 0
    }

    /// 验收用：把模式切换的因果打到 stderr，只在 DEBUG 下且 MISCKIT_DEBUG 置位时出声。
    private func debugTrace(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MISCKIT_DEBUG"] != nil else { return }
        FileHandle.standardError.write("launcher \(message)\n".data(using: .utf8)!)
        #endif
    }

    /// Esc 阶梯的每一级都留一条读数：走了哪一级，以及按下这一刻模型里的字数、画面里那串字的字数。
    /// `rung=close` 而 `fieldLen>0` ⇒ 模型早空了、画面上还是旧字（"文字清不掉""placeholder 不见了"）；
    /// 两个长度一致却直接关闭 ⇒ 阶梯本身少了一级。
    private func traceEsc(_ rung: String, modelLen: Int, fieldLen: Int) {
        Breadcrumbs.event("panel.esc", [
            "rung": rung,
            "modelLen": String(modelLen),
            "fieldLen": String(fieldLen),
        ])
    }

    /// 验收用：`MISCKIT_DEBUG_OPEN_PANE=hosts|reminder` 让面板一出现就停在对应工作区。
    private func openDebugPaneIfNeeded() {
        #if DEBUG
        guard let pane = ProcessInfo.processInfo.environment["MISCKIT_DEBUG_OPEN_PANE"] else { return }
        switch pane {
        case "hosts":
            model.query = "hosts"
            pinnedWorkspace = .hosts
        case "reminder":
            model.query = ReminderTool.openQuery
            pinnedWorkspace = .reminder
        case "otp":
            model.query = OTPTool.openQuery
            pinnedWorkspace = .otp
        case "file":
            model.query = "file"
            pinnedWorkspace = .file
        case "calc":
            model.query = CalcTool.openQuery
            pinnedWorkspace = .calc
        default:
            break
        }
        #endif
    }

    // MARK: 高度与动作

    private var rowAreaHeight: CGFloat {
        guard !results.isEmpty else {
            return Layout.Metric.rowHeightCompact + Layout.Metric.listBottomInset
        }
        // 一条规则管所有列表：最多 8 行高，内容短就贴着内容长，不按结果类型开特例。
        let maxHeight = Layout.listHeight(rows: Layout.Metric.maxVisibleRows)
        guard listContentHeight > 0 else { return maxHeight }
        return min(listContentHeight, maxHeight)
    }

    /// 输入框恒为 barHeight；展开只是往下长，不改输入框本身。
    /// 列表内容自带 8pt 底边，面板不再额外加下半段间距，选中态才能和四角同心。
    private var measuredHeight: CGFloat {
        guard isExpanded else { return Layout.Metric.barHeight }
        if isHostsMode {
            return Layout.Metric.barHeight + Layout.Metric.panelGap + HostsPane.contentHeight
        }
        if isReminderMode {
            return Layout.Metric.barHeight + Layout.Metric.panelGap + ReminderPane.contentHeight
        }
        if isOTPMode {
            return Layout.Metric.barHeight + Layout.Metric.panelGap + OTPPane.contentHeight
        }
        if isCalcMode {
            return Layout.Metric.barHeight + Layout.Metric.panelGap + CalcPane.contentHeight
        }
        let content = isFileMode ? fileModel.contentHeight(panelWidth: model.panelWidth) : rowAreaHeight
        return Layout.Metric.barHeight + Layout.Metric.panelGap + content
    }

    private func performCurrentSelection() {
        if isHostsMode {
            // ↵ = 进入下一层：段列表里展开该段，段内容页里编辑该行。
            // 「应用 hosts」不挂任何快捷键 —— 它要管理员授权，不该是最顺手的那个键。
            // 要开编辑框的情况由模型自己挂 requestLineEditor，HostsPane 观察后弹窗
            _ = hostsModel.activate(store: HostsStore.shared)
            return
        }
        if isReminderMode { return }
        if isOTPMode {
            // ↵ = 执行 = 复制选中那条的验证码（与点一下同一动作）
            _ = otpModel.requestCopy(in: OTPStore.shared)
            return
        }
        if isCalcMode {
            _ = calcModel.addRowAfterFocused()
            return
        }
        if isFileMode {
            guard let item = fileModel.selectedItem else { return }
            execute(fileModel.primaryAction(for: item))
            return
        }
        guard results.indices.contains(selection) else { return }
        perform(results[selection])
    }

    private func perform(_ result: ToolResult) {
        // 别名编辑要开面板内的编辑框，不是外部动作（与 openTool 同一条路）。
        if case .editAppAlias(let appID) = result.action {
            beginAliasEdit(appID: appID,
                           name: AppIndex.shared.app(withID: appID)?.name ?? result.subtitle)
            return
        }
        // 「设定音量…」「gh 」这类把话接回输入框，不离开面板。
        if case .prefillQuery(let text) = result.action {
            model.query = text
            searchFocused = true
            return
        }
        // 「搜索文件」「Hosts」「提醒」不是外部动作：留在同一个面板里换内容区。
        if case .openTool(let target) = result.action {
            // 面板有 120 秒的状态窗口：功能在设置里被关掉之后，旧的那一行还可能留在屏上。
            guard on(target) else { return }
            if result.toolID == Self.filesToolID {
                enterWorkspace(.file)
                return
            }
            if result.toolID == Self.hostsToolID {
                enterWorkspace(.hosts)
                return
            }
            if result.toolID == Self.reminderToolID {
                enterWorkspace(.reminder)
                return
            }
            if result.toolID == Self.otpToolID {
                enterWorkspace(.otp)
                return
            }
            if result.toolID == Self.calcToolID {
                enterWorkspace(.calc)
                return
            }
        }
        execute(result.action)
    }

    private static let filesToolID = ToolID.files
    private static let hostsToolID = ToolID.hosts
    private static let reminderToolID = ToolID.reminder
    private static let otpToolID = ToolID.otp
    private static let calcToolID = ToolID.calc

    private func execute(_ action: ToolAction) {
        let dismisses = action.dismissesPanel
        // 先收面板再执行：拉起/打开这类动作现在要盯 1 秒确认目标没秒退，让它挡在收起
        // 动画前面就变成"回车后窗口赖着不走、输入框先灰掉"。失败时再把面板叫回来说话。
        if dismisses { panel?.hide() }
        Task { @MainActor in
            do {
                try await ActionDispatcher.perform(action)
                guard dismisses else { return }
                scheduleQueryReset()
            } catch {
                actionError = error.localizedDescription
                if dismisses { panel?.show() }
            }
        }
    }

    /// 关掉之后再清空，否则收起动画会连带把面板高度突然抽走。
    private func scheduleQueryReset() {
        Task { @MainActor in
            let delay = a11y.motionDuration(Layout.Motion.dismiss, scale: settings.motionScale) + 0.05
            try? await Task.sleep(for: .seconds(delay))
            guard !model.isVisible else { return }
            model.query = ""
            selection = 0
        }
    }

    @ViewBuilder
    private func rowContextMenu(for result: ToolResult) -> some View {
        // 会议号行右键给「拷贝会议号」，再挂通用动作。
        if case .joinMeeting(let code) = result.action {
            Button(L10n.Launcher.Context.copyMeeting) { execute(.copy(code)) }
            Divider()
        }
        // 词典行点一下就进词典.app；要文字就右键拷释义，否则 Enter 被跳转占掉后没地方拿全文。
        if case .openDictionary = result.action, let detail = result.detail, !detail.isEmpty {
            Button(L10n.Launcher.Context.copyDefinition) { execute(.copy(detail)) }
            Divider()
        }
        // 动作清单与输入框「对象 动作词」共用 RowActionCatalog：这里再手写一遍，
        // 新加的动作就会只在其中一个入口出现。
        if let app = appTarget(of: result) {
            let running = RowActionCatalog.RunningSnapshot()
            let actions = RowActionCatalog.available(isRunning: running.contains(app))
            ForEach(actions, id: \.code) { action in
                if action.code == "alias" { Divider() }
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    performRowAction(action, on: app)
                }
            }
        } else {
            Button(L10n.Launcher.Context.execute) { perform(result) }
        }
    }

    /// 应用行与它派生的动作行都指向同一个 App。
    private func appTarget(of result: ToolResult) -> InstalledApp? {
        let appID: String?
        switch result.action {
        case .launchApp(_, let id), .editAppAlias(let id), .quitApp(let id),
             .forceQuitApp(let id), .relaunchApp(_, let id):
            appID = id
        default:
            appID = nil
        }
        return appID.flatMap { AppIndex.shared.app(withID: $0) }
    }

    private func performRowAction(_ action: RowAction, on app: InstalledApp) {
        let toolAction = RowActionCatalog.toolAction(action.code, for: app)
        if case .editAppAlias(let appID) = toolAction {
            beginAliasEdit(appID: appID, name: app.name)
            return
        }
        execute(toolAction)
    }

    private func beginAliasEdit(appID: String, name: String) {
        aliasTarget = AliasTarget(appID: appID, name: name)
        aliasText = AppIndex.shared.aliases(for: appID).joined(separator: ", ")
        showingAliasEditor = true
    }
}

private struct AliasTarget {
    let appID: String
    let name: String
}
