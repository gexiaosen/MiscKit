import Foundation

/// 设置面板的常驻索引。扫描要读 294 个 `.appex`（实测首扫约 150ms），
/// 所以只在第一次真的查设置时才扫，之后吃内存里的结果；磁盘缓存由 scanner 自己管。
@MainActor
public final class SettingsPaneIndex {
    public static let shared = SettingsPaneIndex()

    private let customScanner: SettingsPaneScanner?
    @ObservationIgnored private var cached: [SettingsPane]?
    @ObservationIgnored private var cachedLanguage: ResolvedLanguage?
    @ObservationIgnored private var priming = false

    public init(scanner: SettingsPaneScanner? = nil) {
        self.customScanner = scanner
    }

    private func activeScanner(for language: AppLanguage? = nil) -> SettingsPaneScanner {
        if let customScanner { return customScanner }
        let lang = language ?? L10n.currentLanguage
        return SettingsPaneScanner(preferredLanguages: SettingsPaneScanner.preferredLanguages(for: lang))
    }

    /// 语言切换时清空内存缓存并用目标语言重新预热面板名。
    public func syncLanguage(_ language: AppLanguage) {
        guard customScanner == nil, cachedLanguage != language.resolved else { return }
        cached = nil
        cachedLanguage = nil
        priming = false
        prime(for: language)
    }

    /// 启动时后台预热：不打关键词的「蓝牙」直达要它，但第一次按键等 150ms 是不能接受的。
    public func prime(for language: AppLanguage? = nil) {
        let targetResolved = language?.resolved ?? L10n.effectiveLanguage
        guard cached == nil || cachedLanguage != targetResolved, !priming else { return }
        priming = true
        let scanner = activeScanner(for: language)
        Task { @MainActor in
            let panes = await Task.detached(priority: .utility) { scanner.scan() }.value
            if self.cached == nil || self.cachedLanguage != targetResolved {
                self.cached = panes
                self.cachedLanguage = targetResolved
            }
            self.priming = false
        }
    }

    /// 显式关键词（`设置 蓝牙`）走这里，允许当场补一次同步扫描。
    public var all: [SettingsPane] {
        let currentResolved = L10n.effectiveLanguage
        if let cached, customScanner != nil || cachedLanguage == currentResolved {
            return cached
        }
        let scanned = activeScanner().scan()
        cached = scanned
        cachedLanguage = currentResolved
        return scanned
    }

    /// 不带关键词的直达：先比名字（整词/前缀/包含），名字不中再看 Apple 的索引词。
    /// 索引词**只认整词**，而且英文至少 4 个字符 —— 否则：
    /// - `tri` 会撞上无障碍里的 `Tritanopia`；
    /// - `登录` 会因前缀把共享、锁屏一起带出来。
    /// 打「耳机」出蓝牙靠的是 Apple 词表里本来就有「耳机」这个词，够用。
    public func directMatches(_ term: String, limit: Int = 3) -> [(pane: SettingsPane, score: Int)] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let isASCII = q.allSatisfy(\.isASCII)
        var scored: [(rank: Int, index: Int, pane: SettingsPane)] = []
        for (index, pane) in all.enumerated() {
            var rank = 0
            let name = pane.name.lowercased()
            if name == q { rank = 100 }
            else if name.hasPrefix(q) { rank = 80 }
            else if name.contains(q) { rank = 60 }
            if rank == 0, !isASCII || q.count >= 4,
               pane.matchTerms.contains(where: { $0.lowercased() == q }) {
                rank = 40
            }
            if rank > 0 { scored.append((rank, index, pane)) }
        }
        scored.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank > rhs.rank
        }
        return scored.prefix(limit).map { (pane: $0.pane, score: 86 + $0.rank * 12 / 100) }
    }

    /// 名称命中压过索引词命中：打「蓝牙」先给蓝牙面板，别让「耳机」的索引词把耳机面板顶上来。
    /// 返回分数而不只是结果 —— 注册表最后按分数重排，同分再按标题字母序，
    /// 全给同一个分等于把这里的排序扔掉（实测「设置 蓝牙」把蓝牙排到第三）。
    public func search(_ term: String, limit: Int = 6) -> [(pane: SettingsPane, score: Int)] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(rank: Int, index: Int, pane: SettingsPane)] = []
        for (index, pane) in all.enumerated() {
            var best = 0
            let name = pane.name.lowercased()
            if name == q { best = 100 }
            else if name.hasPrefix(q) { best = 80 }
            else if name.contains(q) { best = 60 }
            if best < 60, q.count >= 2 {
                for word in pane.matchTerms {
                    let w = word.lowercased()
                    if w == q { best = max(best, 50) }
                    else if w.hasPrefix(q) { best = max(best, 40) }
                }
            }
            if best > 0 { scored.append((best, index, pane)) }
        }
        scored.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank > rhs.rank
        }
        // 显式打了「设置」，结果就必须压过「搜索文件」那条 82 分兜底。
        return scored.prefix(limit).map { (pane: $0.pane, score: 84 + $0.rank * 14 / 100) }
    }
}
