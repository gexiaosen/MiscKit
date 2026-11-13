import Foundation

/// 小数位档位。0 档不是"截断"而是四舍五入到整数。
public enum CalcScale: Int, CaseIterable, Codable, Sendable, Identifiable {
    case zero = 0
    case two = 2
    case four = 4

    public var id: Int { rawValue }
    public var label: String { L10n.Calc.scaleLabel(rawValue) }
}

public enum CalcFormat {
    /// 整数值永远不带 `.00`；非整数按档位补齐位数，方便对账时竖着看。
    public static func string(_ value: Decimal, scale: CalcScale, grouping: Bool) -> String {
        let rounded = round(value, to: scale.rawValue)
        let isInteger = fractionalDigits(rounded) == 0
        let digits: Int = isInteger ? 0 : scale.rawValue

        var text = fixedString(rounded, digits: digits)
        guard grouping else { return text }

        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text = String(text.dropFirst())
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let integerPart = parts.first ?? "0"
        let grouped = groupingSeparated(integerPart)
        let tail = parts.count > 1 ? "." + parts[1] : ""
        return (negative ? "-" : "") + grouped + tail
    }

    static func round(_ value: Decimal, to digits: Int) -> Decimal {
        var result = Decimal()
        var source = value
        NSDecimalRound(&result, &source, digits, .plain)
        return result
    }

    /// 小数点后实际有几位有效数字（去掉尾随 0）。
    static func fractionalDigits(_ value: Decimal) -> Int {
        let text = value.description
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        let fraction = text[text.index(after: dot)...].reversed().drop(while: { $0 == "0" })
        return fraction.count
    }

    /// 手写定点输出，避开 NumberFormatter 的区域差异（有的区域用逗号做小数点）。
    private static func fixedString(_ value: Decimal, digits: Int) -> String {
        if digits == 0 {
            var truncated = value
            var result = Decimal()
            NSDecimalRound(&result, &truncated, 0, .plain)
            return result.description
        }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, digits, .plain)
        var text = rounded.description
        if let dot = text.firstIndex(of: ".") {
            let current = text.distance(from: text.index(after: dot), to: text.endIndex)
            if current < digits { text += String(repeating: "0", count: digits - current) }
        } else {
            text += "." + String(repeating: "0", count: digits)
        }
        return text
    }

    private static func groupingSeparated(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var groups: [String] = []
        var rest = Substring(digits)
        while rest.count > 3 {
            groups.insert(String(rest.suffix(3)), at: 0)
            rest = rest.dropLast(3)
        }
        groups.insert(String(rest), at: 0)
        return groups.joined(separator: ",")
    }
}
