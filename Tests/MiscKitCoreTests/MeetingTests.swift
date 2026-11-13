import Foundation
import Testing

@testable import MiscKitCore

@Suite("腾讯会议号：识别、误判拒绝与入会链接")
struct MeetingCodeTests {
    private static let code = "123456789"

    @Test("三种粘贴形态识别出同一个号码")
    func sameCodeFromThreeShapes() {
        let forms = [
            Self.code,                              // 裸号码
            "123-456-789",                          // 连字符分组
            "123 456 789",                          // 空格分组
            "腾讯会议\n会议号: 123 456 789\n点击链接入会", // 邀请文案
        ]
        for form in forms {
            #expect(MeetingCodeRecognizer.recognize(form)?.code == Self.code, "形态「\(form)」应识别出号码")
        }
    }

    @Test("入会链接的 meetingCode 参数优先于同一句里的其它数字")
    func urlParamWins() {
        let text = "13800138000 会议时间 2026-10-20 https://meeting.tencent.com/dm/x?meetingCode=9876543210"
        let candidate = MeetingCodeRecognizer.recognize(text)
        #expect(candidate?.code == "9876543210")
        #expect(candidate?.anchor == .inviteURL)
    }

    @Test("锚点决定置信度：链接 > 关键词 > 裸号码")
    func anchorDrivesConfidence() {
        #expect(MeetingCodeRecognizer.recognize("123456789")?.anchor == .bare)
        #expect(MeetingCodeRecognizer.recognize("会议号 123456789")?.anchor == .keyword("会议号"))
        #expect(MeetingCodeRecognizer.recognize("入会：123 456 789")?.anchor == .keyword("入会"))
    }

    @Test("取锚点之后的号码，不把前面的日期当号")
    func prefersRunAfterAnchor() {
        let text = "20261020 腾讯会议 123456789"
        #expect(MeetingCodeRecognizer.recognize(text)?.code == Self.code)
    }

    @Test("误判防护：手机号、时间戳、订单号、无锚点长文本都不出候选")
    func rejectsLookalikes() {
        let rejected = [
            "13800138000",                       // 11 位手机号
            "1729401600000",                     // 13 位毫秒时间戳
            "订单号 8123456789012",               // 有锚点词之外的文字，但不是会议锚点
            "联系电话 138 0013 8000",             // 分组手机号
            "67529069",                          // 8 位，太短
            "会议号稍后发",                        // 有锚点但没号码
            "1234567890123456789",               // 21 位，超出长度区间
        ]
        for text in rejected {
            #expect(MeetingCodeRecognizer.recognize(text) == nil, "「\(text)」不该产生候选")
        }
    }

    @Test("显式写了「会议号」时，11 位手机号形态也按会议号接受")
    func explicitAnchorBeatsPhoneShape() {
        let candidate = MeetingCodeRecognizer.recognize("会议号 13800138000")
        #expect(candidate?.code == "13800138000")
        #expect(candidate?.anchor == .keyword("会议号"))
    }

    @Test("12 位社区版号码可识别，13 位不行")
    func lengthRange() {
        #expect(MeetingCodeRecognizer.recognize("123456789012")?.code == "123456789012")
        #expect(MeetingCodeRecognizer.recognize("1234567890123") == nil)
    }

    @Test("展示形态：每 3 位一组，完整可读（不打码）")
    func displayForms() {
        let nine = MeetingCandidate(code: Self.code, anchor: .bare)
        #expect(nine.formatted == "123-456-789")

        let ten = MeetingCandidate(code: "1234567891", anchor: .bare)
        #expect(ten.formatted == "123-456-789-1")

        let twelve = MeetingCandidate(code: "123456789012", anchor: .bare)
        #expect(twelve.formatted == "123-456-789-012")
    }

    @Test("入会链接带 meeting_code、空 token 与 16 位 launch_id")
    func joinURLShape() {
        let launchID = TencentMeeting.makeLaunchID()
        #expect(launchID.count == 16)
        #expect(launchID.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        guard let url = TencentMeeting.joinURL(code: Self.code, launchID: launchID),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Issue.record("入会链接应能构造")
            return
        }
        #expect(components.scheme == "wemeet")
        #expect(components.host == "page")
        #expect(components.path == "/inmeeting")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["meeting_code"] == Self.code)
        #expect(items["token"] == "")
        #expect(items["launch_id"] == launchID)
    }

    @Test("launch_id 每次不同")
    func launchIDIsRandom() {
        #expect(TencentMeeting.makeLaunchID() != TencentMeeting.makeLaunchID())
    }
}

@MainActor
@Suite("腾讯会议：结果行接入")
struct MeetingToolRowTests {
    private func rows(_ text: String) -> [ToolResult] {
        let tool = MeetingTool()
        guard let hit = TriggerDescriptor(code: "meeting-code", title: "识别会议号",
                                          kind: .text(label: "会议号", minLength: 9)).match(MatchInput(text: text))
        else { return [] }
        return tool.results(for: MatchInput(text: text), hit: hit)
    }

    @Test("识别出行：完整分组号码 + joinMeeting 动作 + 稳定 key")
    func recognizedRow() {
        let produced = rows("腾讯会议 会议号 123 456 789")
        #expect(produced.count == 1)
        let row = produced[0]
        #expect(row.title.contains("123-456-789"), "会议号不当众打码，直接给可读的完整号码")
        #expect(!row.title.contains("•") && !row.subtitle.contains("•"), "不该再有打码形态")
        #expect(!row.subtitle.contains("打码") && !row.subtitle.contains("展开"))
        #expect(row.key == "meeting:join")
        if case .joinMeeting(let code) = row.action {
            #expect(code == "123456789")
        } else {
            Issue.record("动作应是 joinMeeting")
        }
    }

    @Test("手机号不占会议行")
    func phoneProducesNoRow() {
        #expect(rows("13800138000").isEmpty)
    }

    @Test("会议号置信度高于文件搜索弱命中，但只在真识别出号码时")
    func confidenceBeatsWeakRows() {
        let recognized = rows("会议号 123456789")
        #expect(recognized.first.map { $0.score > FilesTool.searchRowScore } == true)
        #expect(rows("1729401600000").isEmpty)
    }
}
