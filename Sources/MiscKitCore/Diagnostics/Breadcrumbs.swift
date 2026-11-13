import Darwin
import Foundation
import os

/// 崩溃面包屑：低频状态快照，写统一日志的 `notice` 级（默认持久化，
/// `log show` 不带 `--info` 也读得到）。
///
/// 只记**状态**，不记输入内容：搜索词可能来自剪贴板带入的敏感文本。
/// 每条自动带内存占用与进程运行时长，用来判断是否与长时间运行/内存压力相关。
public enum Breadcrumbs {
    private static let log = Logger(subsystem: "app.misckit.launcher", category: "breadcrumb")
    private static let started = Date()

    public static func event(_ name: String, _ fields: [String: String] = [:]) {
        var all = fields
        all["mem"] = String(format: "%.0fMB", memoryFootprintMB())
        all["up"] = String(format: "%.0fs", Date().timeIntervalSince(started))
        let suffix = all.keys.sorted()
            .map { "\($0)=\(all[$0] ?? "")" }
            .joined(separator: " ")
        log.notice("\(name, privacy: .public) \(suffix, privacy: .public)")
    }

    /// 当前进程的物理足迹（不是常驻集）：崩溃前若一路涨，能看出是内存相关。
    public static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
