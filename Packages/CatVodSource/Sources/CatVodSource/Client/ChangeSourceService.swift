import CatVodCore
import Foundation

/// 换源候选：在其它站点搜到的同一部片的条目。
public struct ChangeSourceCandidate: Sendable, Hashable {
    public var site: Site
    public var item: VodItem
    /// 片名匹配度（0...1）。**启发式**，不声称与上游一致，见 ``ChangeSourceService/matchScore(query:candidate:)``。
    public var score: Double
    /// 是否来自当前站点（用于提示「本站还有其它条目」）。
    public var isCurrent: Bool

    public init(site: Site, item: VodItem, score: Double, isCurrent: Bool) {
        self.site = site
        self.item = item
        self.score = score
        self.isCurrent = isCurrent
    }
}

/// 换源：按片名在当前配置的其它站点里搜索，给出可切换的候选。
///
/// 规则（刻意写得可预测）：
/// - **跳过** 永久禁用的站点（`changeable == 0`）与本平台不可用的站点；
/// - 单次最多查询 ``maxSites`` 个站点（换源不该把整份配置全打一遍）；
/// - **best-effort**：某个站点搜索失败只跳过它，不影响其它站点（整体不抛错）；
/// - 排序：匹配度降序 → 同一片名时当前站点优先（方便「换线路」）→ 其余保持配置顺序。
///
/// 客户端用 ``SiteClient``（门面）：CMS 与 CatSpider HTTP（js2p 宿主）站点都能搜，
/// 这样 JS 源也能参与换源。
public struct ChangeSourceService: Sendable {
    public var client: SiteClient
    public var maxSites: Int

    public init(client: SiteClient, maxSites: Int = 8) {
        self.client = client
        self.maxSites = maxSites
    }

    /// 搜索候选。
    ///
    /// - Parameters:
    ///   - title: 片名（用详情页当前条目的 `vod_name`）。
    ///   - sites: 候选站点（一般传配置里的全部站点，由本方法自行过滤）。
    ///   - currentSiteKey: 当前站点 key，仅用于标记与排序。
    public func candidates(
        title: String,
        sites: [Site],
        currentSiteKey: String?
    ) async -> [ChangeSourceCandidate] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let targets = sites
            .filter { !$0.key.isEmpty && $0.changeSourceAvailability.isUsable && $0.availability.isAvailable }
            .prefix(max(1, maxSites))

        var candidates: [ChangeSourceCandidate] = []
        for site in targets {
            // best-effort：单站失败不影响整体。
            guard let result = try? await client.search(site: site, keyword: title) else {
                continue
            }
            for item in result.list {
                let score = Self.matchScore(query: title, candidate: item.vodName)
                guard score > 0 else {
                    continue
                }
                candidates.append(
                    ChangeSourceCandidate(
                        site: site,
                        item: item,
                        score: score,
                        isCurrent: site.key == currentSiteKey
                    )
                )
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent
            }
            return false
        }
    }

    /// 片名匹配度（0...1）。
    ///
    /// 归一化后按「完全相同 → 前缀 → 包含 → 字符重合度」四档给分；
    /// 字符重合度低于 0.6 视为无关，返回 0（UI 据此不展示）。
    public static func matchScore(query: String, candidate: String) -> Double {
        let lhs = normalize(query)
        let rhs = normalize(candidate)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }
        if lhs == rhs {
            return 1
        }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            return 0.85
        }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            return 0.7
        }
        let left = Set(lhs)
        let right = Set(rhs)
        let denom = Double(max(left.count, right.count))
        guard denom > 0 else {
            return 0
        }
        let overlap = Double(left.intersection(right).count) / denom
        return overlap >= 0.6 ? 0.5 : 0
    }

    /// 归一化：去掉空白与常见中英文标点、统一小写（片名里的大小写与标点不该影响匹配）。
    public static func normalize(_ text: String) -> String {
        let dropped: Set<Character> = [
            " ", "\t", "\n", "\r", "-", "_", ".", "·", ":", "：", ",", "，", "。", "、",
            "(", ")", "（", "）", "《", "》", "[", "]", "!", "！", "?", "？", "\"", "'", "`",
        ]
        return String(text.lowercased().filter { !dropped.contains($0) })
    }
}
