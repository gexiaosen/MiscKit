import MiscKitCore
import SwiftUI

/// 计算稿纸工作区。排版照参照图：左边一行一式子、结果右对齐大号，
/// 右边是张列表（默认按日期时间命名），底部一条工具条。
struct CalcPane: View {
    static let contentHeight: CGFloat = 420
    private static let sheetListWidth: CGFloat = 168

    @Environment(\.appLanguage) private var appLanguage
    @State private var model: CalcModel
    @State private var store: CalcStore
    @State private var renameTarget: CalcSheet?
    @State private var renameText = ""
    @State private var notice: String?
    @State private var errorNotice: String?
    @State private var noticeTask: Task<Void, Never>?
    /// 张列表看哪一堆。归档过的张只在 `archived` 这一列里出现，
    /// 所以这个开关是"取消归档"的唯一入口。
    @State private var listing: Listing = .active
    @State private var searchTerm = ""
    @FocusState private var focusedRow: UUID?

    enum Listing { case active, archived }

    init(model: CalcModel = CalcModel()) {
        _model = State(initialValue: model)
        _store = State(initialValue: model.store)
    }

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: Layout.Spacing.s) {
            HStack(alignment: .top, spacing: Layout.Spacing.m) {
                rows
                sheetList
            }
            .frame(maxHeight: .infinity)
            Divider()
            toolbar
        }
        .padding(.horizontal, Layout.Spacing.l)
        .padding(.vertical, Layout.Spacing.s)
        .frame(height: Self.contentHeight, alignment: .top)
        .background(keyboardLayer)
        .onChange(of: model.focusedRowID) { _, new in
            if let new { focusedRow = new }
        }
        .onChange(of: focusedRow) { _, new in
            if let new { model.focus(new) }
        }
        .alert(L10n.Calc.renameTitle, isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(L10n.Calc.namePlaceholder, text: $renameText)
            Button(L10n.Common.cancel, role: .cancel) { renameTarget = nil }
            Button(L10n.Common.save) {
                if let target = renameTarget { store.rename(target.id, to: renameText) }
                renameTarget = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.successText)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Theme.successFill, in: Capsule())
                    .padding(.bottom, 44)
                    .transition(.opacity)
            } else if let failure = errorNotice ?? store.lastError {
                // 存盘与剪贴板失败以前没人看得见，用户只会以为"没保存上是我的错"
                Text(failure)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.errorText)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Theme.errorFill, in: Capsule())
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
    }

    /// ⌘D 复制结果、⌘R 删行（可撤销）。跟方向键一样走隐藏按钮：
    /// TextField 会吃掉键盘事件，按钮绑定不会。
    private var keyboardLayer: some View {
        VStack(spacing: 0) {
            Button("") {
                if case .failed = model.copyFocusedResult() {
                    showErrorNotice(L10n.Actions.clipboardFailed)
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .accessibilityHidden(true)
            Button("") { model.deleteFocused() }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityHidden(true)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: 左侧：行

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.Metric.rowSpacing) {
                    ForEach(model.rows) { row in
                        CalcRowView(row: row, store: store,
                                    isFocused: model.focusedRowID == row.id) {
                            _ = model.addRowAfterFocused()
                        }
                            .id(row.id)
                            .focused($focusedRow, equals: row.id)
                            .onTapGesture { model.focus(row.id) }
                    }
                }
                .padding(.vertical, Layout.Spacing.xs)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.focusedRowID) { _, new in
                if let new { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    // MARK: 右侧：张列表

    private var sheetList: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
            if listing == .active {
                TextField(L10n.Calc.searchPlaceholder, text: $searchTerm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, Layout.Spacing.s)
                    .frame(height: 22)
                    .background(Theme.previewFill,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(L10n.Calc.archivedHeader(store.archivedSheets.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, Layout.Spacing.s)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.Metric.rowSpacing) {
                    ForEach(listedSheets) { sheet in
                        sheetRow(sheet)
                    }
                    if listedSheets.isEmpty {
                        Text(listing == .archived ? L10n.Calc.emptyArchived : L10n.Calc.emptyMatching)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textBody)
                            .padding(.horizontal, Layout.Spacing.s)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            if listing == .active {
                Button {
                    store.newSheet()
                    model.focus(store.selectedSheet?.rows.first?.id ?? UUID())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L10n.Calc.newSheet)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Button {
                listing = listing == .archived ? .active : .archived
                searchTerm = ""
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: listing == .archived ? "chevron.left" : "archivebox")
                        .font(.system(size: 10, weight: .semibold))
                    Text(listing == .archived ? L10n.Calc.backToActive : L10n.Calc.archivedButton(store.archivedSheets.count))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(listing == .active && store.archivedSheets.isEmpty)
        }
        .frame(width: Self.sheetListWidth, alignment: .leading)
    }

    /// 搜索走 `CalcStore.sheet(matching:)`（名字或任一行的式子），空词就是全部在用张。
    private var listedSheets: [CalcSheet] {
        listing == .archived ? store.archivedSheets : store.sheet(matching: searchTerm)
    }

    private func sheetRow(_ sheet: CalcSheet) -> some View {
        let isSelected = sheet.id == store.selectedSheetID
        return Button {
            store.selectedSheetID = sheet.id
            model.focus(sheet.rows.first?.id)
        } label: {
            Text(sheet.name)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(isSelected ? Theme.tileText : Theme.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, Layout.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .modifier(SelectedRowGlass(selected: isSelected,
                                   cornerRadius: Layout.concentric(8, inset: 0)))
        .contextMenu {
            Button(L10n.Calc.rename) {
                renameTarget = sheet
                renameText = sheet.name
            }
            Button(sheet.archived ? L10n.Calc.unarchive : L10n.Calc.archive) {
                store.setArchived(sheet.id, !sheet.archived)
            }
            Divider()
            Button(L10n.Calc.deleteSheet, role: .destructive) { store.delete(sheet.id) }
        }
    }

    // MARK: 底部工具条

    private var toolbar: some View {
        HStack(spacing: Layout.Spacing.m) {
            Button(L10n.Calc.clearRows) {
                guard let id = store.selectedSheetID else { return }
                store.clearRows(of: id)
                model.focus(store.selectedSheet?.rows.first?.id)
            }
            Button(L10n.Calc.rename) {
                guard let sheet = store.selectedSheet else { return }
                renameTarget = sheet
                renameText = sheet.name
            }
            Button(L10n.Calc.copySheet) { copyAll() }
            Button(L10n.Calc.undoDelete) {
                model.undoDelete()
            }
            .disabled(!store.canUndoRow)

            Spacer(minLength: Layout.Spacing.s)

            Picker(L10n.Calc.decimals, selection: $store.scale) {
                ForEach(CalcScale.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .id("picker-calc-scale-\(appLanguage.resolved.rawValue)")

            Toggle(L10n.Calc.grouping, isOn: $store.groupingEnabled)
                .toggleStyle(.button)
                .controlSize(.small)
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .frame(height: 26)
    }

    private func copyAll() {
        guard let sheet = store.selectedSheet else { return }
        let text = store.plainText(of: sheet)
        guard !text.isEmpty else { return }
        guard ClipboardGuard.shared.write(text) else {
            showErrorNotice(L10n.Actions.clipboardFailed)
            return
        }
        errorNotice = nil
        notice = L10n.Calc.copiedSheet(text.split(separator: "\n").count)
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private func showErrorNotice(_ message: String) {
        notice = nil
        errorNotice = message
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            errorNotice = nil
        }
    }
}

/// 一行：上面是式子输入，下面是右对齐的结果或错误。错误时把出错那个字符染红。
private struct CalcRowView: View {
    let row: CalcRow
    let store: CalcStore
    let isFocused: Bool

    @Environment(\.appLanguage) private var appLanguage
    @State private var settings = AppSettings.shared
    @State private var a11y = AccessibilityPreferences.shared

    /// 结果跟着输入实时变：数字滚动交代"新值到位"，快速连续输入时由动画系统自行合并
    private var rollAnimation: Animation? {
        let duration = a11y.motionDuration(Layout.Motion.numericRoll, scale: settings.motionScale)
        return duration > 0 ? .easeOut(duration: duration) : nil
    }
    var addRow: (() -> Void)?

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 2) {
            TextField(L10n.Calc.expressionPlaceholder, text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 17, design: .rounded))
                .lineLimit(1)
                // ↵ 在下一行接着写，不用先挪光标
                .onSubmit { addRow?() }
            resultLine
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Layout.SpacingValue.rowPadding)
        .frame(minHeight: 56, alignment: .leading)
        .background(isFocused ? Theme.previewFill : .clear,
                    in: RoundedRectangle(cornerRadius: Layout.Metric.rowCornerRadius,
                                         style: .continuous))
        .contentShape(Rectangle())
        // 表达式出错的那一下抖一抖：只在出错瞬间和换错误时抖，同一条错误反复敲键不再抖；
        // 非焦点行不抖，免得整张纸一起晃。「式子没写完」属于打字过程，不算错误、不抖。
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: shakeMessage) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                if isFocused, shakeStep > 0 {
                    LinearKeyframe(-3, duration: shakeStep)
                    LinearKeyframe(3, duration: shakeStep * 1.2)
                    LinearKeyframe(-2, duration: shakeStep)
                    LinearKeyframe(0, duration: shakeStep)
                } else {
                    LinearKeyframe(0, duration: 0.001)
                }
            }
        }
    }

    /// 值得抖的错误文案：完整的错误才抖；写了一半（没写完/少个数/括号没闭合）不抖。
    /// 用文案当触发值：同一错误不重复抖。
    private var shakeMessage: String? {
        let expression = row.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty,
              case .failure(let issue) = CalcEvaluator.evaluate(expression),
              !issue.isIncompleteInput else { return nil }
        return issue.message
    }

    private var shakeStep: TimeInterval {
        a11y.motionDuration(Layout.Motion.errorShake, scale: settings.motionScale)
    }

    private var binding: Binding<String> {
        Binding(get: { row.expression },
                set: { store.updateRow(row.id, expression: $0) })
    }

    @ViewBuilder
    private var resultLine: some View {
        let expression = row.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if expression.isEmpty {
            Text("=")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.decorationOnly)
        } else if case .success(let value) = CalcEvaluator.evaluate(expression) {
            let text = CalcFormat.string(value, scale: store.scale, grouping: store.groupingEnabled)
            HStack(spacing: 6) {
                Text("=")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.decorationOnly)
                Text(text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.tileText)
                    .contentTransition(.numericText())
                    .animation(rollAnimation, value: text)
            }
        } else if case .failure(let issue) = CalcEvaluator.evaluate(expression) {
            HStack(spacing: 6) {
                markedExpression(issue)
                Text(issue.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.errorText)
                    .lineLimit(1)
            }
        }
    }

    /// 把出错的那个字符单独染色，长式子里不用再数第几位。
    private func markedExpression(_ issue: CalcIssue) -> Text {
        let characters = Array(row.expression)
        guard !characters.isEmpty else { return Text("") }
        let index = min(max(issue.offset, 0), characters.count - 1)
        let head = String(characters[..<index])
        let hit = String(characters[index])
        let tail = index + 1 < characters.count ? String(characters[(index + 1)...]) : ""
        return Text("\(Text(head).foregroundStyle(Theme.secondaryText))\(Text(hit).foregroundStyle(Theme.errorText))\(Text(tail).foregroundStyle(Theme.secondaryText))")
    }
}
