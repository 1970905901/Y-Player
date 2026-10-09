import CatVodCore
import Foundation

/// 聚合搜索（M11 聚合海报墙）里「一个站点 + 它搜到的条目」。
///
/// 左栏一行 = 一个 section（站点名 + 命中数）；右栏的格子从它的 `items` 来 ——
/// 「全部」那一档就是把所有 section 的 items 摞起来（在 `AggregateSearchView` 里做）。
struct AggregateSearchSection: Identifiable {
    /// 站点：点海报进详情时要用它。
    let site: Site
    /// 左栏显示的站点名：自定义名 > 原始名 > key（见 `AppModel.siteDisplayName(for:)`）。
    let siteName: String
    let items: [VodItem]

    var id: String { site.key }
    var count: Int { items.count }
}

/// 聚合搜索的两条规则（纯逻辑、有单测）：**搜哪些站点**、**结果怎么归位**。
///
/// 为什么单拎出来：这两条决定「墙画出来是什么」；而且并发回来的顺序是乱的，
/// 归位规则钉住才好测（与 `DiscoverPaging` / `SiteSelection` 同一个做法）。
enum AggregateSearchRules {
    /// 参与聚合搜索的站点，保持站点清单的顺序：
    ///
    /// 1. 先只留下**能搜**的站点（`availability` + `searchAvailability.isUsable`）；
    /// 2. 其中有站点标了 `indexs == 1`（上游语义：**索引站点，参与聚合搜索**）就只搜这些；
    /// 3. 一个都没标就回落「全部可搜站点」—— 新配置常常没人标 `indexs`，回落总比空墙好。
    static func targets(sites: [Site]) -> [Site] {
        let searchable = sites.filter { $0.availability.isAvailable && $0.searchAvailability.isUsable }
        let indexed = searchable.filter { $0.indexs == 1 }
        return indexed.isEmpty ? searchable : indexed
    }

    /// 左栏要的站点串：**只留有命中的站点**（参考图左栏只列有东西的站点），
    /// 顺序照站点清单 —— 并发谁先回来不该决定界面顺序。
    ///
    /// - Parameters:
    ///   - sites: 参与搜索的站点（``targets(sites:)`` 的结果）。
    ///   - hits: 站点 key → 该站点搜到的条目；**失败与零命中都不进列表**（best-effort，与换源一个口径）。
    ///   - names: 站点 key → 展示名；缺失时回落站点原名，名字也空就回落 key。
    static func sections(
        sites: [Site],
        hits: [String: [VodItem]],
        names: [String: String] = [:]
    ) -> [AggregateSearchSection] {
        sites.compactMap { site in
            guard let items = hits[site.key], !items.isEmpty else {
                return nil
            }
            let name = names[site.key] ?? (site.name.isEmpty ? site.key : site.name)
            return AggregateSearchSection(site: site, siteName: name, items: items)
        }
    }
}
