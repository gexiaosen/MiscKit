import AppKit
import Foundation
import Testing

@testable import MiscKitCore

/// 「唤起面板带入刚复制的内容」的判定。uTools 那条体验的核心是 **5 秒**，
/// 而 macOS 没有剪贴板写入时间的公开 API，只能盯 changeCount —— 见 `ClipboardWatch` 的查证注释。
@MainActor
@Suite("剪贴板带入")
struct ClipboardPrefillTests {
    private func input(_ text: String?, age: TimeInterval? = 2,
                       own: Bool = false, initial: Bool = true) -> ClipboardPrefill.Input {
        ClipboardPrefill.Input(text: text, age: age, isOurOwnCopy: own, barIsInitial: initial)
    }

    @Test("窗口内带入，超窗不带；正好 5 秒算带")
    func windowBoundary() {
        #expect(ClipboardPrefill.textToUse(input("github", age: 4.9)) == "github")
        #expect(ClipboardPrefill.textToUse(input("github", age: ClipboardPrefill.window)) == "github")
        #expect(ClipboardPrefill.textToUse(
            input("github", age: ClipboardPrefill.window + 0.001)) == nil)
    }

    @Test("时间不知道就不带——宁可不带，也不把 20 分钟前的东西当刚复制的")
    func unknownAgeIsNotFresh() {
        #expect(ClipboardPrefill.textToUse(input("github", age: nil)) == nil)
    }

    @Test("本 App 自己复制的那份绝不带入")
    func ourOwnCopyNeverFills() {
        // 刚在 OTP 里点了复制 ⇒ 验证码/密钥绝不能出现在 22pt 的搜索条上
        #expect(ClipboardPrefill.textToUse(input("JBSWY3DPEHPK3PXP", own: true)) == nil)
    }

    @Test("非初始态不带：旧输入是「接着用」，不能被剪贴板盖掉")
    func onlyOnInitialBar() {
        #expect(ClipboardPrefill.textToUse(input("github", initial: false)) == nil)
    }

    @Test("多行不带，尾部换行不算多行")
    func singleLineOnly() {
        #expect(ClipboardPrefill.textToUse(input("一行\n两行")) == nil)
        #expect(ClipboardPrefill.textToUse(input("刚复制的\r\n")) == "刚复制的")
        #expect(ClipboardPrefill.textToUse(input("   前后空白清掉   ")) == "前后空白清掉")
    }

    @Test("空、纯空白、超长都不带")
    func emptyAndOversized() {
        #expect(ClipboardPrefill.textToUse(input(nil)) == nil)
        #expect(ClipboardPrefill.textToUse(input("   \n  ")) == nil)
        let long = String(repeating: "字", count: ClipboardPrefill.maxCharacters + 1)
        #expect(ClipboardPrefill.textToUse(input(long)) == nil)
        let edge = String(repeating: "字", count: ClipboardPrefill.maxCharacters)
        #expect(ClipboardPrefill.textToUse(input(edge)) == edge)
    }

    @Test("窗口和上限是 5 秒与 200 字符")
    func constantsArePinned() {
        #expect(ClipboardPrefill.window == 5)
        #expect(ClipboardPrefill.maxCharacters == 200)
    }

    // MARK: 计数观测

    @Test("第一次观测只建基线，不编造「何时复制」的时间戳")
    func firstObservationOnlyBaselines() {
        let watch = ClipboardWatch()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!watch.observe(count: 41, now: now))
        #expect(watch.changedAt == nil, "启动时看到的计数不能当「刚刚复制」")
    }

    @Test("计数变了才盖时间戳，没变不移动它")
    func onlyRealChangesRestamp() {
        let watch = ClipboardWatch()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = watch.observe(count: 41, now: start)
        _ = watch.observe(count: 42, now: start.addingTimeInterval(3))
        let stamped = watch.changedAt
        #expect(stamped == start.addingTimeInterval(3))
        _ = watch.observe(count: 42, now: start.addingTimeInterval(9))
        #expect(watch.changedAt == stamped, "没变化的轮询不该把时间往后推")
        _ = watch.observe(count: 43, now: start.addingTimeInterval(10))
        #expect(watch.changedAt == start.addingTimeInterval(10))
    }

    @Test("没有观测到任何变化时直接不读剪贴板内容")
    func nothingObservedShortCircuitsBeforeReading() {
        // 多数唤起走的就是这条路：跨进程读字符串要等源 App 序列化，不该为它付时间
        let watch = ClipboardWatch()
        #expect(watch.prefillText(barIsInitial: true) == nil)
        #expect(watch.prefillText(barIsInitial: false) == nil)
    }

    @Test("冲突规则：面板已有内容为主，5 秒内的新复制也不覆盖（用户实测报的那条）")
    func existingQueryWinsOverFreshClipboard() {
        // 输入文字 → 面板消失 → 2 分钟内又复制别的东西 → 再唤起：
        // 恢复旧输入，不带入。这条以前是靠调用方提前 return 实现的，现在由规则判。
        #expect(ClipboardPrefill.textToUse(input("github", age: 1, initial: false)) == nil)
        #expect(!ClipboardPrefill.worthReading(age: 1, isOurOwnCopy: false, barIsInitial: false))
        // 而"没内容没钉住"才读得到
        #expect(ClipboardPrefill.worthReading(age: 1, isOurOwnCopy: false, barIsInitial: true))
    }

    @Test("不该读内容的时候真的不读：非初始态时 prefillText 直接给 nil")
    func refusesBeforePayingForTheRead() {
        let watch = ClipboardWatch()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = watch.observe(count: 7, now: start)
        _ = watch.observe(count: 8, now: start)     // 制造一次"刚变化"
        #expect(watch.changedAt != nil)
        #expect(watch.prefillText(barIsInitial: false, now: start) == nil)
    }

    // MARK: 强制点

    /// 剪贴板写入必须走 `ClipboardGuard` 那一个口子：
    /// 少了这一步，"排除我们自己复制的验证码"就变成一句约定，随时会被新加的复制点绕过。
    @Test("全仓只准 ClipboardGuard 写剪贴板")
    func writesGoThroughTheOneDoor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil) else {
            throw MissingSources("找不到 Sources，门禁失效就是门禁没跑")
        }
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if url.lastPathComponent == "ClipboardGuard.swift" { continue }
            if text.contains("clearContents()") || text.contains("setString(")
                || text.contains("writeObjects(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 50, "只扫到 \(scanned) 个文件，门禁范围不对")
        #expect(offenders.isEmpty, "这些地方在绕过 ClipboardGuard 直接写剪贴板：\(offenders)")
    }

    private struct MissingSources: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }
}
