import AppKit
import Foundation

/// 全 App 唯一的剪贴板**写入口**，并且负责验证码复制后自动清出剪贴板。
///
/// 只在"剪贴板还是我们写的那一份"时才清：用户中途复制了别的东西就不该被我们抹掉，
/// 所以记 changeCount 而不是记内容。
///
/// `lastOwnChangeCount` 还服务另一件事：唤起面板时会自动带入刚复制的内容
/// （`ClipboardPrefill`），而**我们自己刚复制的验证码/会议号绝不能被带进搜索框**——
/// 那会把密钥摊在一个 22pt 的输入条上。收成一个写入口，这条排除才是结构事实而不是约定。
@MainActor
public final class ClipboardGuard {
    public static let shared = ClipboardGuard()

    /// 清剪贴板前的停留秒数
    public var lifetime: TimeInterval = 60

    /// 最后一次由本 App 写入时的 changeCount；`ClipboardWatch` 用它识别"这份是我们自己复制的"。
    public private(set) var lastOwnChangeCount: Int?

    private var task: Task<Void, Never>?
    /// 单测注入一块**私有命名板**：动 `general` 会把用户真剪贴板抹掉，
    /// 而且任何别的 App 中途复制一下，这条用例就红了（实测偶发失败过一次）。
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// 普通写入（路径、会议号、整张稿纸）。
    @discardableResult
    public func write(_ text: String) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        lastOwnChangeCount = pasteboard.changeCount
        return true
    }

    /// 密钥：写完登记，并起一条 60 秒的自动清出。
    @discardableResult
    public func copySecret(_ text: String) -> Bool {
        guard write(text) else { return false }
        scheduleClear()
        return true
    }

    /// 复制**文件本身**：写进去的是文件引用而不是文字，访达/微信/Word 粘贴时按各自规则取文件。
    /// `clearContents` 不能省：实测 `writeObjects` 不顶掉旧内容，上一段文字还留在板上，
    /// 粘贴方完全可能拿到那段文字而不是这些文件。changeCount 也要登记 —— 少了那一行，
    /// 面板会把「刚自己复制的文件」当成外部新复制的内容带进搜索框。
    @discardableResult
    public func copyFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        lastOwnChangeCount = pasteboard.changeCount
        return true
    }

    private func scheduleClear() {
        task?.cancel()
        let expected = pasteboard.changeCount
        let seconds = lifetime
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.clearIfStillOurs(expected)
        }
    }

    private func clearIfStillOurs(_ expected: Int) {
        guard pasteboard.changeCount == expected else { return }
        pasteboard.clearContents()
        // 清空也是"我们动的手"，一并登记，免得面板把空剪贴板当成刚复制的内容
        lastOwnChangeCount = pasteboard.changeCount
    }

    /// 面板关掉/切走时不取消：60 秒到了还是该清。只有显式撤销才停。
    public func cancelPendingClear() {
        task?.cancel()
        task = nil
    }
}
