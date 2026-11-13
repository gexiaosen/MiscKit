import CryptoKit
import Foundation

/// RFC 4648 Base32。服务方的 secret 经常不带 padding、混着大小写和空格，
/// 但绝不能把"看着像 base32 的乱码"解成密钥，所以字符集与末尾长度都严格判。
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let lookup: [Character: UInt8] = {
        var table = [Character: UInt8]()
        for (index, char) in alphabet.enumerated() { table[char] = UInt8(index) }
        return table
    }()

    /// 解不出来就返回 nil，不猜。
    public static func decode(_ raw: String) -> Data? {
        var value = 0
        var bits = 0
        var bytes: [UInt8] = []
        var groups = 0

        for char in raw.uppercased() {
            if char == "=" { break }                       // padding 之后没有数据了
            if char == " " || char == "-" || char == "\n" || char == "\t" { continue }
            guard let fiveBits = lookup[char] else { return nil }
            value = (value << 5) | Int(fiveBits)
            bits += 5
            groups += 1
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        guard groups > 0 else { return nil }
        // 最后一组的字符数只能是 0/2/4/5/7，1/3/6 位凑不出整数字节
        switch groups % 8 {
        case 0, 2, 4, 5, 7: break
        default: return nil
        }
        // 剩下的低位必须全是 0，否则是被截断或篡改的输入
        if bits > 0, (value & ((1 << bits) - 1)) != 0 { return nil }
        return Data(bytes)
    }

    /// 给设置页回显用：不带 padding，分组好读。
    public static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var output = ""
        var index = 0
        while index < bytes.count {
            var group = 0
            var taken = 0
            // 先按实际字节数左移拼组，再统一对齐到 40bit；边读边补零会把数据顶出 Int 的可用位
            while taken < 5, index < bytes.count {
                group = (group << 8) | Int(bytes[index])
                index += 1
                taken += 1
            }
            group <<= 8 * (5 - taken)
            // 1/2/3/4/5 字节分别输出 2/4/5/7/8 个字符
            let counts = [0, 2, 4, 5, 7, 8]
            let emit = counts[taken]
            for position in 0..<emit {
                output.append(alphabet[(group >> (35 - position * 5)) & 0x1F])
            }
        }
        return output
    }
}

public enum OTPAlgorithm: String, Codable, CaseIterable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    /// 服务方写 `sha1` 还是 `SHA1` 都有可能
    public init?(name: String) {
        guard let match = OTPAlgorithm.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        self = match
    }
}

/// RFC 4226 HMAC-based OTP。计数器版很少单独用，但 TOTP 的截断逻辑就在这。
public enum HOTP {
    public static func code(secret: Data, counter: UInt64, digits: Int = 6,
                            algorithm: OTPAlgorithm = .sha1) -> String? {
        guard !secret.isEmpty, (6...8).contains(digits) else { return nil }
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        let mac: Data
        switch algorithm {
        case .sha1: mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using:
            SymmetricKey(data: secret)))
        case .sha256: mac = Data(HMAC<SHA256>.authenticationCode(for: message, using:
            SymmetricKey(data: secret)))
        case .sha512: mac = Data(HMAC<SHA512>.authenticationCode(for: message, using:
            SymmetricKey(data: secret)))
        }
        // 动态截断：低 4 位选偏移，取 4 字节去掉最高位，再按位数取模
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (Int(mac[offset] & 0x7F) << 24) | (Int(mac[offset + 1]) << 16)
            | (Int(mac[offset + 2]) << 8) | Int(mac[offset + 3])
        var modulo = 1
        for _ in 0..<digits { modulo *= 10 }
        return String(format: "%0\(digits)d", binary % modulo)
    }
}

/// RFC 6238 TOTP。`time` 与 `offset` 分开传：偏移是用户手动校准出来的秒数，
/// 由上层存盘，这里只负责"按校准后的时间出码"。
public enum TOTP {
    public static func code(secret: Data, date: Date, period: Int = 30, digits: Int = 6,
                            algorithm: OTPAlgorithm = .sha1,
                            offset: TimeInterval = 0) -> String? {
        guard period > 0 else { return nil }
        let seconds = date.addingTimeInterval(offset).timeIntervalSince1970
        guard seconds >= 0 else { return nil }
        let counter = UInt64(seconds / Double(period))
        return HOTP.code(secret: secret, counter: counter, digits: digits, algorithm: algorithm)
    }

    /// 本周期还剩多少秒。进度环与"距刷新"文案都读它。
    public static func secondsRemaining(date: Date, period: Int = 30,
                                        offset: TimeInterval = 0) -> Int {
        guard period > 0 else { return 0 }
        let seconds = date.addingTimeInterval(offset).timeIntervalSince1970
        let inside = seconds.truncatingRemainder(dividingBy: Double(period))
        let safe = inside < 0 ? inside + Double(period) : inside
        return max(0, Int(ceil(Double(period) - safe)))
    }
}
