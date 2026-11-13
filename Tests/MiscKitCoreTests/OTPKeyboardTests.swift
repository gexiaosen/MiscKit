import Foundation
import Testing

@testable import MiscKitCore

/// OTP 工作区的键盘导航。盯的是「↑↓ 落在哪一条」和「列表变了选中怎么落回区间」，
/// 这两件事错了不崩，只是用户按半天停在看不见的位置上。
@MainActor
@Suite("OTP 键盘导航")
struct OTPKeyboardTests {
    private func makeStore(_ entries: [(String, String)]) -> (OTPStore, UserDefaults, String) {
        let suite = "misckit-otp-nav-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = OTPStore(defaults: defaults, secrets: InMemorySecretStore())
        for (issuer, account) in entries {
            let meta = OTPAccount(issuer: issuer, account: account,
                                  keychainAccount: "\(issuer)/\(account)")
            store.add(OTPEntry(account: meta, secret: Data("JBSWY3DPEHPK3PXP".utf8)))
        }
        return (store, defaults, suite)
    }

    @Test("空列表：不动、不选中、也不发请求")
    func emptyListIsInert() {
        let (store, defaults, suite) = makeStore([])
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OTPWorkspaceModel()
        #expect(!model.move(by: 1, in: store))
        #expect(model.selected(in: store) == nil)
        #expect(model.requestCopy(in: store) == nil)
        #expect(model.requestNote(in: store) == nil)
        #expect(model.copyRequest == 0, "没有目标却递增 token，面板会收到一次空请求")
    }

    @Test("没搜索时按界面的分组顺序走，不是按存储顺序")
    func walksGroupedOrder() {
        // 两条 GitHub + 一条 Notion：分组顺序 = GitHub, Notion；组内保持加入顺序
        let (store, defaults, suite) = makeStore([("GitHub", "a"), ("Notion", "n"), ("GitHub", "b")])
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OTPWorkspaceModel()
        let order = model.displayed(in: store).map(\.account)
        #expect(order == ["a", "b", "n"], "可见顺序应为分组展开，实得 \(order)")

        var walked: [String] = []
        for _ in 0..<3 {
            _ = model.move(by: 1, in: store)
            walked.append(model.selected(in: store)?.account ?? "?")
        }
        #expect(walked == ["a", "b", "n"])
        // 到底了再按不动
        #expect(model.move(by: 1, in: store))
        #expect(model.selected(in: store)?.account == "n")
    }

    @Test("搜索态只在这几条过滤结果里走")
    func searchNarrowsNavigation() {
        let (store, defaults, suite) = makeStore([("GitHub", "a"), ("Notion", "n")])
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OTPWorkspaceModel()
        _ = model.move(by: 1, in: store)
        model.query = "notion"
        let visible = model.displayed(in: store).map(\.account)
        #expect(visible == ["n"])
        #expect(model.selected(in: store)?.account == "n", "选中项被过滤掉了要落回可见的第一条")
        #expect(model.move(by: 1, in: store))
        #expect(model.selected(in: store)?.account == "n", "只剩一条时上下都该停在它身上")
    }

    @Test("鼠标点一条之后，↑↓ 从那条接着走")
    func clickAlignsKeyboard() {
        let (store, defaults, suite) = makeStore([("GitHub", "a"), ("GitHub", "b"), ("GitHub", "c")])
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OTPWorkspaceModel()
        guard let third = store.accounts.last else { Issue.record("没建出账户"); return }
        model.select(third)
        #expect(model.selected(in: store)?.account == "c")
        #expect(model.move(by: -1, in: store))
        #expect(model.selected(in: store)?.account == "b")
    }

    @Test("复制与备注各是一个请求信号，不互相串")
    func requestsAreSeparate() {
        let (store, defaults, suite) = makeStore([("GitHub", "a")])
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OTPWorkspaceModel()
        _ = model.requestCopy(in: store)
        _ = model.requestCopy(in: store)
        #expect(model.copyRequest == 2)
        #expect(model.noteRequest == 0, "复制不该顺手弹备注框")
        _ = model.requestNote(in: store)
        #expect(model.noteRequest == 1)
    }

    @Test("退出 OTP 页要清掉选中与搜索词")
    func clearResets() {
        let (store, defaults, suite) = makeStore([("GitHub", "a")])
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OTPWorkspaceModel()
        _ = model.move(by: 1, in: store)
        model.query = "git"
        model.clear()
        #expect(model.selectedID == nil)
        #expect(model.query.isEmpty)
        #expect(model.selected(in: store)?.account == "a", "清掉后重新进来从第一条开始，不是停在旧 id")
    }
}
