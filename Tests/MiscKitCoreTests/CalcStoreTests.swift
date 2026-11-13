import Foundation
import Testing

@testable import MiscKitCore

@MainActor
private func makeCalcStore() -> (CalcStore, UserDefaults, String) {
    let suite = "misckit-calc-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (CalcStore(defaults: defaults), defaults, suite)
}

@MainActor
private func cleanupCalc(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
}

@MainActor
@Suite("稿纸：多张与行操作")
struct CalcStoreTests {
    @Test("新张用日期时间命名并立刻选中")
    func newSheetNaming() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let date = Date(timeIntervalSince1970: 1_792_500_000)
        let id = store.newSheet(date: date)
        #expect(store.selectedSheetID == id)
        #expect(store.selectedSheet?.name == CalcSheet.defaultName(date: date))
        #expect(store.selectedSheet?.rows.count == 1)
    }

    @Test("重开后回到上次那张")
    func restoresLastSheet() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let first = store.newSheet(date: Date(timeIntervalSince1970: 1_000))
        let second = store.newSheet(date: Date(timeIntervalSince1970: 2_000))
        #expect(store.selectedSheetID == second)
        store.selectedSheetID = first

        let reopened = CalcStore(defaults: defaults)
        #expect(reopened.selectedSheetID == first)
    }

    @Test("删掉当前张后选中最近的一张")
    func deleteReassignsSelection() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let a = store.newSheet(date: Date(timeIntervalSince1970: 1_000))
        let b = store.newSheet(date: Date(timeIntervalSince1970: 2_000))
        store.delete(b)
        #expect(store.selectedSheetID == a)
        #expect(store.sheets.count == 1)
    }

    @Test("改名忽略空白，其它照常落盘")
    func renameIgnoresBlank() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let id = store.newSheet()
        store.rename(id, to: "   ")
        #expect(store.selectedSheet?.name == CalcSheet.defaultName(date: store.sheets[0].createdAt))
        store.rename(id, to: "面料报价")
        #expect(store.selectedSheet?.name == "面料报价")
        #expect(CalcStore(defaults: defaults).sheets.first?.name == "面料报价")
    }

    @Test("在指定行之后插行")
    func insertAfterRow() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        store.newSheet()
        let first = store.selectedSheet!.rows[0]
        let added = store.insertRow(after: first.id, expression: "2+3")
        #expect(store.selectedSheet?.rows.map(\.id) == [first.id, added.id])
        let tail = store.insertRow(after: nil, expression: "4")
        #expect(store.selectedSheet?.rows.last?.id == tail.id)
    }

    @Test("删行后至少留一行空的，打字的地方不会消失")
    func deleteRowKeepsOneLine() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        store.newSheet()
        let only = store.selectedSheet!.rows[0]
        store.deleteRow(only.id)
        #expect(store.selectedSheet?.rows.count == 1)
        #expect(store.selectedSheet?.rows[0].expression.isEmpty == true)
    }

    @Test("⌘R 删行可撤销，撤销把行放回原位")
    func undoRestoresPosition() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        store.newSheet()
        let head = store.selectedSheet!.rows[0]
        let middle = store.insertRow(after: head.id, expression: "10*5")
        store.insertRow(after: middle.id, expression: "tail")
        store.deleteRow(middle.id)
        #expect(store.canUndoRow)
        #expect(store.selectedSheet?.rows.map(\.expression) == ["", "tail"])
        let restored = store.undoDeleteRow()
        #expect(restored?.expression == "10*5")
        #expect(store.selectedSheet?.rows.map(\.expression) == ["", "10*5", "tail"])
    }

    @Test("删空行不进撤销栈")
    func emptyRowsSkipUndo() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        store.newSheet()
        let blank = store.insertRow(after: nil)
        store.deleteRow(blank.id)
        #expect(!store.canUndoRow)
    }

    @Test("超过 50 张裁最久的，但绝不动当前这张")
    func retentionKeepsCurrent() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        for index in 0..<40 { store.newSheet(date: Date(timeIntervalSince1970: 1_000 + Double(index))) }
        let pinned = store.newSheet(date: Date(timeIntervalSince1970: 900))
        store.selectedSheetID = pinned
        for index in 0..<30 { store.newSheet(date: Date(timeIntervalSince1970: 5_000 + Double(index))) }
        #expect(store.sheets.count == 50)
        #expect(store.sheets.contains { $0.id == pinned }, "当前张不能被裁掉")
    }

    @Test("搜索命中张名与任意一行的式子")
    func searchMatchesNamesAndRows() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let a = store.newSheet()
        store.rename(a, to: "报价")
        let b = store.newSheet()
        let row = store.selectedSheet!.rows[0]
        store.updateRow(row.id, expression: "12*3")
        #expect(store.sheet(matching: "报价").map(\.id) == [a])
        #expect(store.sheet(matching: "12*3").map(\.id) == [b])
        #expect(store.sheet(matching: "没有的东西").isEmpty)
    }

    @Test("归档的张不在默认列表里")
    func archivedSeparated() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let id = store.newSheet()
        #expect(store.activeSheets.count == 1)
        store.setArchived(id, true)
        #expect(store.activeSheets.isEmpty)
        #expect(store.archivedSheets.count == 1)
    }

    @Test("整张导出为「式子 = 结果」，算不出的只留等号")
    func plainTextExport() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        store.newSheet()
        let first = store.selectedSheet!.rows[0]
        store.updateRow(first.id, expression: "23+12")
        let second = store.insertRow(after: first.id, expression: "1/0")
        store.insertRow(after: second.id, expression: "  ")
        let text = store.plainText(of: store.selectedSheet!)
        #expect(text == "23+12 = 35\n1/0 =")
    }

    @Test("小数位与千分位偏好落盘")
    func displayPreferencesPersist() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        #expect(store.scale == .two)
        store.scale = .four
        store.groupingEnabled = true
        let reopened = CalcStore(defaults: defaults)
        #expect(reopened.scale == .four)
        #expect(reopened.groupingEnabled)
    }

    @Test("默认小数位是 2")
    func defaultScaleIsTwo() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        #expect(store.scale == .two)
    }
}

@MainActor
@Suite("稿纸：归档与搜索")
struct CalcArchiveSearchTests {
    @Test("归档的张从在用列表移到归档列表，取消归档能回来")
    func archiveRoundTrip() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let id = store.newSheet(date: Date(timeIntervalSince1970: 1_000))
        store.newSheet(date: Date(timeIntervalSince1970: 2_000))
        #expect(store.activeSheets.count == 2)

        store.setArchived(id, true)
        #expect(store.activeSheets.contains { $0.id == id } == false)
        #expect(store.archivedSheets.map(\.id) == [id])

        store.setArchived(id, false)
        #expect(store.activeSheets.contains { $0.id == id })
        #expect(store.archivedSheets.isEmpty)
    }

    @Test("归档状态重开还在")
    func archiveStatePersists() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let id = store.newSheet(date: Date(timeIntervalSince1970: 1_000))
        store.setArchived(id, true)
        let reopened = CalcStore(defaults: defaults)
        #expect(reopened.archivedSheets.map(\.id) == [id])
        #expect(reopened.activeSheets.isEmpty)
    }

    @Test("裁名额只数在用的张，归档的不会被静默删掉")
    func retentionCountsActiveOnly() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        store.retention = 3
        let archivedID = store.newSheet(date: Date(timeIntervalSince1970: 1_000))
        let doomedID = store.newSheet(date: Date(timeIntervalSince1970: 2_000))
        store.setArchived(archivedID, true)
        store.newSheet(date: Date(timeIntervalSince1970: 3_000))
        store.newSheet(date: Date(timeIntervalSince1970: 4_000))
        store.newSheet(date: Date(timeIntervalSince1970: 5_000))
        // 在用的已经超名额，最久没动那张被裁；归档那张必须还在
        #expect(store.activeSheets.count == 3)
        #expect(store.activeSheets.contains { $0.id == doomedID } == false)
        #expect(store.archivedSheets.map(\.id) == [archivedID])
    }

    @Test("搜名字与搜式子都能命中，空词等于全部在用张")
    func searchMatchesNameAndExpression() {
        let (store, defaults, suite) = makeCalcStore()
        defer { cleanupCalc(defaults, suite) }
        let a = store.newSheet(date: Date(timeIntervalSince1970: 1_000))
        store.rename(a, to: "春季报价")
        store.insertRow(after: store.selectedSheet?.rows.first?.id, expression: "1200*3")
        let b = store.newSheet(date: Date(timeIntervalSince1970: 2_000))
        store.rename(b, to: "杂项")

        #expect(store.sheet(matching: "报价").map(\.id) == [a])
        #expect(store.sheet(matching: "1200").map(\.id) == [a])
        #expect(store.sheet(matching: "  ").count == 2)
        // 归档出去的那张不该还能被"在用"搜索捞回来
        store.setArchived(a, true)
        #expect(store.sheet(matching: "报价").isEmpty)
    }
}
