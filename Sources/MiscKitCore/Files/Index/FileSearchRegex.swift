import Foundation

/// 正则模式的两件事：找一段“必须出现”的字面文本当预筛，再交给 NSRegularExpression 精筛。
/// 没有字面锚点的模式（`^.*x$`）在一百万行上没法跑，直接报一条提示，不假装搜过。
enum FileSearchRegex {
    /// 模式里最长的一段“每个分支都必然出现”的字面文本（≥2 个字符）。
    /// 只在最外层收集；组内的字面可能因为 `|` 或 `?` 不出现，不能当锚点。
    /// 后跟 `*` / `?` 的字面是可选的，同样不算。
    static func literalAnchor(_ pattern: String) -> String? {
        var longest = ""
        var current = ""
        var groupDepth = 0
        var topLevelAlternation = false
        var index = pattern.startIndex

        func flush() {
            if current.count > longest.count { longest = current }
            current = ""
        }

        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "\\":
                index = pattern.index(after: index)
                guard index < pattern.endIndex else { break }
                let escaped = pattern[index]
                if "dDwWsSbBAzZ".contains(escaped) {
                    flush()
                } else if groupDepth == 0 {
                    current.append(escaped)
                }
            case "[":
                flush()
                index = pattern.index(after: index)
                var closed = false
                while index < pattern.endIndex {
                    let inner = pattern[index]
                    if inner == "\\" {
                        index = pattern.index(after: index)
                        if index < pattern.endIndex { index = pattern.index(after: index) }
                        continue
                    }
                    if inner == "]" {
                        closed = true
                        break
                    }
                    index = pattern.index(after: index)
                }
                if !closed { return nil }
            case "(":
                flush()
                groupDepth += 1
            case ")":
                flush()
                groupDepth = max(0, groupDepth - 1)
            case "|":
                if groupDepth == 0 { topLevelAlternation = true }
                flush()
            case ".", "^", "$", "+", "{", "}", ",":
                flush()
            case "*", "?":
                // 前一个字面出现 0 次也成立，不能当“必须出现”的锚点。
                current = ""
            default:
                if groupDepth == 0 { current.append(character) }
            }
            index = pattern.index(after: index)
        }
        flush()

        // 顶层 `a|b`：任何一段字面都只覆盖一个分支，交给全表精筛不划算。
        if topLevelAlternation { return nil }
        return longest.count >= 2 ? longest : nil
    }
}
