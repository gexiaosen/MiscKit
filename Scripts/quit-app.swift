// 让正在跑的 App 正常退出，等它真的没了才返回。
//
// 两个坑都实测踩过：
// 1. NSRunningApplication.terminate() 靠发 Quit Apple Event，没自动化授权时被静默丢掉
//    （6 秒退不掉）。所以走本地分布式通知，让 App 自己调 NSApp.terminate(nil)，不经过 TCC。
// 2. `runningApplications` 与 `isTerminated` 的登记都滞后：App 已经退完了还报"在跑"。
//    判活一律用 kill(pid, 0)。
import AppKit

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app.misckit.MiscKit"

func pids() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == bundleID }
        .map(\.processIdentifier)
        .filter { $0 > 0 }
}

func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

func waitGone(_ seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !pids().contains(where: alive) { return true }
        usleep(100_000)
    }
    return !pids().contains(where: alive)
}

let initial = pids().filter(alive)
if initial.isEmpty { exit(0) }

DistributedNotificationCenter.default().postNotificationName(
    .init("app.misckit.quit"), object: bundleID, userInfo: nil, deliverImmediately: true)
if waitGone(4) { print("通知退出"); exit(0) }

for pid in pids() where alive(pid) {
    if let app = NSRunningApplication(processIdentifier: pid) { _ = app.terminate() }
}
if waitGone(3) { print("terminate 退出"); exit(0) }

for pid in pids() where alive(pid) {
    if let app = NSRunningApplication(processIdentifier: pid) { _ = app.forceTerminate() }
}
if waitGone(3) { print("forceTerminate 退出"); exit(0) }

FileHandle.standardError.write("退不掉，旧实例还在跑\n".data(using: .utf8)!)
exit(2)
