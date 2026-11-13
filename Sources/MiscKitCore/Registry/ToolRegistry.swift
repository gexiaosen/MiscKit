import Foundation
import os

/// 能力授予的唯一裁决点。工具**声明**能力，注册表在派发处统一校验，
/// 工具实现拿不到未声明的宿主句柄。
@MainActor
public final class CapabilityGrant {
    public static let shared = CapabilityGrant()

    private var revoked: [ToolID: Set<Capability>] = [:]
    private let log = Logger(subsystem: "app.misckit.launcher", category: "capability")

    public func isAllowed(_ capability: Capability, for tool: ToolID) -> Bool {
        revoked[tool]?.contains(capability) != true
    }

    /// 工具声明的能力是否全部就位。
    public func isSatisfied(_ capabilities: Set<Capability>, for tool: ToolID) -> Bool {
        capabilities.allSatisfy { isAllowed($0, for: tool) }
    }

    public func revoke(_ capabilities: Set<Capability>, for tool: ToolID) {
        revoked[tool, default: []].formUnion(capabilities)
        log.info("revoke \(tool.rawValue, privacy: .public) \(capabilities.count)")
    }

    public func restore(_ tool: ToolID) {
        revoked[tool] = nil
    }
}

@MainActor
public final class ToolRegistry {
    public static let shared = ToolRegistry()

    private(set) public var tools: [Tool] = []
    private let log = Logger(subsystem: "app.misckit.launcher", category: "registry")

    /// 「功能」页开关的取数口。生产指 `AppSettings.shared`；测试换成自己的实例，
    /// 不往真实 UserDefaults 里写。闸口只有这一处：注册表问它，别的地方各自再问一遍就是第二张表。
    public var enabledCheck: (ToolID) -> Bool = { AppSettings.shared.isEnabled($0) }

    private init() {}

    /// 唯一裁决点：关掉的功能不参评、不出入口行，`results` 也拿不到命中。
    public func isEnabled(_ tool: ToolID) -> Bool { enabledCheck(tool) }

    public func register(_ tool: Tool) {
        if let index = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[index] = tool
            log.info("replace tool \(tool.id.rawValue, privacy: .public)")
        } else {
            tools.append(tool)
        }
    }

    public func tool(for id: ToolID) -> Tool? {
        tools.first { $0.id == id }
    }

    /// 单个工具对该输入的最佳命中；能力未满足或功能被关掉则直接不参评。
    public func bestHit(for tool: Tool, input: MatchInput) -> MatchHit? {
        guard tool.isAvailable, isEnabled(tool.id),
              CapabilityGrant.shared.isSatisfied(tool.capabilities, for: tool.id)
        else { return nil }
        return tool.triggers.compactMap { $0.match(input) }.max { $0.score < $1.score }
    }

    public func results(for tool: Tool, input: MatchInput) -> [ToolResult] {
        guard let hit = bestHit(for: tool, input: input) else { return [] }
        return decorate(tool.results(for: input, hit: hit), from: tool, hit: hit)
    }

    /// 来源标签与高亮片段在这里统一补齐：工具只负责产出内容。
    private func decorate(_ rows: [ToolResult], from tool: Tool, hit: MatchHit) -> [ToolResult] {
        rows.map { row in
            var decorated = row
            if decorated.source.isEmpty { decorated.source = tool.title }
            // 标题本身就等于命中片段时不高亮（否则整行变色，参考图里只染命中的那几个字）
            if decorated.highlight == nil, decorated.title != hit.highlight {
                decorated.highlight = hit.highlight
            }
            return decorated
        }
    }

    /// 聚合搜索：跨工具打分排序。空输入时返回各工具的"入口行"。
    public func rankedResults(for input: MatchInput, limit: Int = 30) -> [ToolResult] {
        let trimmed = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var out: [ToolResult] = []

        for tool in tools where tool.isAvailable && isEnabled(tool.id) {
            if trimmed.isEmpty, input.fileURLs.isEmpty, input.imageURL == nil {
                out.append(ToolResult(toolID: tool.id, title: tool.title,
                                      symbol: tool.symbol, score: 10,
                                      source: tool.title, highlight: nil))
                continue
            }
            if let hit = bestHit(for: tool, input: input) {
                out.append(contentsOf: decorate(tool.results(for: input, hit: hit), from: tool, hit: hit))
            }
        }
        return Array(out.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.sortPriority != rhs.sortPriority { return lhs.sortPriority > rhs.sortPriority }
            return lhs.title < rhs.title
        }.prefix(limit))
    }
}
