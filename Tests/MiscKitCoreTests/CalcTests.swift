import Foundation
import Testing

@testable import MiscKitCore

private func value(_ text: String) -> Decimal? {
    if case .success(let result) = CalcEvaluator.evaluate(text) { return result }
    return nil
}

private func issue(_ text: String) -> CalcIssue? {
    if case .failure(let error) = CalcEvaluator.evaluate(text) { return error }
    return nil
}

@Suite("稿纸：四则求值")
struct CalcEvaluatorTests {
    @Test("优先级、括号与一元负号")
    func precedence() {
        #expect(value("23+12") == 35)
        #expect(value("2+3*4") == 14)
        #expect(value("(2+3)*4") == 20)
        #expect(value("-5+2") == -3)
        #expect(value("-(2+3)*2") == -10)
        #expect(value("10/4") == 2.5)
        #expect(value(" 7 * ( 1 + 2 ) ") == 21)
    }

    @Test("全程 Decimal：0.1+0.2 必须正好是 0.3")
    func decimalExactness() {
        #expect(value("0.1+0.2") == Decimal(string: "0.3"))
        #expect(value("1.111*3") == Decimal(string: "3.333"))
        #expect(value("0.07*100") == Decimal(string: "7"))
    }

    @Test("百分号是除以 100，取模要后面跟数")
    func percentAndModulo() {
        #expect(value("50%") == Decimal(string: "0.5"))
        #expect(value("200+5%") == Decimal(string: "200.05"))
        #expect(value("200*(1+5%)") == 210)
        #expect(value("10%3") == 1)
        #expect(value("10%3*2") == 2)
    }

    @Test("逗号只当参数分隔：粘贴来的千分位要报错，不能悄悄改值")
    func commasAreArgumentSeparators() {
        #expect(value("sum(1,234)") == 235)
        #expect(value("sum(1,234,5)") == 240)
        #expect(issue("1,234+1")?.reason == .misplacedOperator(","))
        #expect(issue("1,234+1")?.offset == 1)
    }

    @Test("函数：四舍五入、取整、绝对值、开方、幂、聚合")
    func functions() {
        #expect(value("round(2.5)") == 3)
        #expect(value("round(-2.5)") == -3)
        #expect(value("round(2.345,2)") == Decimal(string: "2.35"))
        #expect(value("floor(-2.5)") == -3)
        #expect(value("ceil(-2.5)") == -2)
        #expect(value("floor(2.9)") == 2)
        #expect(value("abs(-4)") == 4)
        #expect(value("sqrt(9)") == 3)
        #expect(value("pow(2,10)") == 1024)
        #expect(value("sum(1,2,3,4)") == 10)
        #expect(value("min(3,1,2)") == 1)
        #expect(value("max(3,1,2)") == 3)
        #expect(value("SUM(1,2)") == 3, "函数名大小写不敏感")
        #expect(value("round(2.5, 1)") == Decimal(string: "2.5"))
    }

    @Test("错误文案分得开：没写完 / 写错了 / 除零 / 括号")
    func distinctErrors() {
        #expect(issue("1++")?.reason == .unexpectedEnd)
        #expect(issue("(*2)")?.reason == .missingOperand)
        #expect(issue("1/0")?.reason == .divisionByZero)
        #expect(issue("(1+2")?.reason == .unbalancedParenthesis(open: true))
        #expect(issue("1+2)")?.reason == .misplacedOperator(")"))
        #expect(issue("foo(1)")?.reason == .unknownFunction("foo"))
        #expect(issue("1 2")?.reason == .misplacedOperator("2"))
        #expect(issue("sqrt(-1)")?.reason == .notANumber)
        #expect(issue("min(1)")?.reason == .wrongArgumentCount(function: "min", expected: 2...64, got: 1))
        #expect(issue("")?.reason == .empty)
        #expect(issue("1＋1")?.reason == .unknownSymbol("＋"), "全角加号要指出来，不能当空格")
    }

    @Test("错误定位到出错的字符下标")
    func errorOffsets() {
        #expect(issue("1/0")?.offset == 1)
        #expect(issue("foo(1)")?.offset == 0)
        #expect(issue("2+3)")?.offset == 3)
        #expect(issue("1＋1")?.offset == 1)
    }

    @Test("大数乘法与 pow 溢出给出错误而不是崩或假结果")
    func decimalOverflowProducesIssue() {
        let hugeMul = Array(repeating: "1000000000000000000000000000000", count: 6).joined(separator: "*")
        #expect(issue(hugeMul)?.reason == .notANumber)
        #expect(issue("pow(10, 100) * pow(10, 100)")?.reason == .notANumber)
        #expect(issue("pow(10, 200)")?.reason == .notANumber)
        #expect(issue("pow(10, 400)")?.reason == .notANumber)
        L10n.withLanguage(.zhHans) {
            #expect(issue(hugeMul)?.message == "结果不是数字")
        }
        L10n.withLanguage(.en) {
            #expect(issue(hugeMul)?.message == "Result is not a number")
        }
    }
}

@Suite("稿纸：结果显示格式")
struct CalcFormatTests {
    private func text(_ value: Decimal, _ scale: CalcScale, grouping: Bool = false) -> String {
        CalcFormat.string(value, scale: scale, grouping: grouping)
    }

    @Test("整数永远不带 .00")
    func integersStayPlain() {
        #expect(text(35, .zero) == "35")
        #expect(text(35, .two) == "35")
        #expect(text(35, .four) == "35")
        #expect(text(Decimal(string: "1.00")!, .two) == "1")
    }

    @Test("非整数按档位补齐位数，0 档四舍五入到整数")
    func fractionsFollowScale() {
        #expect(text(Decimal(string: "1.5")!, .two) == "1.50")
        #expect(text(Decimal(string: "1.5")!, .four) == "1.5000")
        #expect(text(Decimal(string: "2.345")!, .two) == "2.35")
        #expect(text(Decimal(string: "2.344")!, .two) == "2.34")
        #expect(text(Decimal(string: "2.6")!, .zero) == "3")
        #expect(text(Decimal(string: "-2.6")!, .zero) == "-3")
    }

    @Test("千分位只切整数部分，可关")
    func grouping() {
        #expect(text(Decimal(string: "1234567.891")!, .two, grouping: true) == "1,234,567.89")
        #expect(text(Decimal(string: "1234567.891")!, .two, grouping: false) == "1234567.89")
        #expect(text(1234, .zero, grouping: true) == "1,234")
        #expect(text(123, .zero, grouping: true) == "123")
        #expect(text(Decimal(string: "-1234.5")!, .two, grouping: true) == "-1,234.50")
    }
}

@Test("「式子没写完」与「真写错了」分得开：抖动只给后者")
func incompleteInputClassification() {
    func incomplete(_ text: String) -> Bool? {
        guard case .failure(let issue) = CalcEvaluator.evaluate(text) else { return nil }
        return issue.isIncompleteInput
    }
    #expect(incomplete("1+") == true, "写了一半的加法")
    #expect(incomplete("(") == true, "括号还没闭合")
    #expect(incomplete("2*") == true, "运算符悬空")
    #expect(incomplete("1/0") == false, "除以零是真错误")
    #expect(incomplete("@") == false, "不认识的符号是真错误")
    #expect(incomplete("1+1") == nil, "能算出来的不报错")
}
