import Foundation
import MiscKitCore

/// 进程级唯一性围栏：同一个二进制第二次启动时直接退出，不注册热键、不碰任何共享存储。
///
/// 为什么必须存在（2026-11-05 实测）：看门狗用 launchd 拉起一个实例，用户再从
/// 「打开 App」/`open -a` 走 LaunchServices 又起一个，两个进程互不知情——
/// · 全局热键各注册一次，按一下两个面板轮流上屏、互相抢焦点（失焦自动隐藏会被对面触发），
///   用户看到的就是"文字清不掉""placeholder 不见了""重新唤起还在"这类偶现现象；
/// · `UserDefaults` 没有跨进程协调，两边各揣一份内存态账户列表整键回写，
///   后写的那一份会把前一份的记录抹掉 —— OTP 记录消失走的就是这条。
///
/// 怎么做：对 Application Support 下的文件 `flock(LOCK_EX | LOCK_NB)`，拿不到锁就退出。
/// 锁随进程死亡由内核释放，不需要清锁文件，也不会留下"崩溃后起不来"的坑。
@MainActor
enum ProcessGuard {
    /// fd 故意不关也不置 nil：关掉等于主动放锁，下一个实例就能挤进来。
    nonisolated(unsafe) private static var lockDescriptor: Int32?

    enum Outcome: Equatable {
        case claimed
        /// 已有实例持有锁，带上它的 pid（埋点里能直接看到撞车的是谁）。
        case blockedBy(pid: Int32)
    }

    static func claimSingleton() -> Outcome {
        let directory = AppStoragePaths.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = AppStoragePaths.file("single.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { return .claimed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let holder = readHolder(descriptor)
            close(descriptor)
            return .blockedBy(pid: holder)
        }
        let text = "\(getpid())\n"
        _ = text.withCString {
            ftruncate(descriptor, 0)
            return write(descriptor, $0, strlen($0))
        }
        lockDescriptor = descriptor
        return .claimed
    }

    private static func readHolder(_ descriptor: Int32) -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 32)
        let read = pread(descriptor, &buffer, buffer.count - 1, 0)
        guard read > 0, let text = String(bytes: buffer[0..<read], encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return -1 }
        return pid
    }
}
