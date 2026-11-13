import Foundation
import Observation

/// HostsPane 的"选中在哪儿"。单独成模是因为 **↑↓ 只能在 `LauncherView.move()` 里路由**：
/// `arrowNavigation` 已经绑了无修饰方向键，pane 里再放一个隐藏按钮就是同一个快捷键两个
/// handler，行为未定义。而 `move()` 要能改段/行的选中，状态就得放在它拿得到的地方。
///
/// 形状照 `CalcModel` / `FileSearchModel`：由 `LauncherView` 持有，传进 pane。
///
/// 放在 MiscKitCore 而不是 UI target：`CalcModel`/`FileSearchModel` 都在 UI 侧，结果导航逻辑
/// 一行都测不到 —— 而"跳过空行""下标夹住""段/行两层切换"恰恰是错了不崩、只是默默难用的那类。
@MainActor
@Observable
public final class HostsPaneModel {
    public init() {}
    public enum Zone { case sections, lines }

    public var tab: HostsTab = .effective
    public var selectedSectionID: UUID?
    public var selectedLineIndex: Int?

    /// 键盘触发的"要开哪个弹窗"。放模型里而不是回传给 LauncherView：
    /// LauncherView 只管把键路由过来，弹窗本来就是 HostsPane 的东西。
    public var requestLineEditor: LineEditorRequest?
    public var requestBaseOff: HostsSection?

    /// 键盘当前落在哪一层：段内容页走行，其余走段列表。
    public var zone: Zone { tab == .content ? .lines : .sections }

    // MARK: 取当前可导航的集合

    private func sections(_ store: HostsStore) -> [HostsSection] { store.sections }

    private func selected(_ store: HostsStore) -> HostsSection? {
        if let id = selectedSectionID, let match = sections(store).first(where: { $0.id == id }) {
            return match
        }
        return sections(store).first
    }

    /// 段内容页里可导航的行：跳过空行 —— 空行既不能禁用也没有信息，
    /// 让 ↑↓ 停在空行上只会让人觉得键盘坏了。
    private func navigableLines(_ store: HostsStore) -> [Int] {
        guard let section = selected(store) else { return [] }
        return section.lines.enumerated()
            .filter { !HostsLineParser.parse($0.element).isBlank }
            .map(\.offset)
    }

    // MARK: 键盘动作

    @discardableResult
    public func move(by delta: Int, store: HostsStore) -> Bool {
        switch zone {
        case .sections:
            let list = sections(store)
            guard !list.isEmpty else { return false }
            let current = selectedSectionID.flatMap { id in list.firstIndex { $0.id == id } }
                ?? (delta > 0 ? -1 : 0)
            let target = ListSelection.move(current: current, delta: delta, count: list.count)
            guard list[target].id != selectedSectionID else { return true }
            selectedSectionID = list[target].id
            selectedLineIndex = nil
            return true
        case .lines:
            let indices = navigableLines(store)
            guard !indices.isEmpty else { return false }
            let current = selectedLineIndex.flatMap { idx in indices.firstIndex(of: idx) }
                ?? (delta > 0 ? -1 : 0)
            let target = ListSelection.move(current: current, delta: delta, count: indices.count)
            selectedLineIndex = indices[target]
            return true
        }
    }

    /// `↵` / `→`：段列表里展开该段；段内容页里编辑该行。
    /// 返回 false 表示没有可编辑的行（比如光标还没落到任何行上）。
    public func activate(store: HostsStore) -> ActivateOutcome {
        switch zone {
        case .sections:
            guard let section = selected(store) else { return .nothing }
            selectedSectionID = section.id
            tab = .content
            selectedLineIndex = navigableLines(store).first
            return .openedSection(section.name)
        case .lines:
            guard let section = selected(store), let index = selectedLineIndex,
                  section.lines.indices.contains(index) else { return .nothing }
            requestLineEditor = LineEditorRequest(sectionID: section.id, index: index,
                                                  line: section.lines[index])
            return .editLine(sectionID: section.id, index: index, line: section.lines[index])
        }
    }

    /// `⌘`：勾选/取消该段，或临时禁用/恢复该行。
    /// 关基座要二次确认，所以这里只回一个 `.needsBaseConfirm`，由视图决定弹什么。
    public func toggleFocused(store: HostsStore) -> ToggleOutcome {
        switch zone {
        case .sections:
            guard let section = selected(store) else { return .nothing }
            if section.isBase && section.isEnabled {
                requestBaseOff = section
                return .needsBaseConfirm(section)
            }
            store.setSectionEnabled(section.id, enabled: !section.isEnabled)
            return .toggled(name: section.name, enabled: !section.isEnabled)
        case .lines:
            guard let section = selected(store), let index = selectedLineIndex else { return .nothing }
            // 先算出"操作完之后是什么状态"再落盘：section 是值类型拷贝，
            // 切换之后再读它拿到的是旧值，靠命名绕过去迟早读错。
            let willBeEnabled = section.disabledLines.contains(index)
            store.toggleLine(sectionID: section.id, lineIndex: index)
            return .toggledLine(index: index, enabled: willBeEnabled)
        }
    }

    /// `←`：段内容页退回段列表；已经在段列表就交回给 LauncherView 退出 hosts 模式。
    @discardableResult
    public func collapse() -> Bool {
        guard tab == .content else { return false }
        tab = .effective
        selectedLineIndex = nil
        return true
    }

    public struct LineEditorRequest: Equatable {
        public let sectionID: UUID
        public let index: Int
        public let line: String
    }

    public enum ActivateOutcome {
        case nothing
        case openedSection(String)
        case editLine(sectionID: UUID, index: Int, line: String)
    }

    public enum ToggleOutcome {
        case nothing
        case needsBaseConfirm(HostsSection)
        case toggled(name: String, enabled: Bool)
        case toggledLine(index: Int, enabled: Bool)
    }
}


public enum HostsTab: String, CaseIterable, Identifiable {
    case effective
    case content
    case diff

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .effective: return L10n.Hosts.Tab.effective
        case .content: return L10n.Hosts.Tab.content
        case .diff: return L10n.Hosts.Tab.diff
        }
    }
}
