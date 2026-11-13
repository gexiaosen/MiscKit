import Foundation

/// 提醒统计的"应该完成多少次"。纯函数，视图与测试共用。
public enum ReminderTarget {
    /// 一整天理论应完成次数：窗口分钟 ÷ 间隔；周末跳过时为 0。
    public static func perDay(plan: ReminderPlan, day: Date,
                              calendar: Calendar = .current) -> Int {
        guard plan.enabled, plan.windowIsValid else { return 0 }
        if plan.skipWeekends, ReminderScheduler.isWeekend(day, calendar: calendar) { return 0 }
        let minutes = plan.windowEnd.minutes - plan.windowStart.minutes
        return max(0, minutes / max(1, plan.intervalMinutes))
    }

    /// 到 `now` 为止应完成的次数：过去的日子按整天；今天按已过时段折算；未来为 0。
    public static func expectedSoFar(plan: ReminderPlan, day: Date, now: Date,
                                     calendar: Calendar = .current) -> Int {
        let full = perDay(plan: plan, day: day, calendar: calendar)
        guard full > 0 else { return 0 }
        let dayStart = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        if dayStart < today { return full }
        if dayStart > today { return 0 }

        let windowStart = calendar.date(byAdding: .minute, value: plan.windowStart.minutes, to: dayStart)
            ?? dayStart.addingTimeInterval(TimeInterval(plan.windowStart.minutes * 60))
        let windowEnd = calendar.date(byAdding: .minute, value: plan.windowEnd.minutes, to: dayStart)
            ?? dayStart.addingTimeInterval(TimeInterval(plan.windowEnd.minutes * 60))
        if now <= windowStart { return 0 }
        if now >= windowEnd { return full }
        let elapsed = now.timeIntervalSince(windowStart)
        let slots = Int(elapsed / TimeInterval(plan.intervalMinutes * 60))
        return min(full, max(0, slots))
    }
}
