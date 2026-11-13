import AppKit

public enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case command
    case option
    case control
    case shift

    public var label: String {
        switch self {
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        }
    }

    public var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    public var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }
}

/// 双击修饰键的判定逻辑。只看"按下"沿：两次独立按下且间隔不超过 interval，
/// 期间不能出现普通按键或其他修饰键（否则是在用组合键，不算双击）。
public struct DoubleTapDetector: Sendable {
    public static let defaultInterval: TimeInterval = 0.3

    public let modifier: ModifierKey
    public let interval: TimeInterval

    private var wasDown = false
    private var lastPressAt: TimeInterval?

    public init(modifier: ModifierKey, interval: TimeInterval = DoubleTapDetector.defaultInterval) {
        self.modifier = modifier
        self.interval = interval
    }

    public mutating func handleFlags(_ flags: NSEvent.ModifierFlags, at now: TimeInterval) -> Bool {
        let active = flags.intersection([.command, .option, .control, .shift])
        let down = active.contains(modifier.flag)
        let changed = down != wasDown
        wasDown = down
        guard changed, down else { return false }

        guard active.subtracting(modifier.flag).isEmpty else {
            lastPressAt = nil
            return false
        }
        if let last = lastPressAt, now - last <= interval {
            lastPressAt = nil
            return true
        }
        lastPressAt = now
        return false
    }

    /// 任何普通按键都说明用户在打字或用组合键，清掉第一次按下的记录。
    public mutating func handleKeyDown() {
        lastPressAt = nil
    }

    public mutating func reset() {
        wasDown = false
        lastPressAt = nil
    }
}

/// 全局双击修饰键监视。隐藏面板时事件走 global monitor，面板可见并接收键盘时走 local monitor；
/// 全局键盘监视需要"输入监控"权限，授权前调用方应保留组合键作为回退。
@MainActor
public final class DoubleTapMonitor {
    public static let shared = DoubleTapMonitor()

    public var onTrigger: (() -> Void)?
    public private(set) var isMonitoring = false

    private var detector: DoubleTapDetector?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    public func start(modifier: ModifierKey) {
        stop()
        detector = DoubleTapDetector(modifier: modifier)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
        isMonitoring = true
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        detector = nil
        isMonitoring = false
    }

    private func handle(_ event: NSEvent) {
        guard var detector else { return }
        var triggered = false
        switch event.type {
        case .flagsChanged:
            triggered = detector.handleFlags(event.modifierFlags, at: event.timestamp)
        case .keyDown:
            detector.handleKeyDown()
        default:
            break
        }
        self.detector = detector
        if triggered { onTrigger?() }
    }
}
