import Foundation
import Testing

@testable import MiscKitCore

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.firstWeekday = 1
    return calendar
}

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar().date(from: DateComponents(year: 2026, month: 10, day: day,
                                        hour: hour, minute: minute))!
}

@Suite("提醒倒计时文案")
struct ReminderDisplayTests {
    @Test("一小时内 m:ss，超过一小时 h:mm:ss")
    func clockFormats() {
        #expect(ReminderDisplay.clockText(2700) == "45:00")
        #expect(ReminderDisplay.clockText(5025) == "1:23:45")
        #expect(ReminderDisplay.clockText(63404) == "17:36:44")
        #expect(ReminderDisplay.clockText(-5) == "0:00")
    }

    @Test("今天之内报剩余时长")
    func sameDayReportsRemaining() {
        let now = at(26, 16, 36)
        #expect(ReminderDisplay.value(now: now, next: at(26, 17, 21), calendar: calendar()) == "45:00")
        L10n.withLanguage(.zhHans) {
            #expect(ReminderDisplay.phrase(now: now, next: at(26, 17, 21), calendar: calendar()) == "距下次 45:00")
        }
        L10n.withLanguage(.en) {
            #expect(ReminderDisplay.phrase(now: now, next: at(26, 17, 21), calendar: calendar()) == "In 45:00")
        }
    }

    @Test("菜单栏分钟级读数：向上取整，跨天仍报目标时刻")
    func menuBarReportsMinutes() {
        let now = at(26, 16, 36)
        L10n.withLanguage(.zhHans) {
            #expect(ReminderDisplay.minuteText(45 * 60) == "45 分")
            #expect(ReminderDisplay.minuteText(45 * 60 - 1) == "45 分")
            #expect(ReminderDisplay.minuteText(45 * 60 + 1) == "46 分")
            #expect(ReminderDisplay.minuteText(3600) == "1 小时")
            #expect(ReminderDisplay.minuteText(5025) == "1 小时 24 分")
            #expect(ReminderDisplay.minuteText(0) == "0 分")
            #expect(ReminderDisplay.menuBarValue(now: now, next: at(26, 17, 21),
                                                 calendar: calendar()) == "45 分")
            #expect(ReminderDisplay.menuBarValue(now: at(25, 15, 53) + 16, next: at(26, 9, 30),
                                                 calendar: calendar()) == "明日 09:30")
        }
        L10n.withLanguage(.en) {
            #expect(ReminderDisplay.minuteText(45 * 60) == "45 min")
            #expect(ReminderDisplay.minuteText(3600) == "1 hr")
            #expect(ReminderDisplay.minuteText(5025) == "1 hr 24 min")
            #expect(ReminderDisplay.menuBarValue(now: now, next: at(26, 17, 21),
                                                 calendar: calendar()) == "45 min")
            #expect(ReminderDisplay.menuBarValue(now: at(25, 15, 53) + 16, next: at(26, 9, 30),
                                                 calendar: calendar()) == "Tomorrow 09:30")
        }
    }

    @Test("明天报目标时刻，不再报十几个小时的倒计时")
    func tomorrowReportsTarget() {
        // 用户截图里那条读数：周日 15:53:16 等周一 09:30
        let now = at(25, 15, 53) + 16
        let next = at(26, 9, 30)
        L10n.withLanguage(.zhHans) {
            #expect(ReminderDisplay.value(now: now, next: next, calendar: calendar()) == "明日 09:30")
            #expect(ReminderDisplay.phrase(now: now, next: next, calendar: calendar()) == "下次 明日 09:30")
        }
        L10n.withLanguage(.en) {
            #expect(ReminderDisplay.value(now: now, next: next, calendar: calendar()) == "Tomorrow 09:30")
            #expect(ReminderDisplay.phrase(now: now, next: next, calendar: calendar()) == "Next Tomorrow 09:30")
        }
    }

    @Test("跳过整个周末时报星期")
    func weekendReportsWeekday() {
        let fridayLate = at(23, 18, 31)
        let monday = at(26, 9, 30)
        L10n.withLanguage(.zhHans) {
            #expect(ReminderDisplay.value(now: fridayLate, next: monday, calendar: calendar()) == "周一 09:30")
        }
        L10n.withLanguage(.en) {
            #expect(ReminderDisplay.value(now: fridayLate, next: monday, calendar: calendar()) == "Mon 09:30")
        }
    }

    @Test("排程已经过期时归零，不显示负数")
    func overdueClampsToZero() {
        #expect(ReminderDisplay.value(now: at(26, 12), next: at(26, 11), calendar: calendar()) == "0:00")
    }
}
