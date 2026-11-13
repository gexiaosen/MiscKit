import Foundation
import Testing

@testable import MiscKitCore

@Suite("提醒目标次数")
struct ReminderTargetTests {
    private let calendar = Calendar.current

    private func day(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func plan(skipWeekends: Bool = true, enabled: Bool = true) -> ReminderPlan {
        ReminderPlan(kind: .water, enabled: enabled, intervalMinutes: 45,
                     windowStart: MinuteOfDay(hour: 9, minute: 30),
                     windowEnd: MinuteOfDay(hour: 18, minute: 30),
                     skipWeekends: skipWeekends)
    }

    @Test("45 分钟窗口内一天 12 次；周末按开关归零")
    func perDay() {
        #expect(ReminderTarget.perDay(plan: plan(), day: day(2026, 10, 26), calendar: calendar) == 12)
        #expect(ReminderTarget.perDay(plan: plan(), day: day(2026, 10, 24), calendar: calendar) == 0)
        #expect(ReminderTarget.perDay(plan: plan(skipWeekends: false),
                                      day: day(2026, 10, 24), calendar: calendar) == 12)
        #expect(ReminderTarget.perDay(plan: plan(enabled: false),
                                      day: day(2026, 10, 26), calendar: calendar) == 0)
    }

    @Test("今天按已过时段折算，过去按整天，未来为 0")
    func expectedSoFar() {
        let p = plan()
        let monday = day(2026, 10, 26)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: monday,
                                             now: day(2026, 10, 26, 9, 0), calendar: calendar) == 0)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: monday,
                                             now: day(2026, 10, 26, 9, 30), calendar: calendar) == 0)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: monday,
                                             now: day(2026, 10, 26, 10, 15), calendar: calendar) == 1)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: monday,
                                             now: day(2026, 10, 26, 18, 0), calendar: calendar) == 11)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: monday,
                                             now: day(2026, 10, 26, 18, 30), calendar: calendar) == 12)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: monday,
                                             now: day(2026, 10, 27, 0, 0), calendar: calendar) == 12)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: day(2026, 10, 27),
                                             now: monday, calendar: calendar) == 0)
        #expect(ReminderTarget.expectedSoFar(plan: p, day: day(2026, 10, 24),
                                             now: day(2026, 10, 26, 12, 0), calendar: calendar) == 0)
    }
}
