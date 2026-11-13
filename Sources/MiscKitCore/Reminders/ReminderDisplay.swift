import Foundation

/// 「下一次」文案的唯一出口：菜单栏标题与提醒面板卡共用，两处不会各写一套格式。
///
/// 今天之内报剩余时长；一旦跨到明天或跳过周末就报目标时刻——
/// 「17:36:44」这种十几个小时的倒计时在菜单栏里读起来像计时器坏了，
/// 而它其实只是「等到明天时段开头」。
public enum ReminderDisplay {
    /// 秒 → `m:ss`，超过一小时 → `h:mm:ss`。
    public static func clockText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        if clamped >= 3600 {
            return String(format: "%d:%02d:%02d", clamped / 3600, clamped % 3600 / 60, clamped % 60)
        }
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// 菜单栏用的分钟级读数：向上取整，避免显示「0 分」时其实还没到点。
    public static func minuteText(_ seconds: Int) -> String {
        let minutes = (max(0, seconds) + 59) / 60
        guard minutes >= 60 else { return L10n.Reminder.Display.minutes(minutes) }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? L10n.Reminder.Display.hours(hours) : L10n.Reminder.Display.hoursMinutes(hours, rest)
    }

    /// 不带前缀的值：`45:00` / `明日 09:30` / `周一 09:30`。
    public static func value(now: Date, next: Date, calendar: Calendar = .current) -> String {
        guard next > now else { return clockText(0) }
        if calendar.isDate(next, inSameDayAs: now) {
            return clockText(Int(next.timeIntervalSince(now)))
        }
        let target = clock(next, calendar: calendar)
        if isTomorrow(next, now: now, calendar: calendar) { return L10n.Reminder.Display.tomorrow(target) }
        return "\(weekday(next, calendar: calendar)) \(target)"
    }

    /// 菜单栏用的分钟级值：今天之内报剩余分钟，跨天仍报目标时刻。
    /// 菜单栏每秒改 title 会整块重绘状态栏快照，这里只到分钟，重绘次数随之降到 1/60。
    public static func menuBarValue(now: Date, next: Date, calendar: Calendar = .current) -> String {
        guard next > now else { return minuteText(0) }
        if calendar.isDate(next, inSameDayAs: now) {
            return minuteText(Int(next.timeIntervalSince(now)))
        }
        let target = clock(next, calendar: calendar)
        if isTomorrow(next, now: now, calendar: calendar) { return L10n.Reminder.Display.tomorrow(target) }
        return "\(weekday(next, calendar: calendar)) \(target)"
    }

    /// 面板卡用的整句：今天说「距下次 45:00」，跨天说「下次 明日 09:30」。
    public static func phrase(now: Date, next: Date, calendar: Calendar = .current) -> String {
        let v = value(now: now, next: next, calendar: calendar)
        return calendar.isDate(next, inSameDayAs: now)
            ? L10n.Reminder.Display.inPrefix(v)
            : L10n.Reminder.Display.nextPrefix(v)
    }

    static func isTomorrow(_ next: Date, now: Date, calendar: Calendar) -> Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: now)) else { return false }
        return calendar.isDate(next, inSameDayAs: tomorrow)
    }

    private static func weekday(_ next: Date, calendar: Calendar) -> String {
        let index = max(0, min(6, calendar.component(.weekday, from: next) - 1))
        return L10n.Reminder.Display.weekday(index)
    }

    private static func clock(_ next: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: next)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
