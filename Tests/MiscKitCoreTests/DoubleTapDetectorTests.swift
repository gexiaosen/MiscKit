import AppKit
import Testing

@testable import MiscKitCore

/// 按一次修饰键的完整动作：按下 → 抬起。
private func tap(_ detector: inout DoubleTapDetector, _ key: ModifierKey,
                 downAt: TimeInterval, upAt: TimeInterval) -> Bool {
    _ = detector.handleFlags(key.flag, at: downAt)
    return detector.handleFlags([], at: upAt)
}

@Test("300ms 内双击同一修饰键触发")
func doubleTapWithinInterval() {
    var detector = DoubleTapDetector(modifier: .option)
    #expect(detector.handleFlags([.option], at: 0) == false)
    #expect(detector.handleFlags([], at: 0.08) == false)
    #expect(detector.handleFlags([.option], at: 0.25) == true)
}

@Test("超过时间窗不触发，第二次按下成为新的起点")
func doubleTapOutsideIntervalReArms() {
    var detector = DoubleTapDetector(modifier: .shift)
    _ = detector.handleFlags([.shift], at: 0)
    _ = detector.handleFlags([], at: 0.05)
    #expect(detector.handleFlags([.shift], at: 0.4) == false)
    _ = detector.handleFlags([], at: 0.45)
    #expect(detector.handleFlags([.shift], at: 0.6) == true)
}

@Test("中间打字会清掉第一次按下")
func keyDownResetsPendingTap() {
    var detector = DoubleTapDetector(modifier: .option)
    _ = detector.handleFlags([.option], at: 0)
    _ = detector.handleFlags([], at: 0.05)
    detector.handleKeyDown()
    #expect(detector.handleFlags([.option], at: 0.2) == false)
    _ = detector.handleFlags([], at: 0.25)
    #expect(detector.handleFlags([.option], at: 0.4) == true)
}

@Test("同时按着其他修饰键不算双击起点")
func otherModifiersBlockTap() {
    var detector = DoubleTapDetector(modifier: .option)
    _ = detector.handleFlags([.option, .command], at: 0)
    _ = detector.handleFlags([.command], at: 0.05)
    _ = detector.handleFlags([], at: 0.06)
    #expect(detector.handleFlags([.option], at: 0.1) == false)
    _ = detector.handleFlags([], at: 0.15)
    #expect(detector.handleFlags([.option], at: 0.2) == true)
}

@Test("按住不放或系统重复上报不会触发")
func heldModifierDoesNotRepeat() {
    var detector = DoubleTapDetector(modifier: .control)
    #expect(detector.handleFlags([.control], at: 0) == false)
    #expect(detector.handleFlags([.control], at: 0.1) == false)
    #expect(detector.handleFlags([.control], at: 0.2) == false)
    _ = detector.handleFlags([], at: 0.25)
    #expect(detector.handleFlags([.control], at: 0.4) == false)
    _ = detector.handleFlags([], at: 0.45)
    #expect(detector.handleFlags([.control], at: 0.5) == true)
}

@Test("触发后归零，第三次按下重新计时")
func triggerResetsState() {
    var detector = DoubleTapDetector(modifier: .option)
    #expect(tap(&detector, .option, downAt: 0, upAt: 0.05) == false)
    _ = detector.handleFlags([], at: 0.06)
    #expect(detector.handleFlags([.option], at: 0.2) == true)
    _ = detector.handleFlags([], at: 0.25)
    #expect(detector.handleFlags([.option], at: 0.3) == false)
    _ = detector.handleFlags([], at: 0.35)
    #expect(detector.handleFlags([.option], at: 0.5) == true)
}

@Test("Caps Lock 等无关 flags 变化不打断计时")
func unrelatedFlagsDoNotReset() {
    var detector = DoubleTapDetector(modifier: .option)
    _ = detector.handleFlags([.option], at: 0)
    _ = detector.handleFlags([], at: 0.05)
    _ = detector.handleFlags([.capsLock], at: 0.1)
    _ = detector.handleFlags([], at: 0.12)
    #expect(detector.handleFlags([.option], at: 0.2) == true)
}

@Test("双击窗口边界按 0.3 秒")
func defaultIntervalIs300ms() {
    var detector = DoubleTapDetector(modifier: .option)
    _ = detector.handleFlags([.option], at: 0)
    _ = detector.handleFlags([], at: 0.05)
    #expect(detector.handleFlags([.option], at: 0.3) == true)

    var slow = DoubleTapDetector(modifier: .option)
    _ = slow.handleFlags([.option], at: 0)
    _ = slow.handleFlags([], at: 0.05)
    #expect(slow.handleFlags([.option], at: 0.3001) == false)
}
