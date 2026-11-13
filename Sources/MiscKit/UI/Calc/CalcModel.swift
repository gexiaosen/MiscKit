import AppKit
import MiscKitCore
import Observation
import SwiftUI

/// 稿纸工作区的交互状态：焦点在哪一行、下一步 ↑↓ 去哪里。
/// 数据本身仍在 `CalcStore`，这里只管"当前这张的选中行"。
@MainActor
@Observable
final class CalcModel {
    var focusedRowID: UUID?
    private(set) var store: CalcStore

    init(store: CalcStore = .shared) {
        self.store = store
        focusedRowID = store.selectedSheet?.rows.first?.id
    }

    var rows: [CalcRow] { store.selectedSheet?.rows ?? [] }

    var selectedIndex: Int? {
        guard let id = focusedRowID else { return nil }
        return rows.firstIndex { $0.id == id }
    }

    func focus(_ id: UUID?) { focusedRowID = id }

    /// ↑↓ 在行之间走；到底了就补一行，稿纸不该有"走不动"的边界。
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let current = selectedIndex ?? (delta < 0 ? rows.count - 1 : 0)
        let target = current + delta
        if target < 0 {
            focusedRowID = rows[0].id
            return
        }
        if target >= rows.count {
            let row = store.insertRow(after: rows.last?.id)
            focusedRowID = row.id
            return
        }
        focusedRowID = rows[target].id
    }

    /// ↵ 在当前行之后插入并聚焦，跟手写稿纸的直觉一致。
    @discardableResult
    func addRowAfterFocused() -> CalcRow {
        let row = store.insertRow(after: focusedRowID)
        focusedRowID = row.id
        return row
    }

    func deleteFocused() {
        guard let id = focusedRowID else { return }
        let index = selectedIndex ?? 0
        store.deleteRow(id)
        let remaining = rows
        if remaining.isEmpty {
            focusedRowID = store.selectedSheet?.rows.first?.id
        } else {
            focusedRowID = remaining[min(index, remaining.count - 1)].id
        }
    }

    func undoDelete() {
        guard let row = store.undoDeleteRow() else { return }
        focusedRowID = row.id
    }

    enum CopyOutcome: Equatable {
        case empty
        case copied(String)
        case failed
    }

    /// ⌘D 复制当前行的结果；算不出时复制式子本身，至少不丢内容。
    func copyFocusedResult() -> CopyOutcome {
        guard let id = focusedRowID,
              let row = rows.first(where: { $0.id == id }) else { return .empty }
        let expression = row.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return .empty }
        let payload: String
        if case .success(let value) = CalcEvaluator.evaluate(expression) {
            payload = CalcFormat.string(value, scale: store.scale, grouping: store.groupingEnabled)
        } else {
            payload = expression
        }
        return ClipboardGuard.shared.copySecret(payload) ? .copied(payload) : .failed
    }
}
