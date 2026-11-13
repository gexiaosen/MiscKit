import AppKit
import CoreAudio
import Foundation

public enum SystemOutcome: Sendable, Equatable {
    case done
    /// 「设定音量…」要一个数值，由输入框接着填，不在这里瞎设。
    case needsValue
    case nothingToEject
}

public enum SystemControlError: Error, LocalizedError {
    case unavailable(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let what): return L10n.System.Error.unavailable(what)
        case .failed(let what, let reason): return L10n.System.Error.failed(what, reason)
        }
    }
}

/// 22 条系统动作的执行端。全部零 TCC 授权 —— 不弹任何权限框。
/// 只有锁屏与媒体键两处用私有符号，都靠 `dlsym` 运行时取；取不到就报不可用，不崩。
@MainActor
public enum SystemControl {
    public static func performAsync(_ id: String) async throws -> SystemOutcome {
        switch id {
        case "sleep":
            let name = SystemActionCatalog.action(id: id)?.title ?? id
            try await Task.detached(priority: .userInitiated) {
                try runPMSet("sleepnow", name: name)
            }.value
            return .done
        case "display-sleep":
            let name = SystemActionCatalog.action(id: id)?.title ?? id
            try await Task.detached(priority: .userInitiated) {
                try runPMSet("displaysleepnow", name: name)
            }.value
            return .done
        case "eject-volumes":
            return await Task.detached(priority: .userInitiated) {
                ejectVolumes()
            }.value
        default:
            return try perform(id)
        }
    }

    public static func perform(_ id: String) throws -> SystemOutcome {
        // 「音量 30」不是目录里的一条固定动作，参数拼成 volume:30 传进来。
        if id.hasPrefix("volume:"), let percent = Int(id.dropFirst("volume:".count)) {
            try setVolume(percent)
            return .done
        }
        guard let action = SystemActionCatalog.action(id: id) else {
            throw SystemControlError.unavailable(L10n.System.Error.actionLabel(id))
        }
        let name = action.title
        switch id {
        case "lock-screen":
            try lockScreen()
        case "sleep":
            try runPMSet("sleepnow", name: name)
        case "display-sleep":
            try runPMSet("displaysleepnow", name: name)
        case "screen-saver":
            try screenSaver()
        case "play-pause":
            try mediaCommand(2, name: name)
        case "previous-track":
            try mediaCommand(5, name: name)
        case "next-track":
            try mediaCommand(4, name: name)
        case "mute":
            try toggleMute()
        case "mic-mute":
            try toggleInputMute(name: name)
        case "volume-up":
            try adjustVolume(by: 6)
        case "volume-down":
            try adjustVolume(by: -6)
        case "volume-0":
            try setVolume(0)
        case "volume-25":
            try setVolume(25)
        case "volume-50":
            try setVolume(50)
        case "volume-75":
            try setVolume(75)
        case "volume-100":
            try setVolume(100)
        case "volume-set":
            return .needsValue
        case "show-desktop":
            // 用 AppKit 的菜单级动作，别逐个 NSRunningApplication.hide()：
            // 那个走 Apple Event，没有自动化授权时被静默丢掉（2026-11-10 实测三条全是空转）。
            NSApp.hideOtherApplications(nil)
            NSApp.hide(nil)
        case "hide-others":
            NSApp.hideOtherApplications(nil)
        case "unhide-all":
            NSApp.unhideAllApplications(nil)
        case "open-trash":
            let trash = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
            guard NSWorkspace.shared.open(trash) else {
                throw SystemControlError.failed(name, L10n.System.Error.finderRejected)
            }
        case "eject-volumes":
            return ejectVolumes()
        default:
            throw SystemControlError.unavailable(name)
        }
        return .done
    }

    // MARK: 音量

    public static func currentVolume() -> Int? {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        guard let scalar = volumeScalar(device: device, scope: kAudioObjectPropertyScopeOutput) else {
            return nil
        }
        return Int((scalar * 100).rounded())
    }

    public static func isMuted() -> Bool? {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return muteState(device: device, scope: kAudioObjectPropertyScopeOutput)
    }

    public static func setVolume(_ percent: Int) throws {
        let clamped = Float(min(max(percent, 0), 100)) / 100
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            throw SystemControlError.unavailable(L10n.System.Error.defaultOutputDevice)
        }
        try setScalar(clamped, device: device, scope: kAudioObjectPropertyScopeOutput)
        // 从 0 拉起来时系统还记着静音，声音不会回来。
        if clamped > 0, muteState(device: device, scope: kAudioObjectPropertyScopeOutput) == true {
            try setMute(false, device: device, scope: kAudioObjectPropertyScopeOutput)
        }
    }

    public static func adjustVolume(by delta: Int) throws {
        let current = currentVolume() ?? 50
        try setVolume(current + delta)
    }

    private static func toggleMute() throws {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            throw SystemControlError.unavailable(L10n.System.Error.defaultOutputDevice)
        }
        let muted = muteState(device: device, scope: kAudioObjectPropertyScopeOutput) ?? false
        try setMute(!muted, device: device, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func toggleInputMute(name: String) throws {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else {
            throw SystemControlError.unavailable(L10n.System.Error.defaultInputDevice)
        }
        if let muted = muteState(device: device, scope: kAudioObjectPropertyScopeInput) {
            try setMute(!muted, device: device, scope: kAudioObjectPropertyScopeInput)
            return
        }
        // 一部分 USB 麦克风没有 mute 属性，只能把输入音量压到 0。恢复靠再跑一次。
        guard let scalar = volumeScalar(device: device, scope: kAudioObjectPropertyScopeInput) else {
            throw SystemControlError.unavailable(L10n.System.Error.micMute)
        }
        try setScalar(scalar > 0 ? 0 : 1, device: device, scope: kAudioObjectPropertyScopeInput)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// 有些设备只有分声道的 volume，主 element 上根本没有这个属性。
    private static func volumeElements(_ device: AudioDeviceID,
                                       scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        var main = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }
        var elements: [AudioObjectPropertyElement] = []
        for channel in 1...8 {
            let element = AudioObjectPropertyElement(channel)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: scope, mElement: element)
            if AudioObjectHasProperty(device, &address) { elements.append(element) }
        }
        return elements
    }

    private static func volumeScalar(device: AudioDeviceID,
                                     scope: AudioObjectPropertyScope) -> Float? {
        let elements = volumeElements(device, scope: scope)
        guard !elements.isEmpty else { return nil }
        var total: Float = 0
        var counted: Float = 0
        for element in elements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: scope, mElement: element)
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                total += value
                counted += 1
            }
        }
        return counted > 0 ? total / counted : nil
    }

    private static func setScalar(_ value: Float, device: AudioDeviceID,
                                  scope: AudioObjectPropertyScope) throws {
        let elements = volumeElements(device, scope: scope)
        guard !elements.isEmpty else { throw SystemControlError.unavailable(L10n.System.Error.volumeControl) }
        var failures = 0
        for element in elements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: scope, mElement: element)
            var value = value
            let size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) != noErr {
                failures += 1
            }
        }
        guard failures < elements.count else {
            throw SystemControlError.failed(L10n.System.Error.volumeLabel, L10n.System.Error.deviceRejected)
        }
    }

    private static func muteState(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool? {
        guard let element = muteElement(device, scope: scope) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: scope, mElement: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    private static func setMute(_ muted: Bool, device: AudioDeviceID,
                                scope: AudioObjectPropertyScope) throws {
        guard let element = muteElement(device, scope: scope) else {
            throw SystemControlError.unavailable(L10n.System.Error.muteControl)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: scope, mElement: element)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr else {
            throw SystemControlError.failed(
                muted ? L10n.System.Error.muteLabel : L10n.System.Error.unmuteLabel,
                L10n.System.Error.deviceRejected
            )
        }
    }

    private static func muteElement(_ device: AudioDeviceID,
                                    scope: AudioObjectPropertyScope) -> AudioObjectPropertyElement? {
        var main = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return kAudioObjectPropertyElementMain }
        for channel in 1...8 {
            let element = AudioObjectPropertyElement(channel)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: scope, mElement: element)
            if AudioObjectHasProperty(device, &address) { return element }
        }
        return nil
    }

    // MARK: 私有符号

    private typealias LockScreenFunction = @convention(c) () -> Void
    private typealias MediaCommandFunction = @convention(c) (Int32, CFDictionary?) -> Bool

    private static let lockScreenFunction: LockScreenFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFunction.self)
    }()

    private static let mediaCommandFunction: MediaCommandFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                                  RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: MediaCommandFunction.self)
    }()

    private static func lockScreen() throws {
        guard let lockScreenFunction else { throw SystemControlError.unavailable(L10n.System.Error.lockScreen) }
        lockScreenFunction()
    }

    private static func mediaCommand(_ command: Int32, name: String) throws {
        guard let mediaCommandFunction, mediaCommandFunction(command, nil) else {
            throw SystemControlError.unavailable(name)
        }
    }

    // MARK: 其余

    nonisolated private static func runPMSet(_ verb: String, name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [verb]
        do {
            try process.run()
        } catch {
            throw SystemControlError.failed(name, error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SystemControlError.failed(name, L10n.System.Error.pmsetExit(process.terminationStatus))
        }
    }

    private static func screenSaver() throws {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("MiscKit 屏幕保护启动失败: %@", error.localizedDescription)
            }
        }
    }

    nonisolated private static func ejectVolumes() -> SystemOutcome {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey, .volumeIsEjectableKey],
            options: [.skipHiddenVolumes]) ?? []
        var ejected = 0
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: [.volumeIsEjectableKey]),
                  values.volumeIsEjectable == true
            else { continue }
            if (try? NSWorkspace.shared.unmountAndEjectDevice(at: url)) != nil { ejected += 1 }
        }
        return ejected == 0 ? .nothingToEject : .done
    }
}
