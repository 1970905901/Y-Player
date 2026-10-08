import CatVodCore
@testable import CatVodUI
import Testing

/// 站点面板的**分组条**：从站点名抽标签 → 收集分组 → 点选筛选。
///
/// 这一层是上游 `SiteDialog` 里最容易做错的部分（抽标签、分组顺序、筛选三件事都在面板生命周期里），
/// 所以全部走纯函数，面板本身只负责摆 UI。
@Suite("站点面板：分组条")
struct DiscoverSiteGroupTests {
    private func makeSite(key: String, name: String) -> Site {
        Site(key: key, name: name, type: 3, api: "/spider/\(key)")
    }

    private var rules: [GroupRule] {
        GroupRuleConfig.builtins
    }

    @Test("抽标签走**显示名**：没有名字的站点用 key，抽不出标签就不进表")
    func tagsFromDisplayName() {
        let sites = [makeSite(key: "wogg", name: "玩偶|4K"), makeSite(key: "noName", name: "")]

        let tags = DiscoverSiteList.tags(sites: sites, input: input())

        #expect(tags["wogg"] == ["4K"])
        #expect(tags["noName"] == nil)
    }

    @Test("分组收集：按站点顺序、去重，再按存的顺序排")
    func groupsFollowSiteOrder() {
        let sites = [
            makeSite(key: "a", name: "甲|4K"),
            makeSite(key: "b", name: "乙|首页"),
            makeSite(key: "c", name: "丙|4K"),
        ]
        let tags = DiscoverSiteList.tags(sites: sites, input: input())

        #expect(DiscoverSiteList.groups(sites: sites, tags: tags) == ["4K", "首页"])
        #expect(DiscoverSiteList.groups(sites: sites, tags: tags, savedOrder: ["首页"]) == ["首页", "4K"])
    }

    @Test("点某个分组只留这个分组的站点；空分组名 = 不筛（点第二次取消）")
    func filteringByGroup() {
        let sites = [makeSite(key: "a", name: "甲|4K"), makeSite(key: "b", name: "乙|首页")]
        let tags = DiscoverSiteList.tags(sites: sites, input: input())

        let only4K = DiscoverSiteList.rows(sites: sites, selectedKey: "a", tags: tags, selectedGroup: "4K")
        #expect(only4K.map(\.key) == ["a"])
        #expect(only4K.first?.isSelected == true)

        let onlyHome = DiscoverSiteList.rows(sites: sites, selectedKey: "a", tags: tags, selectedGroup: "首页")
        #expect(onlyHome.map(\.key) == ["b"])

        let all = DiscoverSiteList.rows(sites: sites, selectedKey: "a", tags: tags, selectedGroup: "")
        #expect(all.map(\.key) == ["a", "b"])
    }

    @Test("所有站点都没标签时分组为空 —— 面板据此整条隐藏")
    func noTagsMeansNoGroupBar() {
        let sites = [makeSite(key: "a", name: "普通线路")]

        let tags = DiscoverSiteList.tags(sites: sites, input: input())

        #expect(DiscoverSiteList.groups(sites: sites, tags: tags).isEmpty)
    }

    @Test("接口规则一起参与抽标签；被关掉的内置规则不再出标签")
    func interfaceRulesAndDisabledBuiltin() {
        let sites = [makeSite(key: "a", name: "[主力]站点A")]
        let extra = GroupRule.user(name: "井号", regex: "#(.+)$")

        #expect(DiscoverSiteList.tags(sites: sites, input: input(rules: rules + [extra]))["a"] == ["主力"])

        let disabled = DiscoverSiteList.tags(
            sites: sites,
            input: input(disabledIDs: [GroupRuleConfig.builtinBracket])
        )
        #expect(disabled["a"] == nil)
    }

    @Test("面板给的上移/下移回调算出的新顺序：隐藏的分组不会被挤到末尾")
    func movingGroupKeepsHiddenSlots() {
        // 站点全集能出三个分组，但面板当前只筛出两个：
        let full = ["4K", "首页", "影视"]
        let visibleAfterMove = ["首页", "4K", "影视"]

        #expect(SiteGroupOrder.mergedVisibleOrder(fullOrder: full, visibleOrder: visibleAfterMove)
            == ["首页", "4K", "影视"])
    }

    @Test("改名之后：显示名与分组标签都按新名字来（旧标签跟着消失）")
    func customNameDrivesTitleAndTags() {
        let sites = [makeSite(key: "a", name: "[荐][采集]影视天堂")]
        let names = ["a": "[主力][短剧]我的一号站"]

        #expect(DiscoverSiteList.title(for: sites[0], names: names) == "[主力][短剧]我的一号站")

        let renamed = DiscoverSiteList.tags(sites: sites, input: input(names: names))
        #expect(renamed["a"] == ["主力", "短剧"])
        #expect(DiscoverSiteList.groups(sites: sites, tags: renamed) == ["主力", "短剧"])

        // 没改名时用的是原始名
        #expect(DiscoverSiteList.tags(sites: sites, input: input())["a"] == ["荐", "采集"])
    }

    @Test("改名成没有标签的名字：分组条上这个站点就没了")
    func customNameWithoutTagsDropsGroup() {
        let sites = [makeSite(key: "a", name: "[荐]影视天堂")]
        let names = ["a": "我的站"]

        let tags = DiscoverSiteList.tags(sites: sites, input: input(names: names))

        #expect(tags["a"] == nil)
        #expect(DiscoverSiteList.groups(sites: sites, tags: tags).isEmpty)
    }

    @Test("搜索：新名 / 原名 / key 都能命中，筛选后的顺序仍按站点顺序")
    func searchMatchesNamesAndKey() {
        let sites = [
            makeSite(key: "csp_xxx", name: "XYQ线路一"),
            makeSite(key: "csp_yyy", name: "XYQ线路二"),
        ]
        let names = ["csp_xxx": "[主力]爸妈用"]

        #expect(rows(sites, names: names, keyword: "爸妈").map(\.key) == ["csp_xxx"])
        #expect(rows(sites, names: names, keyword: "xyq").map(\.key) == ["csp_xxx", "csp_yyy"])
        #expect(rows(sites, names: names, keyword: "csp_yyy").map(\.key) == ["csp_yyy"])
        #expect(rows(sites, names: names, keyword: "音乐").isEmpty)
        #expect(rows(sites, names: names, keyword: "").map(\.key) == ["csp_xxx", "csp_yyy"])
        // 命中后显示的是**生效名**
        #expect(rows(sites, names: names, keyword: "爸妈").first?.title == "[主力]爸妈用")
    }

    @Test("搜索与分组筛选叠加：先按搜索过滤，再按分组过滤")
    func searchCombinesWithGroupFilter() {
        let sites = [
            makeSite(key: "a", name: "甲|4K"),
            makeSite(key: "b", name: "乙|4K"),
            makeSite(key: "c", name: "甲|首页"),
        ]
        let tags = DiscoverSiteList.tags(sites: sites, input: input())

        let result = rows(sites, tags: tags, selectedGroup: "4K", keyword: "甲")

        #expect(result.map(\.key) == ["a"])
    }

    @Test("自建规则参与抽标签；关掉某条规则后它抽的标签立刻消失")
    func userRulesAndDisableChangeGroupBar() {
        let piped = [makeSite(key: "a", name: "某站|4K")]
        let tilde = [makeSite(key: "b", name: "某站~杂谈")]
        let userRule = GroupRule.user(name: "波浪号", regex: "~(.+)$")

        // 自建规则抽出来的标签进分组条
        #expect(DiscoverSiteList.tags(sites: tilde, input: input(userRules: [userRule]))["b"] == ["杂谈"])

        // 关掉它：这个站点就没标签了
        let withoutUser = input(userRules: [userRule], disabledIDs: [userRule.id])
        #expect(DiscoverSiteList.tags(sites: tilde, input: withoutUser)["b"] == nil)

        // 关掉内置的竖线规则：`某站|4K` 不再属于 4K 分组
        #expect(DiscoverSiteList.tags(sites: piped, input: input())["a"] == ["4K"])
        #expect(DiscoverSiteList.tags(
            sites: piped,
            input: input(disabledIDs: [GroupRuleConfig.builtinPipe])
        )["a"] == nil)
    }

    /// 造面板输入（默认就是「四条内置、全开、无改名」）—— M06g 起抽标签的入口统一走 `input:`。
    private func input(
        rules: [GroupRule] = GroupRuleConfig.builtins,
        userRules: [GroupRule] = [],
        disabledIDs: Set<String> = [],
        names: [String: String] = [:]
    ) -> DiscoverSiteRuleInput {
        DiscoverSiteRuleInput(
            interfaceRules: rules,
            userRules: userRules,
            disabledIDs: disabledIDs,
            names: names
        )
    }

    private func rows(
        _ sites: [Site],
        names: [String: String] = [:],
        tags: [String: [String]] = [:],
        selectedGroup: String = "",
        keyword: String = ""
    ) -> [DiscoverSiteRow] {
        DiscoverSiteList.rows(
            sites: sites,
            selectedKey: "",
            names: names,
            tags: tags,
            selectedGroup: selectedGroup,
            keyword: keyword
        )
    }
}
