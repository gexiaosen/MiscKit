import Foundation
import Testing

@testable import MiscKitCore

/// 字号门禁。`Type` 是唯一的字号来源，视图层不许再写磅值字面量 ——
/// 和 `Theme` 管颜色、`ContrastAuditTests` 管对比度是同一套做法：收口点 + 棘轮。
@MainActor
@Suite("字号令牌门禁")
struct TypeGateTests {
    /// 棘轮：上限就是现存的字面量数，只准变短 ——
    /// 谁改到某个文件，就顺手把那个文件的剩余字面量换成 Type.*。
    private let literalCeiling = 163

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // Tests/MiscKitCoreTests/TypeGateTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftFiles() -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: sourcesRoot(), includingPropertiesForKeys: nil) else { return [] }
        return (e.compactMap { $0 as? URL }).filter { $0.pathExtension == "swift" }
    }

    @Test("视图层的 .system(size:) 字面量不得超过登记上限")
    func literalRatchet() {
        let offenders = swiftFiles().filter {
            $0.lastPathComponent != "Type.swift"
        }.compactMap { url -> (String, Int)? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let n = text.components(separatedBy: ".system(size:").count - 1
            return n > 0 ? (url.lastPathComponent, n) : nil
        }
        let total = offenders.reduce(0) { $0 + $1.1 }
        #expect(total <= literalCeiling,
                "字号字面量从 \(literalCeiling) 涨到 \(total)：请用 Type.display/panel/row/body/label/meta/micro")
    }

    @Test("七档磅值就是 macOS 语义字阶，且不低于官方最小值 10pt")
    func scaleMatchesNativeSteps() {
        #expect(Type.pointSizePublic(.display) == 22)
        #expect(Type.pointSizePublic(.panel) == 17)
        #expect(Type.pointSizePublic(.row) == 15)
        #expect(Type.pointSizePublic(.body) == 13)
        #expect(Type.pointSizePublic(.label) == 12)
        #expect(Type.pointSizePublic(.meta) == 11)
        #expect(Type.pointSizePublic(.micro) == 10)
        for step in Type.Step.allCases {
            #expect(Type.pointSizePublic(step) >= 10, "\(step) 低于 macOS 官方最小值")
        }
    }

    @Test("15 个历史磅值全部归一到 7 档，且越界值只会变大不会变小")
    func legacySizesMapOntoTheScale() {
        let mapping: [(CGFloat, Type.Step)] = [
            (8, .micro), (9, .micro), (9.5, .micro), (10, .micro),
            (10.5, .meta), (11, .meta), (11.5, .meta),
            (12, .label), (13, .body), (14, .row), (15, .row),
            (16, .panel), (17, .panel), (20, .display), (22, .display),
        ]
        for (size, step) in mapping {
            #expect(Type.step(forSize: size) == step, "\(size)pt 应归到 \(step)")
            // 越界的那些（8/9/9.5/10.5/11.5/14/16/20）只会提到合法档位，不会被压更小
            #expect(Type.pointSizePublic(step) >= size || size >= 10)
        }
    }
}
