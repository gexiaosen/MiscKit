import Foundation
import Observation

/// OTP 工作区的键盘选中状态。放 Core 而不是 UI，理由与 `HostsPaneModel` 同一条：
/// 「↑↓ 落在哪一条、列表缩水后选中怎么落回区间内」这类导航规则错了不崩，只是默默难用，
/// 而 UI target 里的东西一行都测不到。
@MainActor
@Observable
public final class OTPWorkspaceModel {
    /// 面板顶部的搜索词。界面是唯一来源，这里只镜像一份好算可见列表。
    public var query = ""
    public private(set) var selectedID: UUID?
    public init() {}

    /// 递增一次 = 请面板弹一次「复制」。面板观察它复用已有的复制动作，
    /// 而不是让 `LauncherView` 去碰剪贴板 —— 复制的反馈与 HOTP 计数都在面板里。
    public private(set) var copyRequest = 0
    /// 递增一次 = 请面板打开一次「备注」。
    public private(set) var noteRequest = 0

    /// 界面上真正显示的那批账户与顺序：没搜索时按分组展开，搜索时是扁平的过滤结果。
    /// 必须和 `OTPPane` 画的是同一份，否则 ↑↓ 会跳过看得见的那条、停在看不见的那条上。
    public func displayed(in store: OTPStore) -> [OTPAccount] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.grouped.flatMap(\.accounts)
            : store.visibleAccounts(matching: query)
    }

    public func selected(in store: OTPStore) -> OTPAccount? {
        let list = displayed(in: store)
        if let id = selectedID, let hit = list.first(where: { $0.id == id }) { return hit }
        return list.first          // 搜索词变了或列表缩了：落回第一条，别停在没了的 id 上
    }

    @discardableResult
    public func move(by delta: Int, in store: OTPStore) -> Bool {
        let list = displayed(in: store)
        guard !list.isEmpty else { return false }
        let current = selectedID.flatMap { id in list.firstIndex { $0.id == id } }
            ?? (delta > 0 ? -1 : 0)
        let target = ListSelection.move(current: current, delta: delta, count: list.count)
        guard list[target].id != selectedID else { return true }
        selectedID = list[target].id
        return true
    }

    public func select(_ account: OTPAccount) {
        selectedID = account.id
    }

    /// 返回要复制的账户；没有可复制对象时**不递增** token（否则面板会收到一次空请求）。
    public func requestCopy(in store: OTPStore) -> OTPAccount? {
        guard let account = selected(in: store) else { return nil }
        copyRequest += 1
        return account
    }

    public func requestNote(in store: OTPStore) -> OTPAccount? {
        guard let account = selected(in: store) else { return nil }
        noteRequest += 1
        return account
    }

    public func clear() {
        selectedID = nil
        query = ""
    }
}
