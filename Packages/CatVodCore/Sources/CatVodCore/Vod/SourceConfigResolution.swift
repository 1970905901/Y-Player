import Foundation

// 配置解析辅助：站点筛选、默认站点/解析器回退、可用性汇总。
// 依据 webhtv docs/integration/configuration.md 的「加载流程」与「校验清单」。

public extension SourceConfig {
    /// `msg` 非空表示这是一份错误响应，加载流程必须直接失败。
    var isErrorResponse: Bool {
        !msg.isEmpty
    }

    /// 未隐藏的站点。
    var visibleSites: [Site] {
        sites.filter { $0.hide != 1 }
    }

    /// 在当前平台/构建中可运行的站点（已排除隐藏站点）。
    var usableSites: [Site] {
        visibleSites.filter(\.availability.isAvailable)
    }

    /// 参与聚合搜索的站点（可运行、允许搜索、且参与快速搜索）。
    func sitesForAggregatedSearch(quick: Bool) -> [Site] {
        visibleSites.filter { site in
            guard site.availability.isAvailable, site.searchAvailability.isUsable else {
                return false
            }
            return quick ? site.isQuickSearchEnabled : true
        }
    }

    /// 可用的解析器。
    var usableParsers: [ParserRule] {
        parses.filter(\.availability.isAvailable)
    }

    /// 按 key 查站点；找不到返回 nil。
    func site(forKey key: String) -> Site? {
        sites.first { $0.key == key }
    }

    /// 默认站点：优先 `home` 精确匹配，否则回退第一个可用站点。
    var resolvedHomeSite: Site? {
        if !home.isEmpty, let matched = usableSites.first(where: { $0.key == home }) {
            return matched
        }
        return usableSites.first
    }

    /// 默认解析器：优先 `parse` 精确匹配，否则回退第一个可用解析器。
    var resolvedParser: ParserRule? {
        if !parse.isEmpty, let matched = usableParsers.first(where: { $0.name == parse }) {
            return matched
        }
        return usableParsers.first
    }

    /// 按名称查解析器。
    func parser(named name: String) -> ParserRule? {
        parses.first { $0.name == name }
    }

    /// 不可用站点的原因汇总，用于设置页展示（避免用户误以为站点坏了）。
    var unavailableSiteReasons: [(site: Site, reason: String)] {
        visibleSites.compactMap { site in
            guard let reason = site.availability.reason else {
                return nil
            }
            return (site, reason)
        }
    }

    /// 配置层面的校验告警（不阻断加载，只记录）。
    ///
    /// 对照 webhtv 校验清单：
    /// - `home` 必须精确匹配 `sites[].key`；
    /// - `parse` 必须精确匹配 `parses[].name`。
    var validationWarnings: [String] {
        var warnings: [String] = []
        if !home.isEmpty, site(forKey: home) == nil {
            warnings.append("home=\(home) 未匹配任何 sites[].key，将回退到第一个可用站点")
        }
        if !parse.isEmpty, parser(named: parse) == nil {
            warnings.append("parse=\(parse) 未匹配任何 parses[].name，将回退到第一个可用解析器")
        }
        if sites.isEmpty {
            warnings.append("sites 为空")
        }
        for (site, reason) in unavailableSiteReasons {
            warnings.append("站点 \(site.name)(\(site.key)) 不可用：\(reason)")
        }
        return warnings
    }
}
