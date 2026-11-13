import Foundation
import Testing

@testable import MiscKitCore

/// hosts 工作区的键盘导航。这些断言盯的是"错了不崩、只是默默难用"的那类行为：
/// 边界夹住、跳过空行、基座不许一键关掉。
@MainActor
@Suite("Hosts 键盘导航")
struct HostsKeyboardTests {
    private let fixture = """
        #-------- 共用 --------
        127.0.0.1 localhost
        ::1 localhost

        #-------- DEMO --------

        10.0.0.7 a.demo
        10.0.0.8 b.demo
        #-------- DESIGN --------
        10.0.1.7 x.demo
        """

    private func makeStore() throws -> (HostsStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("misckit-hosts-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hosts = root.appendingPathComponent("hosts")
        try fixture.write(to: hosts, atomically: true, encoding: .utf8)
        let store = HostsStore(paths: HostsPaths(hostsFile: hosts,
                                                 supportDirectory: root.appendingPathComponent("Support")))
        store.ensureLoaded()
        return (store, { try? FileManager.default.removeItem(at: root) })
    }

    // MARK: 段列表层

    @Test("↑↓ 选段，到边界夹住不越界")
    func sectionNavigationClamps() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        #expect(store.sections.count == 3)

        #expect(model.move(by: 1, store: store))
        let first = store.sections[0].id
        #expect(model.selectedSectionID == first)
        model.move(by: 1, store: store)
        #expect(model.selectedSectionID == store.sections[1].id)
        model.move(by: 1, store: store)
        model.move(by: 1, store: store)                       // 已经到底，再按不动
        #expect(model.selectedSectionID == store.sections[2].id)
        for _ in 0..<5 { model.move(by: -1, store: store) }   // 也不会从顶上掉出去
        #expect(model.selectedSectionID == store.sections[0].id)
    }

    @Test("↵ 展开该段：切到段内容页，光标落在第一条非空行")
    func activateOpensSectionAndSkipsBlanks() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        model.selectedSectionID = store.sections[1].id        // DEMO 段：开头有一行空行
        let outcome = model.activate(store: store)
        if case .openedSection(let name) = outcome {
            #expect(name == "DEMO")
        } else { Issue.record("应回 .openedSection，实得 \(outcome)") }
        #expect(model.tab == .content)
        #expect(model.zone == .lines)
        // DEMO 段 lines = ["", "10.0.0.7 a.demo", "10.0.0.8 b.demo"] → 第一条可导航的是下标 1
        #expect(model.selectedLineIndex == 1)
    }

    @Test("空段里按 ↵ 不开编辑框也不崩")
    func activateOnEmptySectionIsHarmless() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        let id = store.addSection(named: "空段")
        #expect(id != nil)
        model.selectedSectionID = id
        model.tab = .content
        model.selectedLineIndex = nil
        if case .nothing = model.activate(store: store) {} else {
            Issue.record("空段不该产生编辑请求")
        }
        #expect(model.requestLineEditor == nil)
        #expect(model.move(by: 1, store: store) == false)
    }

    // MARK: 段内容层

    @Test("↑↓ 在段内容页跳过空行")
    func lineNavigationSkipsBlank() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        model.selectedSectionID = store.sections[1].id
        _ = model.activate(store: store)                      // 现在在段内容页，光标在下标 1
        #expect(model.selectedLineIndex == 1)
        model.move(by: 1, store: store)
        #expect(model.selectedLineIndex == 2)
        model.move(by: -1, store: store)
        #expect(model.selectedLineIndex == 1)
        model.move(by: -1, store: store)                      // 下标 0 是空行，必须被跳过
        #expect(model.selectedLineIndex == 1)
    }

    @Test("⌘ 在段列表勾选该段，store 真的变了")
    func toggleSectionWritesThrough() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        model.selectedSectionID = store.sections[1].id
        let before = store.sections[1].isEnabled
        _ = model.toggleFocused(store: store)
        #expect(store.sections[1].isEnabled == !before)
    }

    @Test("⌘ 关基座不直接关：挂出确认请求，状态原样")
    func baseOffRequiresConfirm() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        model.selectedSectionID = store.sections[0].id        // 共用 = 基座
        #expect(store.sections[0].isBase)
        let before = store.sections[0].isEnabled
        if case .needsBaseConfirm = model.toggleFocused(store: store) {} else {
            Issue.record("关基座必须走二次确认")
        }
        #expect(model.requestBaseOff?.name == store.sections[0].name)
        #expect(store.sections[0].isEnabled == before, "确认之前不该真的关掉")
    }

    @Test("⌘ 在段内容页禁用该行，返回的是'操作完之后'的状态")
    func toggleLineReportsPostState() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        model.selectedSectionID = store.sections[1].id
        _ = model.activate(store: store)
        model.selectedLineIndex = 1                           // a.demo，当前启用
        if case .toggledLine(let index, let enabled) = model.toggleFocused(store: store) {
            #expect(index == 1)
            #expect(enabled == false, "原本启用，禁用之后应报 enabled=false")
        } else { Issue.record("应回 .toggledLine") }
        #expect(store.sections[1].disabledLines.contains(1))

        // 再按一次恢复
        if case .toggledLine(_, let enabled) = model.toggleFocused(store: store) {
            #expect(enabled == true, "原本禁用，恢复之后应报 enabled=true")
        } else { Issue.record("应回 .toggledLine") }
        #expect(!store.sections[1].disabledLines.contains(1))
    }

    // MARK: 退回

    @Test("← 从段内容页退回段列表；已经在段列表时交回上层")
    func collapseOnlyInsideContent() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let model = HostsPaneModel()
        #expect(!model.collapse(), "在生效预览页按 ← 应交回 LauncherView 退出 hosts")
        model.selectedSectionID = store.sections[1].id
        _ = model.activate(store: store)
        #expect(model.tab == .content)
        #expect(model.collapse())
        #expect(model.tab != .content)
        #expect(model.selectedLineIndex == nil)
    }
}
