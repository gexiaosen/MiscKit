import CoreFoundation
import Foundation

/// 汉字文件名的拼音转写：只给真正含汉字的条目算，避免给 100 万行英文名白跑 ICU。
/// 全拼与首字母各占一列，进 FTS 的 pinyin / initials 字段，`h y j y` 与 `huiyijiyao` 都能搜到。
enum FileIndexPinyin {
    static func make(_ name: String) -> (full: String, initials: String) {
        guard containsHanzi(name) else { return ("", "") }
        // 扩展名不参与首字母：`报价.docx` 只该给出 `bj`，不该因为 docx 多出一个 d。
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension

        let mutable = NSMutableString(string: stem)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).lowercased()
        let tokens = latin.split(whereSeparator: { $0 == " " })

        var initials = ""
        for token in tokens {
            let letters = token.prefix { $0.isASCII && $0.isLetter }
            if let first = letters.first { initials.append(first) }
        }
        var full = tokens.joined()
        if !ext.isEmpty { full += "." + ext }
        return (full, initials)
    }

    static func containsHanzi(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}
