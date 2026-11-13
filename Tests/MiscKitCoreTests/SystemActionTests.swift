import AppKit
import Foundation
import Testing

@testable import MiscKitCore

@Suite("系统动作")
struct SystemActionTests {
    @Test("22 条齐全，id 唯一，分组数量对得上")
    func catalogShape() {
        let all = SystemActionCatalog.all
        #expect(all.count == 22)
        #expect(Set(all.map(\.id)).count == 22)
        #expect(all.filter { $0.group == .power }.count == 4)
        #expect(all.filter { $0.group == .media }.count == 3)
        #expect(all.filter { $0.group == .volume }.count == 10)
        #expect(all.filter { $0.group == .desktop }.count == 3)
        #expect(all.filter { $0.group == .finder }.count == 2)
        for action in all {
            #expect(!action.title.isEmpty)
            #expect(!action.words.isEmpty, "「\(action.title)」没有别名，输入框里打不出来")
        }
    }

    @Test("id 往返：每个 code 都查得回自己")
    func idRoundTrip() {
        for action in SystemActionCatalog.all {
            #expect(SystemActionCatalog.action(id: action.id) == action)
        }
        #expect(SystemActionCatalog.action(id: "没有这条") == nil)
    }

    @Test("整词命中压过前缀与包含")
    func matchRanks() {
        #expect(SystemActionCatalog.match("静音").first?.id == "mute")
        #expect(SystemActionCatalog.match("麦克风静音").first?.id == "mic-mute")
        #expect(SystemActionCatalog.match("锁屏").first?.id == "lock-screen")
    }

    @Test("中文、拼音、英文三条路都通")
    func threeSpellings() {
        #expect(SystemActionCatalog.match("suoping").first?.id == "lock-screen")
        #expect(SystemActionCatalog.match("sleep").first?.id == "sleep")
        #expect(SystemActionCatalog.match("屏幕保护").first?.id == "screen-saver")
    }

    @Test("空词与生词都不出动作")
    func noMatch() {
        #expect(SystemActionCatalog.match("").isEmpty)
        #expect(SystemActionCatalog.match("   ").isEmpty)
        #expect(SystemActionCatalog.match("zzzzzz").isEmpty)
    }

    @Test("同分保持声明顺序")
    func tiesKeepOrder() {
        let ids = SystemActionCatalog.match("音量").map(\.id)
        let declared = SystemActionCatalog.all.filter { ids.contains($0.id) }.map(\.id)
        #expect(ids == declared)
    }

    @Test("「音量 30」解析成数值，越界与写错都不认领")
    func volumePercentParsing() {
        #expect(SystemTool.volumePercent(from: "音量 30") == 30)
        #expect(SystemTool.volumePercent(from: "音量30") == 30)
        #expect(SystemTool.volumePercent(from: "音量 30%") == 30)
        #expect(SystemTool.volumePercent(from: "volume 0") == 0)
        #expect(SystemTool.volumePercent(from: "volume 100") == 100)
        #expect(SystemTool.volumePercent(from: "音量 101") == nil)
        #expect(SystemTool.volumePercent(from: "音量 -1") == nil)
        #expect(SystemTool.volumePercent(from: "音量") == nil)
        #expect(SystemTool.volumePercent(from: "音量 三十") == nil)
        #expect(SystemTool.volumePercent(from: "静音") == nil)
    }

    @Test("「设定音量…」只要数值，不在这里改音量")
    @MainActor
    func volumeSetAsksForValue() throws {
        #expect(try SystemControl.perform("volume-set") == .needsValue)
    }

    @Test("执行会碰硬件的动作一律不在测试里跑")
    func dangerousActionsAreCatalogOnly() {
        let destructive = ["sleep", "display-sleep", "lock-screen", "screen-saver",
                           "mute", "mic-mute", "eject-volumes", "show-desktop"]
        for id in destructive {
            #expect(SystemActionCatalog.action(id: id) != nil, "\(id) 应该还在目录里")
        }
    }
}
