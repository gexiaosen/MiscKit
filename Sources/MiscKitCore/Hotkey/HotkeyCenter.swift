import AppKit
import Carbon.HIToolbox
import Observation

public struct HotkeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 默认唤起键：⌥Z（与 ZTools 一致，且不需要辅助功能权限）
    public static let defaultSummon = HotkeyCombo(keyCode: UInt32(kVK_ANSI_Z),
                                                  carbonModifiers: UInt32(optionKey))

    /// 至少要一个修饰键，否则会和正常打字抢事件
    public var isValid: Bool { carbonModifiers != 0 }

    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    public var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + HotkeyCombo.keyName(for: keyCode)
    }

    /// US 布局静态表。非 US 布局下显示名可能与键帽不同，但注册用的是 keyCode，行为不受影响。
    public static func keyName(for keyCode: UInt32) -> String {
        if let letter = letters[Int(keyCode)] { return letter }
        if let digit = digits[Int(keyCode)] { return digit }
        if let special = specials[Int(keyCode)] { return special }
        if keyCode >= UInt32(kVK_F1) && keyCode <= UInt32(kVK_F12) {
            return "F\(Int(keyCode) - Int(kVK_F1) + 1)"
        }
        return "key\(keyCode)"
    }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_S: "S", kVK_ANSI_D: "D", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_J: "J", kVK_ANSI_K: "K",
        kVK_ANSI_L: "L", kVK_ANSI_Q: "Q", kVK_ANSI_W: "W", kVK_ANSI_E: "E",
        kVK_ANSI_R: "R", kVK_ANSI_T: "T", kVK_ANSI_Y: "Y", kVK_ANSI_U: "U",
        kVK_ANSI_I: "I", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Z: "Z",
        kVK_ANSI_X: "X", kVK_ANSI_C: "C", kVK_ANSI_V: "V", kVK_ANSI_B: "B",
        kVK_ANSI_N: "N", kVK_ANSI_M: "M",
    ]

    private static let digits: [Int: String] = [
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_ANSI_0: "0",
    ]

    private static let specials: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
    ]
}

public enum HotkeyKeys {
    public static let summon = "summon"
    public static let appPrefix = "app."
    public static let hostsPrefix = "hosts."
    public static let otpPrefix = "otp."

    public static func app(_ id: String) -> String { appPrefix + id }
    public static func hostsSection(_ id: UUID) -> String { hostsPrefix + id.uuidString }
    public static func otpIssuer(_ issuer: String) -> String { otpPrefix + issuer }

    /// 旧版本存的是裸 bundleID（当时只有应用能绑键）。迁移时不猜：
    /// 没有任何已知前缀的一律按应用处理。
    public static func normalized(key: String) -> String {
        if key == summon { return summon }
        if key.hasPrefix(appPrefix) || key.hasPrefix(hostsPrefix) || key.hasPrefix(otpPrefix) {
            return key
        }
        return appPrefix + key
    }

    public enum Target: Equatable, Sendable {
        case summon
        case app(bundleID: String)
        case hostsSection(id: UUID)
        case otpIssuer(String)
    }

    /// 键名 → 目标。所有分发都过这里，新增前缀时编译器会逼着补 switch。
    public static func target(for key: String) -> Target? {
        if key == summon { return .summon }
        if key.hasPrefix(appPrefix) { return .app(bundleID: String(key.dropFirst(appPrefix.count))) }
        if key.hasPrefix(hostsPrefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(hostsPrefix.count))) else { return nil }
            return .hostsSection(id: id)
        }
        if key.hasPrefix(otpPrefix) { return .otpIssuer(String(key.dropFirst(otpPrefix.count))) }
        return nil
    }
}

/// Carbon 全局热键。实测在 macOS 26 未废弃，且不需要辅助功能权限。
/// 刻意不使用 CGEventTap（辅助功能被撤销时 .defaultTap 有系统级输入挂起风险）。
@MainActor
@Observable
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    /// 每个动作键单独记错：批量注册时，一次成功不能把别的失败冲掉。
    public private(set) var errors: [String: String] = [:]
    public var registrationError: String? { errors.values.sorted().first }
    public private(set) var registeredKeys: Set<String> = []
    public var onAction: ((String) -> Void)?

    private var refs: [String: EventHotKeyRef] = [:]
    private var keysByID: [UInt32: String] = [:]
    private var nextID: UInt32 = 2
    private var handlerRef: EventHandlerRef?
    private var installed = false

    private init() {}

    public func install() {
        guard !installed else { return }
        hotkeyTrampoline = { [weak self] id in
            Task { @MainActor in
                guard let self, let key = self.keysByID[id] else { return }
                self.onAction?(key)
            }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(),
                                         miscKitHotkeyEventHandler,
                                         1, &spec, nil, &handlerRef)
        installed = (status == noErr)
        if !installed {
            errors["event-handler"] = L10n.Hotkey.handlerFailed(status)
        }
    }

    @discardableResult
    public func register(key: String, combo: HotkeyCombo) -> Bool {
        install()
        unregister(key: key)
        guard installed else {
            errors[key] = errors["event-handler"] ?? L10n.Hotkey.handlerUnavailable
            return false
        }
        guard combo.isValid else {
            errors[key] = L10n.Hotkey.missingModifier
            return false
        }

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: miscKitSignature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            errors[key] = L10n.Hotkey.conflict(combo.displayString, status)
            return false
        }

        refs[key] = ref
        keysByID[id] = key
        registeredKeys.insert(key)
        errors[key] = nil
        return true
    }

    public func unregister(key: String) {
        if let ref = refs.removeValue(forKey: key) {
            UnregisterEventHotKey(ref)
        }
        keysByID = keysByID.filter { $0.value != key }
        registeredKeys.remove(key)
        errors[key] = nil
    }

    public func unregisterAll() {
        for key in Array(refs.keys) { unregister(key: key) }
    }
}

private let miscKitSignature: OSType = 0x4D49_5343 // "MISC"

nonisolated(unsafe) private var hotkeyTrampoline: ((UInt32) -> Void)?

private func miscKitHotkeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                      _ event: EventRef?,
                                      _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }
    guard let trampoline = hotkeyTrampoline else { return OSStatus(eventNotHandledErr) }
    trampoline(hotKeyID.id)
    return noErr
}
