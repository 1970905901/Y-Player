import CatVodCore
import Foundation

// 站点面板的**本地偏好**（M06e / M06f）：分组条（抽标签 + 顺序）与站点自定义名。
//
// 上游链路：`SiteDialog → Site.getGroups → SiteNameStore → SiteNameRules.groups → GroupRuleConfig.extract`
// （分组）与 `SiteDialog → SiteNameDialog → SiteNameStore.put`（改名）。
// 纯规则在 `CatVodCore`（`GroupRule` / `GroupRuleConfig` / `SiteGroupOrder` / `SiteNameRules` / `ConfigIdentity`），
// 这里只负责「拿当前站点列表算一遍 + 存下来」，两个书都按**接口摘要**分桶。

public extension AppModel {
    /// 接口配置里的分组规则（`SourceConfig.groupRules`）。
    var siteGroupRules: [GroupRule] {
        state.loadedSource?.config.groupRules ?? []
    }

    /// 当前接口的桶键（接口地址摘要；地址为空时是空串 = 没有可用的桶）。
    var siteConfigBucketKey: String {
        ConfigIdentity.key(for: configURL)
    }

    /// 当前接口的站点自定义名（空 = 全用原始名）。
    var siteNamesForCurrentConfig: [String: String] {
        siteNames[siteConfigBucketKey] ?? [:]
    }

    /// 站点在面板/工具栏上显示的名字（自定义名 > 原始名 > key）。
    func siteDisplayName(for site: Site) -> String {
        SiteNameRules.displayName(
            rawName: site.name,
            customName: siteNamesForCurrentConfig[site.key] ?? "",
            key: site.key
        )
    }

    /// 给站点改名；传空串 = 恢复原名（判定在 ``SiteNameRules/customNameForStorage(rawName:inputName:)``，
    /// 与原名一样的输入不会被存成自定义名）。
    func renameSite(_ site: Site, to name: String) {
        siteNames = SiteNameBook.recording(
            name,
            rawName: site.name,
            for: site.key,
            config: siteConfigBucketKey,
            in: siteNames
        )
    }

    /// **当前站点列表**里所有分组，已按存下来的顺序排好（没存过 = 按站点顺序首次出现）。
    ///
    /// 用**全部可用站点**、而不是「面板当前筛出来的那些」：顺序按全集算并落盘，
    /// 否则一个分组因为当下被筛掉就会掉到末尾，下次它出现时位置就乱了
    /// （与 ``SiteGroupOrder/mergedVisibleOrder(fullOrder:visibleOrder:)`` 是同一个考虑）。
    var siteGroups: [String] {
        let tags = DiscoverSiteList.tags(sites: sites, rules: siteGroupRules, names: siteNamesForCurrentConfig)
        return DiscoverSiteList.groups(sites: sites, tags: tags, savedOrder: siteGroupOrder)
    }

    /// 当前接口存下来的分组顺序（空 = 没存过）。
    var siteGroupOrder: [String] {
        siteGroupOrders[siteConfigBucketKey] ?? []
    }

    /// 把一个分组上移 / 下移一格并落盘。越界或找不到就不动
    /// （判定在 ``SiteGroupOrder/move(_:group:direction:)``，这里不重复一套边界逻辑）。
    func moveSiteGroup(_ group: String, direction: Int) {
        var order = siteGroups
        guard SiteGroupOrder.move(&order, group: group, direction: direction) else {
            return
        }
        siteGroupOrders = SiteGroupOrderBook.recording(order, for: siteConfigBucketKey, in: siteGroupOrders)
    }
}
