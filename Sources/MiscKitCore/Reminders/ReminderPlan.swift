import Foundation
import os

/// 提醒种类。两套计划完全独立：各自的开关、间隔与时段。
public enum ReminderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case water
    case stand

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .water: return L10n.Reminder.Label.water
        case .stand: return L10n.Reminder.Label.stand
        }
    }
    public var symbol: String {
        switch self {
        case .water: return "drop.fill"
        case .stand: return "figure.stand"
        }
    }
    /// 默认间隔：喝水 60 分钟、站立 45 分钟
    public var defaultIntervalMinutes: Int {
        switch self {
        case .water: return 60
        case .stand: return 45
        }
    }
    public var reminderTitle: String {
        switch self {
        case .water: return L10n.Reminder.Overlay.titleWater
        case .stand: return L10n.Reminder.Overlay.titleStand
        }
    }
    public var reminderBody: String {
        switch self {
        case .water: return L10n.Reminder.Overlay.bodyWater
        case .stand: return L10n.Reminder.Overlay.bodyStand
        }
    }
}

/// 一天内的分钟数。调度只用它，不用字符串，避免时区/格式化歧义。
public struct MinuteOfDay: Codable, Equatable, Hashable, Sendable, Comparable {
    public var minutes: Int

    public init(minutes: Int) {
        self.minutes = min(max(minutes, 0), 24 * 60 - 1)
    }

    public init(hour: Int, minute: Int) { self.init(minutes: hour * 60 + minute) }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }

    public var display: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: MinuteOfDay, rhs: MinuteOfDay) -> Bool { lhs.minutes < rhs.minutes }
}

/// 单个提醒计划。`enabled == false` 时不参与调度，其余字段仍保留用户设定。
public struct ReminderPlan: Codable, Equatable, Sendable {
    public var kind: ReminderKind
    public var enabled: Bool
    public var intervalMinutes: Int
    public var windowStart: MinuteOfDay
    public var windowEnd: MinuteOfDay
    public var skipWeekends: Bool
    public var snoozeMinutes: Int

    public init(kind: ReminderKind, enabled: Bool = true, intervalMinutes: Int? = nil,
                windowStart: MinuteOfDay = MinuteOfDay(hour: 9, minute: 30),
                windowEnd: MinuteOfDay = MinuteOfDay(hour: 18, minute: 30),
                skipWeekends: Bool = true, snoozeMinutes: Int = 10) {
        self.kind = kind
        self.enabled = enabled
        self.intervalMinutes = max(5, intervalMinutes ?? kind.defaultIntervalMinutes)
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.skipWeekends = skipWeekends
        self.snoozeMinutes = max(1, snoozeMinutes)
    }

    /// 时段反了（18:30–09:30）按整段不可用处理，而不是悄悄交换：交换会让用户以为设错了还能跑。
    public var windowIsValid: Bool { windowStart < windowEnd }

    /// 决定「下一次在什么时候」的字段是否一致。`snoozeMinutes` 不在内：
    /// 改顺延时长不该把手上已经排好的那一次重置。
    public func sameSchedule(as other: ReminderPlan) -> Bool {
        enabled == other.enabled && intervalMinutes == other.intervalMinutes
            && windowStart == other.windowStart && windowEnd == other.windowEnd
            && skipWeekends == other.skipWeekends
    }
}

/// 免打扰时段。`ClosedRange` 本身不是 Codable，所以自己带一个壳。
public struct MinuteWindow: Codable, Equatable, Sendable, Hashable {
    public var start: MinuteOfDay
    public var end: MinuteOfDay

    public init(start: MinuteOfDay, end: MinuteOfDay) {
        self.start = start
        self.end = end
    }

    public var range: ClosedRange<MinuteOfDay> { start...end }
    public var isValid: Bool { start <= end }
    public var display: String { "\(start.display)–\(end.display)" }
}

/// 提醒时机的唯一裁决者：纯函数，可注入 now / calendar，所有跨天与周末分支都有单测。
public enum ReminderScheduler {
    /// 找不到下一个落在时段内的时刻（计划关闭、时段无效）时返回 nil。
    public static func nextFire(now: Date, lastDue: Date?, plan: ReminderPlan,
                                calendar: Calendar = .current) -> Date? {
        guard plan.enabled, plan.windowIsValid else { return nil }
        let interval = TimeInterval(plan.intervalMinutes * 60)
        var candidate = (lastDue ?? now).addingTimeInterval(interval)
        // 睡了三小时醒来时 lastDue 早已过期：以"现在 + 一个间隔"为准，不补发积压的每一次。
        if candidate < now { candidate = now.addingTimeInterval(interval) }
        return clamp(candidate, plan: plan, calendar: calendar)
    }

    /// 稍后：只顺延 snooze 时长，不再叠加一个完整间隔。
    public static func snoozed(from now: Date, plan: ReminderPlan,
                              calendar: Calendar = .current) -> Date? {
        guard plan.enabled, plan.windowIsValid else { return nil }
        return clamp(now.addingTimeInterval(TimeInterval(plan.snoozeMinutes * 60)),
                     plan: plan, calendar: calendar)
    }

    /// 计划被改动或唤醒之后重新排一次。
    ///
    /// 不能拿「还没到的排程」当 `nextFire` 的基准：设置页每敲一个数字都会提交一次计划，
    /// 每次提交都等于再往后推一个间隔，倒计时于是越改越长，而且排程在未来的那一次
    /// 永远不会被「过期重算」分支拉回来。只认两种情况——排期字段真变了（含首次启用、
    /// 唤醒后 `previous` 传 nil）从此刻重计，其余原样保留现排程。
    public static func rescheduled(now: Date, previous: ReminderPlan?, current: ReminderPlan,
                                   existing: Date?, calendar: Calendar = .current) -> Date? {
        guard current.enabled, current.windowIsValid else { return nil }
        if let previous, previous.sameSchedule(as: current),
           let existing, existing > now {
            return existing
        }
        return nextFire(now: now, lastDue: now, plan: current, calendar: calendar)
    }

    /// 把任意时刻往前推进到最近的合法触发点：时段内、且（按需）不是周末。
    private static func clamp(_ input: Date, plan: ReminderPlan, calendar: Calendar) -> Date? {
        var candidate = input
        let dateForMinute: (Date, Int) -> Date = { dayStart, minuteOfDay in
            calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60,
                          second: 0, of: dayStart)
                ?? calendar.date(byAdding: .minute, value: minuteOfDay, to: dayStart)
                ?? dayStart.addingTimeInterval(TimeInterval(minuteOfDay * 60))
        }
        let nextDayWindowStart: (Date) -> Date = { day in
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
                ?? calendar.startOfDay(for: day).addingTimeInterval(24 * 3600)
            return dateForMinute(nextDay, plan.windowStart.minutes)
        }
        // 最多往前找 400 天：足够覆盖"周末 + 长假"，又能保证异常输入不会死循环。
        for _ in 0..<400 {
            let startOfDay = calendar.startOfDay(for: candidate)
            if plan.skipWeekends && isWeekend(startOfDay, calendar: calendar) {
                candidate = nextDayWindowStart(startOfDay)
                continue
            }
            let windowStart = dateForMinute(startOfDay, plan.windowStart.minutes)
            let windowEnd = dateForMinute(startOfDay, plan.windowEnd.minutes)
            if candidate < windowStart {
                candidate = windowStart
                continue
            }
            if candidate > windowEnd {
                candidate = nextDayWindowStart(startOfDay)
                continue
            }
            return candidate
        }
        return nil
    }

    /// 周六/周日。`weekday` 按系统约定 1 = 周日、7 = 周六。
    static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// 倒计时用的整秒剩余；没有下次触发时返回 nil（面板显示「已暂停」）。
    public static func remaining(now: Date, next: Date?) -> Int? {
        guard let next else { return nil }
        return max(0, Int(next.timeIntervalSince(now)))
    }
}

/// 一次提醒的处置结果。只记「哪天、哪类、几点」，不记任何内容。
public struct ReminderRecord: Codable, Equatable, Sendable {
    public let kind: ReminderKind
    public let date: Date
    public let outcome: Outcome

    public enum Outcome: String, Codable, Sendable {
        case completed
        case snoozed
    }

    public init(kind: ReminderKind, date: Date, outcome: Outcome) {
        self.kind = kind
        self.date = date
        self.outcome = outcome
    }
}

/// 完成/稍后的流水。存 UserDefaults 的 JSON，只保留最近 30 天，供设置页统计。
public final class ReminderLogStore: @unchecked Sendable {
    public static let shared = ReminderLogStore()

    private let defaults: UserDefaults
    private let key = "reminder.log.v1"
    private let retentionDays = 30
    private let calendar: Calendar
    private let cache = OSAllocatedUnfairLock<[ReminderRecord]?>(initialState: nil)

    public init(store: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = store
        self.calendar = calendar
    }

    public var records: [ReminderRecord] { cachedRecords() }

    public func record(_ record: ReminderRecord) {
        cache.withLock { cached in
            var all = cached ?? loadFromDefaults()
            all.append(record)
            let kept = pruned(all, now: record.date)
            cached = kept
            persist(kept)
        }
    }

    public func count(kind: ReminderKind, on day: Date, now: Date? = nil) -> Int {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 3600)
        return cachedRecords().filter {
            $0.kind == kind && $0.outcome == .completed
                && $0.date >= dayStart && $0.date < dayEnd
        }.count
    }

    /// 最近 n 天（含今天）每天完成次数，缺日补 0，方便画柱状。
    public func dailyCounts(kind: ReminderKind, days: Int, now: Date) -> [(day: Date, count: Int)] {
        let today = calendar.startOfDay(for: now)
        let all = cachedRecords()
        return (0..<max(1, days)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let next = calendar.date(byAdding: .day, value: 1, to: day)
                ?? day.addingTimeInterval(24 * 3600)
            let count = all.filter {
                $0.kind == kind && $0.outcome == .completed && $0.date >= day && $0.date < next
            }.count
            return (day, count)
        }
    }

    public func prune(now: Date) {
        cache.withLock { cached in
            let current = cached ?? loadFromDefaults()
            let kept = pruned(current, now: now)
            cached = kept
            persist(kept)
        }
    }

    private func pruned(_ records: [ReminderRecord], now: Date) -> [ReminderRecord] {
        let todayStart = calendar.startOfDay(for: now)
        let floor = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: todayStart)
            ?? todayStart.addingTimeInterval(-Double(retentionDays - 1) * 24 * 3600)
        return records.filter { $0.date >= floor }
    }

    private func cachedRecords() -> [ReminderRecord] {
        cache.withLock { cached in
            if let cached { return cached }
            let loaded = loadFromDefaults()
            cached = loaded
            return loaded
        }
    }

    private func loadFromDefaults() -> [ReminderRecord] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ReminderRecord].self, from: data) else { return [] }
        return decoded
    }

    private func persist(_ records: [ReminderRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 不打扰判定要的状态。由 App 层采集（前台 App、全屏、专注时段），判定本身是纯函数。
public struct ReminderContext: Equatable, Sendable {
    public var frontmostBundleID: String?
    public var hasFullscreenWindow: Bool
    /// 用户自设的免打扰时段，可多段
    public var focusWindows: [ClosedRange<MinuteOfDay>]

    public init(frontmostBundleID: String? = nil, hasFullscreenWindow: Bool = false,
                focusWindows: [ClosedRange<MinuteOfDay>] = []) {
        self.frontmostBundleID = frontmostBundleID
        self.hasFullscreenWindow = hasFullscreenWindow
        self.focusWindows = focusWindows
    }
}

public enum ReminderSuppression {
    /// 命中任一条件就不该弹提醒：全屏、黑名单前台 App、自设专注时段。
    public static func isSuppressed(at date: Date, context: ReminderContext,
                                    blacklist: [String], calendar: Calendar = .current) -> Bool {
        if context.hasFullscreenWindow { return true }
        if let bundleID = context.frontmostBundleID,
           blacklist.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        let minute = MinuteOfDay(minutes: calendar.component(.hour, from: date) * 60
                                        + calendar.component(.minute, from: date))
        return context.focusWindows.contains { $0.contains(minute) }
    }
}
