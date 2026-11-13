import Foundation
import Testing

@testable import MiscKitCore

/// 所有时间断言都用这个固定时区的日历，避免测试跟着机器时区漂。
private func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.firstWeekday = 1
    return calendar
}

private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                  _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute))!
}

private func stamp(_ calendar: Calendar, _ date: Date?) -> String {
    guard let date else { return "nil" }
    let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    return String(format: "%02d-%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0,
                  parts.hour ?? 0, parts.minute ?? 0)
}

@Suite("喝水/站立：下次触发时间计算")
struct ReminderSchedulerTests {
    private let calendar = fixedCalendar()

    private func plan(kind: ReminderKind = .water, enabled: Bool = true,
                      interval: Int = 60, start: Int = 9 * 60 + 30, end: Int = 18 * 60 + 30,
                      skipWeekends: Bool = true) -> ReminderPlan {
        ReminderPlan(kind: kind, enabled: enabled, intervalMinutes: interval,
                     windowStart: MinuteOfDay(minutes: start), windowEnd: MinuteOfDay(minutes: end),
                     skipWeekends: skipWeekends)
    }

    @Test("时段内按间隔推进")
    func advancesInsideWindow() {
        let noon = date(calendar, 2026, 10, 20, 12)
        let next = ReminderScheduler.nextFire(now: noon, lastDue: nil, plan: plan(), calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 13:00", "12:00 + 60min 应落在 13:00")
    }

    @Test("跨过时段末尾时挪到次日时段开头")
    func rollsIntoNextDay() {
        let late = date(calendar, 2026, 10, 20, 18, 10)
        let next = ReminderScheduler.nextFire(now: late, lastDue: nil, plan: plan(), calendar: calendar)
        #expect(stamp(calendar, next) == "10-21 09:30")
    }

    @Test("时段开始之前的第一次提醒落在时段开头，而不是立刻")
    func clampsToWindowStart() {
        let early = date(calendar, 2026, 10, 20, 7)
        let next = ReminderScheduler.nextFire(now: early, lastDue: nil, plan: plan(), calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 09:30")
    }

    @Test("周五收盘后的下一次是周一，跳过整个周末")
    func skipsWeekend() {
        // 2026-10-23 是周五
        let friday = date(calendar, 2026, 10, 23, 18, 20)
        let next = ReminderScheduler.nextFire(now: friday, lastDue: nil, plan: plan(), calendar: calendar)
        #expect(stamp(calendar, next) == "10-26 09:30", "应跳到周一 09:30")
        if let next {
            #expect(ReminderScheduler.isWeekend(next, calendar: calendar) == false)
        }
    }

    @Test("不跳周末时周六照常提醒")
    func weekendIncluded() {
        // 2026-10-24 是周六
        let saturday = date(calendar, 2026, 10, 24, 12)
        let next = ReminderScheduler.nextFire(now: saturday, lastDue: nil,
                                             plan: plan(skipWeekends: false), calendar: calendar)
        #expect(stamp(calendar, next) == "10-24 13:00")
    }

    @Test("关闭或时段无效时没有下次触发")
    func disabledOrInvalidWindow() {
        let noon = date(calendar, 2026, 10, 20, 12)
        #expect(ReminderScheduler.nextFire(now: noon, lastDue: nil,
                                          plan: plan(enabled: false), calendar: calendar) == nil)
        #expect(ReminderScheduler.nextFire(now: noon, lastDue: nil,
                                          plan: plan(start: 18 * 60, end: 9 * 60),
                                          calendar: calendar) == nil, "时段反了不算跨夜窗口")
    }

    @Test("睡眠三小时醒来后只排一次，不补发积压")
    func noBurstAfterWake() {
        let beforeSleep = date(calendar, 2026, 10, 20, 13)
        let woke = date(calendar, 2026, 10, 20, 16, 5)
        let next = ReminderScheduler.nextFire(now: woke, lastDue: beforeSleep, plan: plan(),
                                             calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 17:05", "以醒来时刻为基准，不连发 14:00/15:00/16:00")
    }

    @Test("稍后按 snooze 顺延，贴到时段末尾时进次日")
    func snoozeReschedules() {
        let midday = date(calendar, 2026, 10, 20, 14)
        let pushed = ReminderScheduler.snoozed(from: midday, plan: plan(), calendar: calendar)
        #expect(stamp(calendar, pushed) == "10-20 14:10")

        let nearEnd = date(calendar, 2026, 10, 20, 18, 25)
        let rolled = ReminderScheduler.snoozed(from: nearEnd, plan: plan(), calendar: calendar)
        #expect(stamp(calendar, rolled) == "10-21 09:30")
    }

    @Test("间隔下限 5 分钟，防止误设成 0 导致连发")
    func intervalFloor() {
        let noon = date(calendar, 2026, 10, 20, 12)
        let tight = ReminderScheduler.nextFire(now: noon, lastDue: nil,
                                              plan: plan(interval: 0), calendar: calendar)
        #expect(stamp(calendar, tight) == "10-20 12:05")
    }

    @Test("倒计时剩余秒数不为负，无下次时返回 nil")
    func remainingClamped() {
        let now = date(calendar, 2026, 10, 20, 12)
        #expect(ReminderScheduler.remaining(now: now, next: now.addingTimeInterval(90)) == 90)
        #expect(ReminderScheduler.remaining(now: now, next: now.addingTimeInterval(-10)) == 0)
        #expect(ReminderScheduler.remaining(now: now, next: nil) == nil)
    }

    @Test("跨午夜与夏令时切换日保持目标时刻分钟精度")
    func preservesMinutePrecisionAcrossMidnightAndDST() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        dstCalendar.firstWeekday = 1

        let customPlan = plan(start: 9 * 60 + 47, end: 18 * 60 + 30, skipWeekends: false)

        // 普通跨午夜
        let weekdayLate = date(calendar, 2026, 10, 20, 18, 10)
        let weekdayNext = ReminderScheduler.nextFire(now: weekdayLate, lastDue: nil, plan: customPlan,
                                                     calendar: calendar)
        #expect(stamp(calendar, weekdayNext) == "10-21 09:47")

        // 夏令时春拨（2026-03-08 少 1 小时）
        let springEve = date(dstCalendar, 2026, 3, 7, 18, 10)
        let springNext = ReminderScheduler.nextFire(now: springEve, lastDue: nil, plan: customPlan,
                                                    calendar: dstCalendar)
        #expect(stamp(dstCalendar, springNext) == "03-08 09:47")

        // 夏令时秋拨（2026-11-01 多 1 小时）
        let fallEve = date(dstCalendar, 2026, 10, 31, 18, 10)
        let fallNext = ReminderScheduler.nextFire(now: fallEve, lastDue: nil, plan: customPlan,
                                                  calendar: dstCalendar)
        #expect(stamp(dstCalendar, fallNext) == "11-01 09:47")
    }
}

/// 设置页每敲一个数字都会提交一次计划并广播重排。旧实现拿「还没到的排程」当基准，
/// 一次提交等于往后滑一个间隔，倒计时越改越长且永远回不来（用户实测「疯狂增加」）。
@Suite("喝水/站立：改设置后的重排不叠加滑移")
struct ReminderRescheduleTests {
    private let calendar = fixedCalendar()

    private func plan(enabled: Bool = true, interval: Int = 60, start: Int = 9 * 60 + 30,
                      end: Int = 18 * 60 + 30, skipWeekends: Bool = true,
                      snooze: Int = 10) -> ReminderPlan {
        ReminderPlan(kind: .water, enabled: enabled, intervalMinutes: interval,
                     windowStart: MinuteOfDay(minutes: start), windowEnd: MinuteOfDay(minutes: end),
                     skipWeekends: skipWeekends, snoozeMinutes: snooze)
    }

    @Test("计划字段没变时沿用现排程，连敲五次也不动")
    func repeatedCommitsDoNotSlide() {
        let now = date(calendar, 2026, 10, 20, 12)
        let scheduled = date(calendar, 2026, 10, 20, 17)
        var existing: Date? = scheduled
        var previous: ReminderPlan? = plan()
        for _ in 0..<5 {
            let next = ReminderScheduler.rescheduled(now: now, previous: previous,
                                                    current: plan(), existing: existing,
                                                    calendar: calendar)
            #expect(stamp(calendar, next) == "10-20 17:00", "无变更的提交不该推进排程")
            existing = next
        }
    }

    @Test("只改「稍后顺延」不重置已经排好的那一次")
    func snoozeOnlyChangeKeepsSchedule() {
        let now = date(calendar, 2026, 10, 20, 12)
        let scheduled = date(calendar, 2026, 10, 20, 17)
        let next = ReminderScheduler.rescheduled(now: now, previous: plan(snooze: 10),
                                                current: plan(snooze: 20), existing: scheduled,
                                                calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 17:00")
    }

    @Test("改间隔从此刻重计，而不是在原排程上再加一个间隔")
    func intervalChangeRecountsFromNow() {
        let now = date(calendar, 2026, 10, 20, 12)
        let scheduled = date(calendar, 2026, 10, 20, 17)
        let next = ReminderScheduler.rescheduled(now: now, previous: plan(interval: 300),
                                                current: plan(interval: 45), existing: scheduled,
                                                calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 12:45")
    }

    @Test("唤醒（previous 为 nil）从此刻重计；首次启动同理")
    func wakeRecountsFromNow() {
        let woke = date(calendar, 2026, 10, 20, 16, 5)
        let next = ReminderScheduler.rescheduled(now: woke, previous: nil, current: plan(interval: 45),
                                                existing: date(calendar, 2026, 10, 20, 17),
                                                calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 16:50")
    }

    @Test("过期排程即使字段没变也重算")
    func overdueScheduleIsRecomputed() {
        let now = date(calendar, 2026, 10, 20, 12)
        let next = ReminderScheduler.rescheduled(now: now, previous: plan(), current: plan(),
                                                existing: date(calendar, 2026, 10, 20, 11),
                                                calendar: calendar)
        #expect(stamp(calendar, next) == "10-20 13:00")
    }

    @Test("关闭或时段无效时没有排程")
    func disabledHasNoSchedule() {
        let now = date(calendar, 2026, 10, 20, 12)
        #expect(ReminderScheduler.rescheduled(now: now, previous: plan(), current: plan(enabled: false),
                                             existing: date(calendar, 2026, 10, 20, 17),
                                             calendar: calendar) == nil)
        #expect(ReminderScheduler.rescheduled(now: now, previous: plan(),
                                             current: plan(start: 18 * 60 + 30, end: 9 * 60 + 30),
                                             existing: nil, calendar: calendar) == nil)
    }

    @Test("连敲间隔数字：最远也只到下一个间隔或次日时段开头")
    func typedIntervalRunawayBounded() {
        // 用户实测场景：周一 16:36，间隔被逐键敲成 5 → 45 → 240 → 240
        let now = date(calendar, 2026, 10, 26, 16, 36)
        var existing: Date? = date(calendar, 2026, 10, 26, 17, 21)
        var previous: ReminderPlan? = plan(interval: 45)
        for interval in [5, 45, 240, 240] {
            let next = ReminderScheduler.rescheduled(now: now, previous: previous,
                                                    current: plan(interval: interval),
                                                    existing: existing, calendar: calendar)
            existing = next
            previous = plan(interval: interval)
        }
        #expect(stamp(calendar, existing) == "10-27 09:30",
                "240 分钟超出今天时段，该顺延到明天开头，而不是再叠一个间隔")
        let remaining = existing!.timeIntervalSince(now)
        #expect(remaining < 26 * 3600, "剩余时间不该超过一天量级")
        L10n.withLanguage(.zhHans) {
            #expect(ReminderDisplay.value(now: now, next: existing!, calendar: calendar) == "明日 09:30",
                    "跨天要报目标时刻，不能再报 h:mm:ss")
        }
        L10n.withLanguage(.en) {
            #expect(ReminderDisplay.value(now: now, next: existing!, calendar: calendar) == "Tomorrow 09:30")
        }
    }
}

@Suite("喝水/站立：不打扰判定")
struct ReminderSuppressionTests {
    private let calendar = fixedCalendar()

    @Test("全屏、黑名单、专注时段各自命中")
    func eachConditionSuppresses() {
        let at14 = date(calendar, 2026, 10, 20, 14)
        #expect(ReminderSuppression.isSuppressed(at: at14,
                context: ReminderContext(hasFullscreenWindow: true),
                blacklist: [], calendar: calendar))
        #expect(ReminderSuppression.isSuppressed(at: at14,
                context: ReminderContext(frontmostBundleID: "com.tencent.meeting"),
                blacklist: ["com.tencent.meeting"], calendar: calendar))
        #expect(ReminderSuppression.isSuppressed(at: at14,
                context: ReminderContext(focusWindows: [MinuteOfDay(minutes: 14 * 60)...MinuteOfDay(minutes: 15 * 60)]),
                blacklist: [], calendar: calendar))
    }

    @Test("黑名单大小写不敏感，普通前台 App 与专注时段外不抑制")
    func normalCasePasses() {
        let at14 = date(calendar, 2026, 10, 20, 14)
        #expect(ReminderSuppression.isSuppressed(at: at14,
                context: ReminderContext(frontmostBundleID: "COM.Tencent.Meeting"),
                blacklist: ["com.tencent.meeting"], calendar: calendar))
        #expect(!ReminderSuppression.isSuppressed(at: at14,
                context: ReminderContext(frontmostBundleID: "com.apple.finder"),
                blacklist: ["com.tencent.meeting"], calendar: calendar))
        #expect(!ReminderSuppression.isSuppressed(at: at14,
                context: ReminderContext(focusWindows: [MinuteOfDay(minutes: 20 * 60)...MinuteOfDay(minutes: 21 * 60)]),
                blacklist: [], calendar: calendar))
    }
}

@Suite("喝水/站立：完成流水与统计")
struct ReminderLogTests {
    private let calendar = fixedCalendar()

    private func makeStore() -> (ReminderLogStore, UserDefaults, String) {
        let suite = "misckit-reminder-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ReminderLogStore(store: defaults, calendar: calendar), defaults, suite)
    }

    private func cleanup(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("按天与种类统计完成次数，稍后不计入")
    func countsCompletedOnly() {
        let (store, defaults, suite) = makeStore()
        defer { cleanup(defaults, suite) }
        let day = date(calendar, 2026, 10, 20, 10)
        store.record(ReminderRecord(kind: .water, date: day, outcome: .completed))
        store.record(ReminderRecord(kind: .water, date: day.addingTimeInterval(3600), outcome: .completed))
        store.record(ReminderRecord(kind: .stand, date: day, outcome: .completed))
        store.record(ReminderRecord(kind: .water, date: day.addingTimeInterval(7200), outcome: .snoozed))

        #expect(store.count(kind: .water, on: day) == 2)
        #expect(store.count(kind: .stand, on: day) == 1)
        #expect(store.count(kind: .water, on: day.addingTimeInterval(86_400)) == 0)
    }

    @Test("7 天统计缺日补 0，末尾是今天")
    func dailyCountsFillGaps() {
        let (store, defaults, suite) = makeStore()
        defer { cleanup(defaults, suite) }
        let today = date(calendar, 2026, 10, 20, 12)
        store.record(ReminderRecord(kind: .water, date: today, outcome: .completed))
        let older = today.addingTimeInterval(-2 * 86_400)
        store.record(ReminderRecord(kind: .water, date: older, outcome: .completed))
        store.record(ReminderRecord(kind: .water, date: older, outcome: .completed))

        let counts = store.dailyCounts(kind: .water, days: 7, now: today)
        #expect(counts.count == 7)
        #expect(counts.last?.count == 1)
        #expect(counts[counts.count - 3].count == 2)
        #expect(counts.reduce(0) { $0 + $1.count } == 3)
    }

    @Test("超过保留期的流水被裁掉")
    func prunesOldRecords() {
        let (store, defaults, suite) = makeStore()
        defer { cleanup(defaults, suite) }
        let today = date(calendar, 2026, 10, 20, 12)
        store.record(ReminderRecord(kind: .water, date: today.addingTimeInterval(-60 * 86_400),
                                   outcome: .completed))
        store.record(ReminderRecord(kind: .water, date: today, outcome: .completed))
        #expect(store.count(kind: .water, on: today.addingTimeInterval(-60 * 86_400)) == 0)
        #expect(store.count(kind: .water, on: today) == 1)
    }

    @Test("MinuteOfDay 夹在一天内并可显示")
    func minuteOfDayClamps() {
        #expect(MinuteOfDay(minutes: -10).display == "00:00")
        #expect(MinuteOfDay(minutes: 24 * 60 + 5).minutes == 24 * 60 - 1)
        #expect(MinuteOfDay(hour: 9, minute: 30).display == "09:30")
        #expect(MinuteOfDay(minutes: 600) < MinuteOfDay(minutes: 601))
    }
}
