import Testing

@testable import MiscKitCore

/// 屏幕提醒的定稿规格：尺寸来自 2026-10-26 验收的 demo，改动要在这里显式改数。
@Suite("屏幕提醒规格")
struct ReminderOverlayTests {
    @Test("卡片尺寸、圆角与自动收起时长")
    func pinnedChrome() {
        #expect(ReminderOverlayChrome.cardWidth == 360)
        #expect(ReminderOverlayChrome.cardRadius == 24)
        #expect(ReminderOverlayChrome.autoDismissSeconds == 45)
        #expect(ReminderOverlayChrome.scrimOpacity == 0.28)
        #expect(ReminderOverlayChrome.buttonHeight == 38)
        #expect(ReminderOverlayChrome.artHeight == 128)
    }

    @Test("两套提醒的标题与正文")
    func copy() {
        L10n.withLanguage(.zhHans) {
            #expect(ReminderKind.water.reminderTitle == "该喝水了")
            #expect(ReminderKind.water.reminderBody == "喝口水，顺便看看远处。")
            #expect(ReminderKind.stand.reminderTitle == "站起来活动一下")
            #expect(ReminderKind.stand.reminderBody == "站起来走两步，伸展一下。")
        }
        L10n.withLanguage(.en) {
            #expect(ReminderKind.water.reminderTitle == "Time for a glass of water")
            #expect(ReminderKind.water.reminderBody == "Take a sip of water and rest your eyes.")
            #expect(ReminderKind.stand.reminderTitle == "Time to stand and move")
            #expect(ReminderKind.stand.reminderBody == "Stand up, stretch, and take a short walk.")
        }
    }
}
