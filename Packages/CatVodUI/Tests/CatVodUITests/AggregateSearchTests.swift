import CatVodCore
@testable import CatVodUI
import Testing

@Suite("聚合搜索：搜哪些站点 / 结果怎么归位")
struct AggregateSearchTests {
    /// 造一个能搜的站点（`type=1` 走 CMS 通道，`availability` 自然是可用）。
    private func site(key: String, name: String = "", indexs: Int = 0, searchable: Int = 1) -> Site {
        Site(
            key: key,
            name: name,
            type: 1,
            api: "https://example.com/\(key)",
            indexs: indexs,
            searchable: searchable
        )
    }

    @Test("可搜站点：永久禁搜与平台不可用的都不算，临时禁搜（2）仍算")
    func searchableSitesFilters() {
        let sites = [site(key: "a"), site(key: "b", searchable: 0), site(key: "c", searchable: 2)]
        #expect(AggregateSearchRules.searchableSites(sites: sites).map(\.key) == ["a", "c"])
    }

    @Test("有索引站点就只搜「索引站点」——上游 indexs 的语义就是参与聚合搜索")
    func prefersIndexSites() {
        let sites = [site(key: "a"), site(key: "b", indexs: 1), site(key: "c", indexs: 1)]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["b", "c"])
    }

    @Test("一个索引站点都没有就回落全部可搜站点（新配置常常没人标 indexs）")
    func fallsBackToAllSearchable() {
        let sites = [site(key: "a"), site(key: "b")]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["a", "b"])
    }

    @Test("永久禁搜（searchable=0）的站点不进候选，哪怕标了 indexs")
    func skipsSearchDisabledSites() {
        let sites = [site(key: "a", indexs: 1, searchable: 0), site(key: "b", indexs: 1)]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["b"])
    }

    @Test("临时禁搜（searchable=2）仍进候选：口径与换源一致（isUsable）")
    func keepsTemporarilyDisabledSites() {
        let sites = [site(key: "a", searchable: 2)]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["a"])
    }

    @Test("归位：只留有命中的站点、顺序照站点清单（并发谁先回来不算数）")
    func sectionsKeepSiteOrder() {
        let sites = [site(key: "a"), site(key: "b"), site(key: "c")]
        let hits = [
            "c": [VodItem(vodID: "3", vodName: "丙")],
            "a": [VodItem(vodID: "1", vodName: "甲")],
        ]
        let sections = AggregateSearchRules.sections(
            sites: sites,
            hits: hits,
            names: ["a": "甲站", "c": "丙站"]
        )
        #expect(sections.map(\.siteKey) == ["a", "c"])
        #expect(sections.map(\.siteName) == ["甲站", "丙站"])
        #expect(sections.map(\.count) == [1, 1])
    }

    @Test("零命中与搜索失败一样：都不占左栏的位置")
    func emptyHitsAreDropped() {
        let sites = [site(key: "a"), site(key: "b"), site(key: "c")]
        // b 搜到了但是空的、c 整个没进 hits（= 请求失败被跳过）。
        let hits = ["a": [VodItem(vodID: "1")], "b": []]
        #expect(AggregateSearchRules.sections(sites: sites, hits: hits).map(\.siteKey) == ["a"])
    }

    @Test("展示名缺失时回落站点原名；名字也空就回落 key")
    func nameFallsBack() {
        let sites = [site(key: "a", name: "甲站"), site(key: "b")]
        let hits = ["a": [VodItem(vodID: "1")], "b": [VodItem(vodID: "2")]]
        let sections = AggregateSearchRules.sections(sites: sites, hits: hits)
        #expect(sections.map(\.siteName) == ["甲站", "b"])
    }
}
