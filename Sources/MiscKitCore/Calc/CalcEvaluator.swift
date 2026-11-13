import Foundation

/// 求值失败的原因。`offset` 指向出错的字符，界面按它红标到具体位置。
public struct CalcIssue: Equatable, Sendable, Error {
    public enum Reason: Equatable, Sendable {
        case empty
        case unknownFunction(String)
        case unknownSymbol(String)
        case unexpectedEnd
        case missingOperand
        case misplacedOperator(String)
        case unbalancedParenthesis(open: Bool)
        case divisionByZero
        case invalidNumber(String)
        case wrongArgumentCount(function: String, expected: ClosedRange<Int>, got: Int)
        case notANumber
    }

    public let reason: Reason
    public let offset: Int

    public init(reason: Reason, offset: Int = 0) {
        self.reason = reason
        self.offset = offset
    }

    /// 输入到一半的正常中间态：没写完、少个操作数、括号还没闭合。
    /// 界面据此区分"还在打字"与"真写错了"——比如错误抖动只给后者。
    public var isIncompleteInput: Bool {
        switch reason {
        case .empty, .unexpectedEnd, .missingOperand, .unbalancedParenthesis(open: true):
            return true
        default:
            return false
        }
    }

    /// 文案要能区分"式子没写完"和"式子写错了"：前者用户还在打字，不该报得像失败。
    public var message: String {
        switch reason {
        case .empty: return L10n.Calc.Error.empty
        case .unknownFunction(let name): return L10n.Calc.Error.unknownFunction(name)
        case .unknownSymbol(let symbol): return L10n.Calc.Error.unknownSymbol(symbol)
        case .unexpectedEnd: return L10n.Calc.Error.unexpectedEnd
        case .missingOperand: return L10n.Calc.Error.missingOperand
        case .misplacedOperator(let op): return L10n.Calc.Error.misplacedOperator(op)
        case .unbalancedParenthesis(let open):
            return open ? L10n.Calc.Error.unbalancedOpen : L10n.Calc.Error.unbalancedClose
        case .divisionByZero: return L10n.Calc.Error.divisionByZero
        case .invalidNumber(let text): return L10n.Calc.Error.invalidNumber(text)
        case .wrongArgumentCount(let name, let expected, let got):
            let exp = expected.lowerBound == expected.upperBound
                ? "\(expected.lowerBound)"
                : "\(expected.lowerBound)–\(expected.upperBound)"
            return L10n.Calc.Error.arityRange(name, exp, got)
        case .notANumber: return L10n.Calc.Error.notANumber
        }
    }
}

/// 十进制四则求值。全程 `Decimal`，避免二进制浮点把 0.1+0.2 算成 0.30000000000000004。
public enum CalcEvaluator {
    /// 支持的一元/多元函数。名字大小写不敏感。
    public static let functions: [String: ArgumentShape] = [
        "round": .range(1...2), "floor": .exactly(1), "ceil": .exactly(1),
        "abs": .exactly(1), "sqrt": .exactly(1), "pow": .exactly(2),
        "min": .atLeast(2), "max": .atLeast(2), "sum": .atLeast(1),
    ]

    public enum ArgumentShape: Equatable, Sendable {
        case exactly(Int)
        case range(ClosedRange<Int>)
        case atLeast(Int)

        func matches(_ count: Int) -> Bool {
            switch self {
            case .exactly(let n): return count == n
            case .range(let bounds): return bounds.contains(count)
            case .atLeast(let n): return count >= n
            }
        }

        var expected: ClosedRange<Int> {
            switch self {
            case .exactly(let n): return n...n
            case .range(let bounds): return bounds
            case .atLeast(let n): return n...64
            }
        }
    }

    public static func evaluate(_ text: String) -> Result<Decimal, CalcIssue> {
        let tokens: [Token]
        do {
            tokens = try lex(text)
        } catch {
            return .failure(error)
        }
        guard !tokens.isEmpty else { return .failure(CalcIssue(reason: .empty)) }
        var parser = Parser(tokens: tokens)
        do {
            let value = try parser.parseExpression(state: ParseState(text: text), depth: 0)
            if !parser.isAtEnd {
                let token = parser.current
                return .failure(CalcIssue(reason: .misplacedOperator(token.text), offset: token.offset))
            }
            guard !value.isNaN else {
                return .failure(CalcIssue(reason: .notANumber))
            }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    // MARK: 词法

    enum Kind: Equatable {
        case number, identifier, symbol
    }

    struct Token: Equatable {
        let kind: Kind
        let text: String
        let decimal: Decimal?
        let offset: Int
    }

    static func lex(_ text: String) throws(CalcIssue) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == " " || char == "\t" || char == "\n" || char == "\r" {
                index += 1
                continue
            }
            if char.isNumber || char == "." {
                var digits = ""
                let start = index
                var sawDot = false
                while index < characters.count {
                    let current = characters[index]
                    if current.isNumber {
                        digits.append(current)
                        index += 1
                    } else if current == ".", !sawDot {
                        sawDot = true
                        digits.append(current)
                        index += 1
                    } else {
                        break
                    }
                }
                // 逗号一律是参数分隔符，不当千分位：`sum(1,234)` 若被读成 1234
                // 就是悄悄算错，比报错糟得多。粘进来的 `1,234` 会明确报「,」位置不对。
                guard let value = Decimal(string: digits) else {
                    throw CalcIssue(reason: .invalidNumber(digits), offset: start)
                }
                tokens.append(Token(kind: .number, text: digits, decimal: value, offset: start))
                continue
            }
            if char.isLetter || char == "_" {
                let start = index
                var name = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber {
                    name.append(characters[index])
                    index += 1
                }
                tokens.append(Token(kind: .identifier, text: name, decimal: nil, offset: start))
                continue
            }
            if "+-*/().%,".contains(char) {
                tokens.append(Token(kind: .symbol, text: String(char), decimal: nil, offset: index))
                index += 1
                continue
            }
            throw CalcIssue(reason: .unknownSymbol(String(char)), offset: index)
        }
        return tokens
    }

    // MARK: 语法

    private struct ParseState {
        let text: String
    }

    private struct Parser {
        private static let maxDepth = 128

        var tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }
        var current: Token { tokens[position] }

        mutating func advance() -> Token {
            let token = tokens[position]
            position += 1
            return token
        }

        mutating func match(_ symbol: String) -> Bool {
            if !isAtEnd, tokens[position].kind == .symbol, tokens[position].text == symbol {
                position += 1
                return true
            }
            return false
        }

        private func checkDepth(_ depth: Int) throws(CalcIssue) {
            guard depth <= Self.maxDepth else {
                let offset = isAtEnd ? 0 : tokens[position].offset
                throw CalcIssue(reason: .notANumber, offset: offset)
            }
        }

        private func startsModuloRightOperand(at index: Int) -> Bool {
            guard index < tokens.count else { return false }
            let token = tokens[index]
            if token.kind == .number || token.kind == .identifier || token.text == "(" {
                return true
            }
            // `10 % -3` / `10 % +3` 后跟一元正负与操作数时按取模处理
            if token.kind == .symbol, token.text == "-" || token.text == "+" {
                return startsModuloRightOperand(at: index + 1)
            }
            return false
        }

        private func checkedAdd(_ lhs: Decimal, _ rhs: Decimal, offset: Int) throws(CalcIssue) -> Decimal {
            var a = lhs
            var b = rhs
            var out = Decimal()
            let err = NSDecimalAdd(&out, &a, &b, .plain)
            guard err != .overflow, !out.isNaN else {
                throw CalcIssue(reason: .notANumber, offset: offset)
            }
            return out
        }

        private func checkedSub(_ lhs: Decimal, _ rhs: Decimal, offset: Int) throws(CalcIssue) -> Decimal {
            var a = lhs
            var b = rhs
            var out = Decimal()
            let err = NSDecimalSubtract(&out, &a, &b, .plain)
            guard err != .overflow, !out.isNaN else {
                throw CalcIssue(reason: .notANumber, offset: offset)
            }
            return out
        }

        private func checkedMul(_ lhs: Decimal, _ rhs: Decimal, offset: Int) throws(CalcIssue) -> Decimal {
            var a = lhs
            var b = rhs
            var out = Decimal()
            let err = NSDecimalMultiply(&out, &a, &b, .plain)
            guard err != .overflow, !out.isNaN else {
                throw CalcIssue(reason: .notANumber, offset: offset)
            }
            return out
        }

        private func checkedDiv(_ lhs: Decimal, _ rhs: Decimal, offset: Int) throws(CalcIssue) -> Decimal {
            guard rhs != 0 else { throw CalcIssue(reason: .divisionByZero, offset: offset) }
            var a = lhs
            var b = rhs
            var out = Decimal()
            let err = NSDecimalDivide(&out, &a, &b, .plain)
            guard err != .overflow, err != .divideByZero, !out.isNaN else {
                throw CalcIssue(reason: err == .divideByZero ? .divisionByZero : .notANumber, offset: offset)
            }
            return out
        }

        /// 加减
        mutating func parseExpression(state: ParseState, depth: Int) throws(CalcIssue) -> Decimal {
            try checkDepth(depth)
            var left = try parseTerm(state: state, depth: depth + 1)
            while !isAtEnd, tokens[position].kind == .symbol,
                  tokens[position].text == "+" || tokens[position].text == "-" {
                let op = advance()
                let right = try parseTerm(state: state, depth: depth + 1)
                left = op.text == "+"
                    ? try checkedAdd(left, right, offset: op.offset)
                    : try checkedSub(left, right, offset: op.offset)
            }
            return left
        }

        /// 乘除取模
        mutating func parseTerm(state: ParseState, depth: Int) throws(CalcIssue) -> Decimal {
            try checkDepth(depth)
            var left = try parseUnary(state: state, depth: depth + 1)
            while !isAtEnd, tokens[position].kind == .symbol {
                switch tokens[position].text {
                case "*", "/":
                    let op = advance()
                    let right = try parseUnary(state: state, depth: depth + 1)
                    if op.text == "/" {
                        left = try checkedDiv(left, right, offset: op.offset)
                    } else {
                        left = try checkedMul(left, right, offset: op.offset)
                    }
                case "%":
                    guard startsModuloRightOperand(at: position + 1) else {
                        return left
                    }
                    let op = advance()
                    let right = try parseUnary(state: state, depth: depth + 1)
                    let quotient = try checkedDiv(left, right, offset: op.offset)
                    let floored = try checkedMul(truncDecimal(quotient), right, offset: op.offset)
                    left = try checkedSub(left, floored, offset: op.offset)
                default:
                    return left
                }
            }
            return left
        }

        mutating func parseUnary(state: ParseState, depth: Int) throws(CalcIssue) -> Decimal {
            try checkDepth(depth)
            if !isAtEnd, tokens[position].kind == .symbol {
                if tokens[position].text == "-" {
                    position += 1
                    return -(try parseUnary(state: state, depth: depth + 1))
                }
                if tokens[position].text == "+" {
                    position += 1
                    return try parseUnary(state: state, depth: depth + 1)
                }
            }
            return try parsePostfix(state: state, depth: depth + 1)
        }

        /// 百分号就是"除以 100"：`50%` = 0.5，`200+5%` = 200.05。
        /// 要算 200 的 5% 加成得写 `200*(1+5%)`——不做"紧跟加号就按百分比加成"那种魔法，
        /// 那种规则在长式子里谁也算不清。
        mutating func parsePostfix(state: ParseState, depth: Int) throws(CalcIssue) -> Decimal {
            try checkDepth(depth)
            var value = try parsePrimary(state: state, depth: depth + 1)
            while !isAtEnd, tokens[position].kind == .symbol, tokens[position].text == "%" {
                guard !startsModuloRightOperand(at: position + 1) else { break }
                let opOffset = tokens[position].offset
                position += 1
                value = try checkedDiv(value, 100, offset: opOffset)
            }
            return value
        }

        mutating func parsePrimary(state: ParseState, depth: Int) throws(CalcIssue) -> Decimal {
            try checkDepth(depth)
            guard !isAtEnd else { throw CalcIssue(reason: .unexpectedEnd) }
            let token = tokens[position]
            switch token.kind {
            case .number:
                position += 1
                return token.decimal ?? 0
            case .identifier:
                position += 1
                let name = token.text.lowercased()
                guard let shape = CalcEvaluator.functions[name] else {
                    throw CalcIssue(reason: .unknownFunction(token.text), offset: token.offset)
                }
                guard match("(") else {
                    throw CalcIssue(reason: .unbalancedParenthesis(open: true), offset: token.offset)
                }
                var arguments: [Decimal] = []
                if !isAtEnd, tokens[position].text == ")", tokens[position].kind == .symbol {
                    position += 1
                } else {
                    while true {
                        arguments.append(try parseExpression(state: state, depth: depth + 1))
                        if match(",") { continue }
                        break
                    }
                    guard match(")") else {
                        throw CalcIssue(reason: .unbalancedParenthesis(open: true), offset: token.offset)
                    }
                }
                guard shape.matches(arguments.count) else {
                    throw CalcIssue(reason: .wrongArgumentCount(function: name,
                                                                expected: shape.expected,
                                                                got: arguments.count),
                                    offset: token.offset)
                }
                return try apply(name: name, arguments: arguments, offset: token.offset)
            case .symbol:
                if token.text == "(" {
                    position += 1
                    let value = try parseExpression(state: state, depth: depth + 1)
                    guard match(")") else {
                        throw CalcIssue(reason: .unbalancedParenthesis(open: true), offset: token.offset)
                    }
                    return value
                }
                if token.text == ")" {
                    throw CalcIssue(reason: .unbalancedParenthesis(open: false), offset: token.offset)
                }
                position += 1
                throw CalcIssue(reason: .missingOperand, offset: token.offset)
            }
        }

        private func apply(name: String, arguments: [Decimal], offset: Int) throws(CalcIssue) -> Decimal {
            func fromDouble(_ value: Double) throws(CalcIssue) -> Decimal {
                guard value.isFinite else { throw CalcIssue(reason: .notANumber, offset: offset) }
                let dec = Decimal(value)
                guard !dec.isNaN else { throw CalcIssue(reason: .notANumber, offset: offset) }
                return dec
            }
            switch name {
            case "round":
                let value = arguments[0]
                if arguments.count == 2 {
                    let rawDigits = NSDecimalNumber(decimal: arguments[1])
                    let digits = rawDigits.doubleValue.isFinite ? rawDigits.intValue : 0
                    var rounded = Decimal()
                    var source = value
                    NSDecimalRound(&rounded, &source, max(0, min(18, digits)), .plain)
                    return rounded
                }
                var rounded = Decimal()
                var source = value
                NSDecimalRound(&rounded, &source, 0, .plain)
                return rounded
            case "floor": return floorDecimal(arguments[0])
            case "ceil": return ceilDecimal(arguments[0])
            case "abs": return abs(arguments[0])
            case "sqrt":
                guard arguments[0] >= 0 else { throw CalcIssue(reason: .notANumber, offset: offset) }
                return try fromDouble(sqrt(NSDecimalNumber(decimal: arguments[0]).doubleValue))
            case "pow":
                let base = NSDecimalNumber(decimal: arguments[0]).doubleValue
                let exp = NSDecimalNumber(decimal: arguments[1]).doubleValue
                guard base.isFinite, exp.isFinite else { throw CalcIssue(reason: .notANumber, offset: offset) }
                return try fromDouble(pow(base, exp))
            case "min": return arguments.min() ?? 0
            case "max": return arguments.max() ?? 0
            case "sum":
                var acc = Decimal(0)
                for item in arguments {
                    acc = try checkedAdd(acc, item, offset: offset)
                }
                return acc
            default: throw CalcIssue(reason: .unknownFunction(name), offset: offset)
            }
        }
    }

    /// 实测（2026-10-21）：`NSDecimalRound` 的 `.down` 是朝 −∞、`.up` 是朝 +∞，
    /// 正好就是 floor / ceil；朝零截断得自己按符号选。
    static func truncDecimal(_ value: Decimal) -> Decimal {
        var result = Decimal()
        var source = value
        NSDecimalRound(&result, &source, 0, value < 0 ? .up : .down)
        return result
    }

    static func floorDecimal(_ value: Decimal) -> Decimal {
        var result = Decimal()
        var source = value
        NSDecimalRound(&result, &source, 0, .down)
        return result
    }

    static func ceilDecimal(_ value: Decimal) -> Decimal {
        var result = Decimal()
        var source = value
        NSDecimalRound(&result, &source, 0, .up)
        return result
    }
}
