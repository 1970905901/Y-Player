import CatVodCore

// 发现页（`HomeView`）的纯逻辑：翻页判定、筛选行模型、站点切换面板的行模型。
//
// 刻意与视图分开：参考录屏里有几处「看不见的分支」——
// 上游不给 `pagecount` 时要靠「返回空列表」停下上拉加载、上游没给筛选名时不出左侧标签列、
// 站点名为空时面板与按钮都要回落 `key`。这类分支在真机上很难手工造出来，只有纯函数才方便单测覆盖。

/// 发现页的翻页判定。
///
/// 对齐参考录屏：发现页**没有**「上一页 / 下一页」按钮，滚动到底部自动接着加载，
/// 所以「还能不能加载」必须判断得可靠 —— 判错就是无限请求空页。
enum DiscoverPaging {
    /// 是否还能继续加载下一页。
    ///
    /// - `reachedEnd`：上次请求返回了空列表（上游分页到底，且它没给 `pagecount`）；
    /// - `itemCount == 0`：首屏还没有内容（由加载态负责），此时不翻页；
    /// - `pageCount <= 0`：上游没给总页数，只能靠 `reachedEnd` 停。
    static func canLoadMore(page: Int, pageCount: Int, itemCount: Int, reachedEnd: Bool) -> Bool {
        guard !reachedEnd, itemCount > 0 else {
            return false
        }
        return pageCount <= 0 || page < pageCount
    }
}

/// 发现页的一行筛选（参考视频：左侧筛选名 + 右侧一串胶囊）。
///
/// 上游 `filters` 的 `name` 可能为空，参考录屏里两种形态都出现过：
/// 「木偶剧集」每行都有名字（剧情 / 地区 / 语言 / 时间），「玩偶」源则只有胶囊没有名字。
/// 这里原样保留上游数据，由 `showsName` 决定要不要那一列。
struct DiscoverFilterRow: Hashable, Identifiable {
    /// 提交参数名（放入 `extend`）。
    var key: String
    /// 上游给的显示名；可为空。
    var name: String
    /// 可选值。
    var values: [VodFilterValue]
    /// 当前选中值：优先用户已选，其次上游 `init`。
    var selectedValue: String

    var id: String { key }

    /// 是否显示左侧的筛选名。
    var showsName: Bool {
        !name.isEmpty
    }

    /// 从上游 `filters` 与用户已选值构造回显模型。
    ///
    /// `selected` 里没有该 `key` 时用上游 `init`，与旧版 Picker 的默认高亮一致
    /// （「全部」这类默认项不会错位）。
    static func rows(filters: [VodFilter], selected: [String: String]) -> [DiscoverFilterRow] {
        filters.map { filter in
            DiscoverFilterRow(
                key: filter.key,
                name: filter.name,
                values: filter.values,
                selectedValue: selected[filter.key] ?? filter.initialValue
            )
        }
    }

    /// 某个可选值是否是当前选中项。
    func isSelected(_ value: VodFilterValue) -> Bool {
        value.value == selectedValue
    }
}

extension VodFilterValue {
    /// 胶囊上显示的文字：上游给了 `n` 就用它，否则退回提交值 `v`。
    var chipTitle: String {
        name.isEmpty ? value : name
    }
}

/// 站点切换面板里的一行。
struct DiscoverSiteRow: Identifiable, Equatable {
    /// 站点 `key`（切换时回传它）。
    var key: String
    /// 行里显示的名字。
    var title: String
    /// 是否是当前站点（右侧打勾）。
    var isSelected: Bool

    var id: String { key }
}

/// 站点切换面板的行模型。
///
/// 单测价值：录屏里的面板有三种容易做错的状态 —— 站点名为空、当前站点、站点顺序，
/// 它们在真机上都不好复现（上游配置随时会变），所以把判定放进纯函数。
enum DiscoverSiteList {
    /// 面板要列出的行：**保持上游站点顺序**（面板行序 = 配置里的站点序）。
    static func rows(sites: [Site], selectedKey: String) -> [DiscoverSiteRow] {
        sites.map { site in
            DiscoverSiteRow(key: site.key, title: title(for: site), isSelected: site.key == selectedKey)
        }
    }

    /// 站点显示名：上游没给名字时回落 `key`（工具栏按钮与面板用同一口径）。
    static func title(for site: Site) -> String {
        site.name.isEmpty ? site.key : site.name
    }
}
