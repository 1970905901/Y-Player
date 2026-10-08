import CatVodCore
import Foundation

// 站点面板的**分组条**（M06d）：从站点名里抽标签 → 按存的顺序排 → 上移下移落盘。
//
// 上游链路是 `SiteDialog → Site.getGroups → SiteNameStore → SiteNameRules.groups → GroupRuleConfig.extract`；
// 其中纯规则部分在 `CatVodCore`（`GroupRule` / `GroupRuleConfig` / `SiteGroupOrder`），
// 这里只负责「拿当前站点列表算一遍 + 存顺序」。

public extension AppModel {
    /// 接口配置里的分组规则（`SourceConfig.groupRules`）。
    var siteGroupRules: [GroupRule] {
        state.loadedSource?.config.groupRules ?? []
    }

    /// **当前站点列表**里所有分组，已按存下来的顺序排好（没存过 = 按站点顺序首次出现）。
    ///
    /// 用**全部可用站点**、而不是「面板当前筛出来的那些」：顺序按全集算并落盘，
    /// 否则一个分组因为当下被筛掉就会掉到末尾，下次它出现时位置就乱了
    /// （与 ``SiteGroupOrder/mergedVisibleOrder(fullOrder:visibleOrder:)`` 是同一个考虑）。
    var siteGroups: [String] {
        let tags = DiscoverSiteList.tags(sites: sites, rules: siteGroupRules)
        return DiscoverSiteList.groups(sites: sites, tags: tags, savedOrder: siteGroupOrder)
    }

    /// 当前接口存下来的分组顺序（空 = 没存过）。
    var siteGroupOrder: [String] {
        siteGroupOrders[configURL] ?? []
    }

    /// 把一个分组上移 / 下移一格并落盘。越界或找不到就不动
    /// （判定在 ``SiteGroupOrder/move(_:group:direction:)``，这里不重复一套边界逻辑）。
    func moveSiteGroup(_ group: String, direction: Int) {
        var order = siteGroups
        guard SiteGroupOrder.move(&order, group: group, direction: direction) else {
            return
        }
        siteGroupOrders = SiteGroupOrderBook.recording(order, for: configURL, in: siteGroupOrders)
    }
}
