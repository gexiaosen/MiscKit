import Foundation
import Observation

public struct CalcRow: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var expression: String

    public init(id: UUID = UUID(), expression: String = "") {
        self.id = id
        self.expression = expression
    }
}

public struct CalcSheet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 默认用日期时间命名（参照图右侧列表就是时间戳），可以改成自己的名字
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var rows: [CalcRow]
    /// 归档不等于删除：收起来但不占默认 50 张的名额
    public var archived: Bool

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(),
                rows: [CalcRow] = [CalcRow()], archived: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.rows = rows
        self.archived = archived
    }

    public static let defaultNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    public static func defaultName(date: Date = Date()) -> String {
        defaultNameFormatter.string(from: date)
    }
}

/// 稿纸的真相：多张、每张多行、显示偏好，全部落 UserDefaults。
/// 求值不在这里做，视图直接问 `CalcEvaluator`，这样输入时能立刻出结果而不必先落盘。
@MainActor
@Observable
public final class CalcStore {
    public static let shared = CalcStore(defaults: .standard)

    private let defaults: UserDefaults
    private let sheetsKey = "calc.sheets.v1"
    private let lastSheetKey = "calc.lastSheetID.v1"
    private let scaleKey = "calc.scale.v1"
    private let groupingKey = "calc.grouping.v1"
    /// 默认保留 50 张
    public var retention = 50

    public private(set) var sheets: [CalcSheet] = []
    public var selectedSheetID: UUID? {
        didSet { defaults.set(selectedSheetID?.uuidString, forKey: lastSheetKey) }
    }
    public var scale: CalcScale {
        didSet { defaults.set(scale.rawValue, forKey: scaleKey) }
    }
    public var groupingEnabled: Bool {
        didSet { defaults.set(groupingEnabled, forKey: groupingKey) }
    }
    public var lastError: String?

    /// 删行的撤销栈：只存被删的行与位置，够把误删还原回来
    private var undoStack: [(sheetID: UUID, row: CalcRow, index: Int)] = []

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.scale = CalcScale(rawValue: defaults.object(forKey: scaleKey) as? Int ?? 2) ?? .two
        self.groupingEnabled = defaults.object(forKey: groupingKey) as? Bool ?? false
        reload()
        // 启动恢复上次那张；那张被删过就退回最新的一张
        if let saved = defaults.string(forKey: lastSheetKey), let id = UUID(uuidString: saved),
           sheets.contains(where: { $0.id == id }) {
            selectedSheetID = id
        } else {
            selectedSheetID = sheets.first?.id
        }
    }

    public func reload() {
        // 编码走 iso8601，解码必须同样设置：默认策略会把日期解成 Double 而整体失败，
        // 表现是"存了但重开就空"。HostsState 也踩过这个。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = defaults.data(forKey: sheetsKey),
              let decoded = try? decoder.decode([CalcSheet].self, from: data) else {
            sheets = []
            return
        }
        sheets = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: 张

    public var selectedSheet: CalcSheet? {
        guard let id = selectedSheetID else { return nil }
        return sheets.first { $0.id == id }
    }

    /// 未归档的张，按最近使用排序；右侧列表就显示这个。
    public var activeSheets: [CalcSheet] { sheets.filter { !$0.archived } }
    public var archivedSheets: [CalcSheet] { sheets.filter { $0.archived } }

    @discardableResult
    public func newSheet(date: Date = Date()) -> UUID {
        let sheet = CalcSheet(name: CalcSheet.defaultName(date: date), createdAt: date)
        sheets.insert(sheet, at: 0)
        selectedSheetID = sheet.id
        trim()
        persist()
        return sheet.id
    }

    public func delete(_ id: UUID) {
        sheets.removeAll { $0.id == id }
        undoStack.removeAll { $0.sheetID == id }
        if selectedSheetID == id { selectedSheetID = sheets.first?.id }
        persist()
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        sheets[index].name = trimmed
        touch(sheets[index])
        persist()
    }

    public func setArchived(_ id: UUID, _ archived: Bool) {
        guard let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        sheets[index].archived = archived
        persist()
    }

    public func sheet(matching term: String) -> [CalcSheet] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return activeSheets }
        return activeSheets.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.rows.contains { row in row.expression.localizedCaseInsensitiveContains(needle) }
        }
    }

    // MARK: 行

    public func updateRow(_ rowID: UUID, expression: String) {
        guard let sheetIndex = sheets.firstIndex(where: { $0.id == selectedSheetID }),
              let rowIndex = sheets[sheetIndex].rows.firstIndex(where: { $0.id == rowID }) else { return }
        sheets[sheetIndex].rows[rowIndex].expression = expression
        touch(sheets[sheetIndex])
        persist()
    }

    /// 在给定行之后插入新行；不传就加到末尾。
    @discardableResult
    public func insertRow(after rowID: UUID?, expression: String = "") -> CalcRow {
        let row = CalcRow(expression: expression)
        guard let sheetIndex = sheets.firstIndex(where: { $0.id == selectedSheetID }) else {
            let sheet = CalcSheet(name: CalcSheet.defaultName(), rows: [row])
            sheets.insert(sheet, at: 0)
            selectedSheetID = sheet.id
            persist()
            return row
        }
        if let rowID, let at = sheets[sheetIndex].rows.firstIndex(where: { $0.id == rowID }) {
            sheets[sheetIndex].rows.insert(row, at: at + 1)
        } else {
            sheets[sheetIndex].rows.append(row)
        }
        touch(sheets[sheetIndex])
        persist()
        return row
    }

    /// 删行：入栈以便撤销。空行不占撤销名额，免得按几次 ⌘R 之后撤销栈全是空气。
    public func deleteRow(_ rowID: UUID) {
        guard let sheetIndex = sheets.firstIndex(where: { $0.id == selectedSheetID }),
              let rowIndex = sheets[sheetIndex].rows.firstIndex(where: { $0.id == rowID }) else { return }
        let row = sheets[sheetIndex].rows.remove(at: rowIndex)
        if !row.expression.trimmingCharacters(in: .whitespaces).isEmpty {
            undoStack.append((selectedSheetID!, row, rowIndex))
            if undoStack.count > 20 { undoStack.removeFirst(undoStack.count - 20) }
        }
        if sheets[sheetIndex].rows.isEmpty { sheets[sheetIndex].rows.append(CalcRow()) }
        touch(sheets[sheetIndex])
        persist()
    }

    public var canUndoRow: Bool { !undoStack.isEmpty }

    @discardableResult
    public func undoDeleteRow() -> CalcRow? {
        guard let last = undoStack.popLast(),
              let sheetIndex = sheets.firstIndex(where: { $0.id == last.sheetID }) else { return nil }
        let index = min(last.index, sheets[sheetIndex].rows.count)
        // 末尾那条自动空行是给打字准备的，还原时把它顶掉
        if sheets[sheetIndex].rows.count == 1,
           sheets[sheetIndex].rows[0].expression.trimmingCharacters(in: .whitespaces).isEmpty {
            sheets[sheetIndex].rows = [last.row]
        } else {
            sheets[sheetIndex].rows.insert(last.row, at: index)
        }
        touch(sheets[sheetIndex])
        persist()
        return last.row
    }

    public func clearRows(of id: UUID) {
        guard let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        sheets[index].rows = [CalcRow()]
        undoStack.removeAll { $0.sheetID == id }
        touch(sheets[index])
        persist()
    }

    /// 整张导出成纯文本（"复制整张"）：`式子 = 结果` 每行一条。
    public func plainText(of sheet: CalcSheet) -> String {
        sheet.rows.compactMap { row -> String? in
            let expression = row.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else { return nil }
            if case .success(let value) = CalcEvaluator.evaluate(expression) {
                return "\(expression) = \(CalcFormat.string(value, scale: scale, grouping: groupingEnabled))"
            }
            return "\(expression) ="
        }.joined(separator: "\n")
    }

    // MARK: 内部

    private func touch(_ sheet: CalcSheet) {
        guard let index = sheets.firstIndex(where: { $0.id == sheet.id }) else { return }
        sheets[index].updatedAt = Date()
        sheets.sort { $0.updatedAt > $1.updatedAt }
    }

    private func trim() {
        // 名额只数在用的张：归档是"收起来"，不是"等着被裁掉"。
        // 以前这里数的是 sheets.count，攒够 50 张就会把归档张静默删掉，
        // 而归档张在界面上已经不可见，等于无声丢数据。
        let active = sheets.filter { !$0.archived }
        guard active.count > retention else { return }
        // 当前那张永远不裁，裁的是最久没动的
        let keep = active.filter { $0.id != selectedSheetID }
        let dropped = keep.dropFirst(retention - 1).map(\.id)
        sheets.removeAll { dropped.contains($0.id) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sheets) else {
            lastError = L10n.Calc.saveFailed
            return
        }
        defaults.set(data, forKey: sheetsKey)
        lastError = nil
    }
}
