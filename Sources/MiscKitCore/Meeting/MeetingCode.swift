import Foundation

/// 号码是从哪一路证据认出来的：决定置信度，也决定行文案怎么说。
public enum MeetingAnchor: Equatable, Sendable {
    /// 入会链接里的 `meetingCode=` 参数，最可信
    case inviteURL
    /// 「腾讯会议 / 会议号 / 入会 …」锚点词附近出现的数字
    case keyword(String)
    /// 整段输入本身就是一个号码
    case bare
}

public struct MeetingCandidate: Equatable, Sendable {
    /// 去掉分隔符后的纯数字
    public let code: String
    public let anchor: MeetingAnchor

    public init(code: String, anchor: MeetingAnchor) {
        self.code = code
        self.anchor = anchor
    }

    /// 每 3 位一组，方便肉眼核对
    public var formatted: String {
        var groups: [String] = []
        var rest = Substring(code)
        while rest.count > 3 {
            groups.append(String(rest.prefix(3)))
            rest = rest.dropFirst(3)
        }
        if !rest.isEmpty { groups.append(String(rest)) }
        return groups.joined(separator: "-")
    }
}

/// 腾讯会议号识别。纯函数，全部规则可单测；不做任何剪贴板/网络读取。
public enum MeetingCodeRecognizer {
    /// 腾讯会议号长度：常规 9/10/11 位，社区版 12 位
    public static let lengthRange = 9...12

    public static let anchors: [String] = [
        "腾讯会议", "会议号", "会议 ID", "会议ID", "会议 id", "入会", "wemeet", "meeting.tencent.com",
    ]

    /// 中国大陆手机号形态：11 位且 1[3-9] 开头
    static func looksLikeMobile(_ digits: String) -> Bool {
        digits.count == 11 && digits.first == "1" && digits.dropFirst().first.map { "3456789".contains($0) } == true
    }

    /// 一段文本里所有「数字（可用单个空格或连字符分组）」连续串。
    /// 分隔符只在两侧都是数字时才算分组，所以 `123-456-789` 归一为 9 位，
    /// 而 `2026-10-20` 并成 8 位、落在长度区间外。
    static func digitRuns(in text: Substring) -> [(digits: String, range: Range<String.Index>)] {
        var runs: [(String, Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isNumber else { index = text.index(after: index); continue }
            var digits = ""
            let start = index
            while index < text.endIndex {
                let char = text[index]
                if char.isNumber {
                    digits.append(char)
                    index = text.index(after: index)
                    continue
                }
                let next = text.index(after: index)
                if (char == " " || char == "-"), next < text.endIndex, text[next].isNumber {
                    index = next
                    continue
                }
                break
            }
            runs.append((digits, start..<index))
        }
        return runs
    }

    public static func recognize(_ text: String) -> MeetingCandidate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let fromURL = inviteURLCode(in: trimmed) {
            return MeetingCandidate(code: fromURL, anchor: .inviteURL)
        }

        // 锚点位置与数字区间必须来自同一个 String 实例，所以统一在 view 上算。
        let view = Substring(trimmed)
        let anchor = anchors.first { view.range(of: $0, options: .caseInsensitive) != nil }
        let runs = digitRuns(in: view).filter { lengthRange.contains($0.digits.count) }

        if let anchor {
            // 锚点之后的第一个候选才是「这个会议的号」；锚点前的数字多半是日期或人数。
            let anchorRange = view.range(of: anchor, options: .caseInsensitive)!.lowerBound
            let after = runs.first { $0.range.lowerBound >= anchorRange }
            let picked = after ?? runs.first
            guard let digits = picked?.digits else { return nil }
            // 用户明确写了「会议号 138…」时按会议号处理，只有裸手机号才拒。
            return MeetingCandidate(code: digits, anchor: .keyword(anchor))
        }

        // 没有锚点：只有整段输入就是一个号码才认，避免把手机号、订单号、时间戳当会议号。
        guard runs.count == 1, let only = runs.first,
              only.range.lowerBound == view.startIndex,
              only.range.upperBound == view.endIndex else { return nil }
        guard !looksLikeMobile(only.digits) else { return nil }
        return MeetingCandidate(code: only.digits, anchor: .bare)
    }

    /// `meetingCode=` / `meeting_code=` 参数优先，取到下一个 `&`、空白或结尾为止。
    static func inviteURLCode(in text: String) -> String? {
        let lowercased = text.lowercased()
        for key in ["meetingcode=", "meeting_code="] {
            guard let found = lowercased.range(of: key) else { continue }
            let raw = text[found.upperBound...]
            let value = raw.prefix { !$0.isWhitespace && $0 != "&" && $0 != "#" }
            let digits = String(value.filter(\.isNumber))
            if lengthRange.contains(digits.count) { return digits }
        }
        return nil
    }
}

/// 入会链接与本机腾讯会议的定位。scheme 参数是 2026-10-19 实测过的形态。
public enum TencentMeeting {
    public static let bundleID = "com.tencent.meeting"
    public static let scheme = "wemeet"

    /// 本地随机 16 位 launch_id：腾讯用它区分一次入会尝试，不需要任何权限。
    public static func makeLaunchID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func joinURL(code: String, launchID: String = makeLaunchID()) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "page"
        components.path = "/inmeeting"
        components.queryItems = [
            URLQueryItem(name: "meeting_code", value: code),
            URLQueryItem(name: "token", value: ""),
            URLQueryItem(name: "launch_id", value: launchID),
        ]
        return components.url
    }
}
