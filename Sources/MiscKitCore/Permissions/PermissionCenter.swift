import AppKit
import IOKit.hid
import Observation

public enum PermissionState: String, Sendable {
    case granted
    case denied
    case notDetermined
    case unavailableOnThisOS

    public var label: String {
        switch self {
        case .granted: return L10n.Permissions.granted
        case .denied: return L10n.Permissions.denied
        case .notDetermined: return L10n.Permissions.notDetermined
        case .unavailableOnThisOS: return L10n.Permissions.unavailable
        }
    }

    public var isGranted: Bool { self == .granted }
}

/// 需要引导用户去系统设置里授予的权限面板。
/// 只列 MiscKit 真的用得到的：`inputMonitoring`（双击修饰键唤起读全局事件）。
/// 「辅助功能」「屏幕录制」不在列——全仓库没有对应的 API 调用，不申请、也不展示。
public enum PermissionPane: String, Sendable {
    case inputMonitoring
    case filesAndFolders

    var settingsURL: String {
        switch self {
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .filesAndFolders:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        }
    }
}

/// 受限功能的权限真相来源。设置页与功能降级提示都读这里，
/// 避免各处自己判断权限。
@MainActor
@Observable
public final class PermissionCenter {
    public static let shared = PermissionCenter()

    public private(set) var inputMonitoring: PermissionState = .notDetermined

    private init() {}

    /// 只在值真的变了才写：视图和 `observeSummonChange` 都在观察这些属性，
    /// 定时重读若每次赋值会把"没变化"也当成一次变更，快捷键会被反复重注册。
    public func refresh() {
        let input: PermissionState
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: input = .granted
        case kIOHIDAccessTypeDenied: input = .denied
        default: input = .notDetermined
        }
        if inputMonitoring != input { inputMonitoring = input }
    }

    /// 弹系统授权窗。注意：授予后进程需重启才能完全生效。
    public func promptInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refresh()
    }

    public func openSettings(_ pane: PermissionPane) {
        guard let url = URL(string: pane.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}