import Foundation

public struct DictionaryEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let headword: String
    public let body: String
    public let dictionaryName: String

    public init(id: String, headword: String, body: String, dictionaryName: String) {
        self.id = id
        self.headword = headword
        self.body = body
        self.dictionaryName = dictionaryName
    }
}

/// 读系统「词典.app」已启用的词库。只取文本，不调任何 `DCSShow*` ——
/// 那些会弹出词典面板，而这个 App 只有一个窗口。
public enum DictionaryLookup {
    private typealias DefinitionFunction = @convention(c) (CFTypeRef?, CFString, CFRange) -> Unmanaged<CFString>?
    private typealias ActiveDictionariesFunction = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DictionaryNameFunction = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?

    private static let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"

    private static let definition: DefinitionFunction? = {
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "DCSCopyTextDefinition")
        else { return nil }
        return unsafeBitCast(symbol, to: DefinitionFunction.self)
    }()

    private static let activeDictionaries: ActiveDictionariesFunction? = {
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "DCSGetActiveDictionaries")
        else { return nil }
        return unsafeBitCast(symbol, to: ActiveDictionariesFunction.self)
    }()

    private static let dictionaryName: DictionaryNameFunction? = {
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "DCSDictionaryGetName")
        else { return nil }
        return unsafeBitCast(symbol, to: DictionaryNameFunction.self)
    }()

    public static var isAvailable: Bool { definition != nil }

    public static var availableDictionaryNames: [String] {
        guard let activeDictionaries else { return [] }
        // Get 系列不转移所有权：这里 takeRetainedValue 会多减一次引用计数，
        // 之后任何一次查询都会在已释放的数组上崩（实测在 CFArrayGetCount 里 SIGTRAP）。
        let array = activeDictionaries()?.takeUnretainedValue() as? [CFTypeRef] ?? []
        return array.map { dictionary in
            dictionaryName?(dictionary)?.takeUnretainedValue() as String? ?? L10n.Tools.Dictionary.systemTitle
        }
    }

    /// 同步、纯本地、不上屏。查不到返回空数组。
    ///
    /// 每个已启用词库单独查一次：`DCSCopyTextDefinition` 传 NULL 只会返回**一个**词库的结果
    /// （实测「感」只给现代汉语的 189 字，牛津英汉那 438 字被整个丢掉），不是合并。
    public static func define(_ term: String, max: Int = 3) -> [DictionaryEntry] {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, max > 0, let definition else { return [] }
        let length = (word as NSString).length
        guard length <= 64 else { return [] }
        let range = CFRange(location: 0, length: length)

        let dictionaries = activeDictionaries?()?.takeUnretainedValue() as? [CFTypeRef] ?? []
        guard !dictionaries.isEmpty else {
            guard let copied = definition(nil, word as CFString, range) else { return [] }
            let body = normalize(copied.takeRetainedValue() as String, droppingHeadword: word)
            guard !body.isEmpty else { return [] }
            return [DictionaryEntry(id: "system:\(word.lowercased())", headword: word,
                                    body: body, dictionaryName: L10n.Tools.Dictionary.systemTitle)]
        }

        var entries: [DictionaryEntry] = []
        for (index, dictionary) in dictionaries.enumerated() {
            let name = dictionaryName?(dictionary)?.takeUnretainedValue() as String? ?? L10n.Tools.Dictionary.systemTitle
            guard let copied = definition(dictionary, word as CFString, range) else { continue }
            let body = normalize(copied.takeRetainedValue() as String, droppingHeadword: word)
            guard !body.isEmpty else { continue }
            entries.append(DictionaryEntry(id: "dict:\(index):\(word.lowercased())",
                                           headword: word, body: body, dictionaryName: name))
            if entries.count >= max { break }
        }
        return entries
    }

    /// 排版清理：`DCSCopyTextDefinition` 给的已经是纯文本，只把词头前缀和空行理顺。
    static func normalize(_ raw: String, droppingHeadword word: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        if text.lowercased().hasPrefix(word.lowercased()) {
            let rest = text.dropFirst(word.count)
            let trimmed = rest.drop { $0 == " " || $0 == "|" || $0 == "\t" || $0 == "\n" }
            if !trimmed.isEmpty { text = String(trimmed) }
        }
        var lines: [String] = []
        var blank = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
