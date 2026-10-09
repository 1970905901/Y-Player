import CatVodCore
@testable import CatVodUI
import SwiftUI
import Testing

@Suite("发现页：翻页判定与筛选行")
struct DiscoverPageTests {
    // MARK: - DiscoverPaging

    @Test("还没有内容时不翻页：首屏没回来，空翻页只会白发请求")
    func noPagingWithoutItems() {
        #expect(!DiscoverPaging.canLoadMore(page: 1, pageCount: 0, itemCount: 0, reachedEnd: false))
        #expect(!DiscoverPaging.canLoadMore(page: 2, pageCount: 5, itemCount: 0, reachedEnd: false))
    }

    @Test("上游给了总页数：按页码判断到头")
    func pagingWithPageCount() {
        #expect(DiscoverPaging.canLoadMore(page: 1, pageCount: 3, itemCount: 20, reachedEnd: false))
        #expect(DiscoverPaging.canLoadMore(page: 2, pageCount: 3, itemCount: 20, reachedEnd: false))
        #expect(!DiscoverPaging.canLoadMore(page: 3, pageCount: 3, itemCount: 20, reachedEnd: false))
        // 本地页码已经超过上游总页数（上游缩水了）也不能再翻。
        #expect(!DiscoverPaging.canLoadMore(page: 5, pageCount: 3, itemCount: 20, reachedEnd: false))
    }

    @Test("上游没给总页数：只能靠「返回空列表」这个信号停下")
    func pagingWithoutPageCount() {
        #expect(DiscoverPaging.canLoadMore(page: 7, pageCount: 0, itemCount: 20, reachedEnd: false))
        #expect(!DiscoverPaging.canLoadMore(page: 8, pageCount: 0, itemCount: 20, reachedEnd: true))
        // `reachedEnd` 优先于总页数：确实到底了就不再翻。
        #expect(!DiscoverPaging.canLoadMore(page: 8, pageCount: 9, itemCount: 20, reachedEnd: true))
    }

    // MARK: - DiscoverContentMerge

    @Test("分类接口不带 class：分类条不能被整页替换抹掉（「显示一下就不见了」的成因）")
    func contentMergeKeepsCategories() {
        var home = SpiderResult()
        home.categories = [VodCategory(typeID: "1", typeName: "玩偶电影")]

        var page = SpiderResult()
        page.pagecount = 9

        let merged = DiscoverContentMerge.content(preservingCategories: page, current: home)
        #expect(merged.categories == home.categories)
        #expect(merged.pagecount == 9)

        var richer = page
        richer.categories = [VodCategory(typeID: "2", typeName: "剧集")]
        #expect(DiscoverContentMerge.content(preservingCategories: richer, current: home).categories == richer.categories)
    }

    // MARK: - DiscoverFilterRow

    private func makeFilter(name: String = "地区") -> VodFilter {
        VodFilter(
            key: "area",
            name: name,
            initialValue: "全部",
            values: [
                VodFilterValue(name: "全部", value: "全部"),
                VodFilterValue(name: "中国大陆", value: "大陆"),
            ]
        )
    }

    @Test("选中值：用户选过用用户的，没选过用上游 init")
    func filterRowSelection() {
        let filter = makeFilter()

        let rows = DiscoverFilterRow.rows(filters: [filter], selected: [:])
        #expect(rows.count == 1)
        #expect(rows[0].key == "area")
        #expect(rows[0].selectedValue == "全部")
        #expect(rows[0].isSelected(VodFilterValue(name: "全部", value: "全部")))
        #expect(!rows[0].isSelected(VodFilterValue(name: "中国大陆", value: "大陆")))

        let chosen = DiscoverFilterRow.rows(filters: [filter], selected: ["area": "大陆"])
        #expect(chosen[0].selectedValue == "大陆")
        #expect(chosen[0].isSelected(VodFilterValue(name: "中国大陆", value: "大陆")))
    }

    @Test("上游没给筛选名就不出左侧标签列（参考录屏里两种形态都出现过）")
    func filterRowNameVisibility() {
        let named = DiscoverFilterRow.rows(filters: [makeFilter()], selected: [:])
        let unnamed = DiscoverFilterRow.rows(filters: [makeFilter(name: "")], selected: [:])
        #expect(named[0].showsName)
        #expect(!unnamed[0].showsName)
        #expect(named[0].values.count == unnamed[0].values.count)
    }

    @Test("多行筛选保持上游顺序（行序即界面行序）")
    func filterRowOrder() {
        let filters = [
            VodFilter(key: "area", name: "地区", initialValue: "全部"),
            VodFilter(key: "year", name: "时间", initialValue: "全部"),
            VodFilter(key: "by", name: "排序", initialValue: "时间"),
        ]
        let rows = DiscoverFilterRow.rows(filters: filters, selected: [:])
        #expect(rows.map { $0.key } == ["area", "year", "by"])
        #expect(rows.map { $0.selectedValue } == ["全部", "全部", "时间"])
    }

    @Test("胶囊文字：上游给了 n 用它，否则退回提交值 v")
    func chipTitle() {
        #expect(VodFilterValue(name: "中国大陆", value: "大陆").chipTitle == "中国大陆")
        #expect(VodFilterValue(name: "", value: "4k").chipTitle == "4k")
    }

    // MARK: - 展示件

    @Test("各展示件都能构造（网格列数、海报比例是版式约定）")
    @MainActor
    func viewsConstruct() {
        let item = VodItem(vodID: "1", vodName: "片名", vodPic: "", vodRemarks: "更新至 58 集")
        let row = DiscoverFilterRow(
            key: "area",
            name: "地区",
            values: [VodFilterValue(name: "全部", value: "全部")],
            selectedValue: "全部"
        )
        _ = DiscoverCategoryStrip(categories: [], selectedID: "", onSelect: { _ in })
        _ = DiscoverFilterStrip(rows: [row], onSelect: { _, _ in })
        _ = DiscoverFilterChip(title: "全部", isSelected: true) { }
        _ = DiscoverPosterCard(item: item)
        _ = DiscoverSitePanel(sites: [], selectedKey: "", onSelect: { _ in })
        // 参考录屏里网格是 3 列、海报接近 2:3。
        #expect(HomeView.posterColumnCount == 3)
        #expect(DiscoverPosterCard.aspectRatio < 1)
    }

    // MARK: - DiscoverSiteList（站点切换面板）

    private func makeSite(key: String, name: String) -> Site {
        Site(key: key, name: name, type: 3, api: "/spider/\(key)")
    }

    @Test("站点行：空名回落 key、当前站点打勾、顺序与上游一致")
    func siteRows() {
        let sites = [
            makeSite(key: "wogg", name: "玩偶|4K"),
            makeSite(key: "noName", name: ""),
            makeSite(key: "douban", name: "豆瓣|首页"),
        ]
        let rows = DiscoverSiteList.rows(sites: sites, selectedKey: "noName")
        #expect(rows.map(\.key) == ["wogg", "noName", "douban"])
        #expect(rows.map(\.title) == ["玩偶|4K", "noName", "豆瓣|首页"])
        #expect(rows.map(\.isSelected) == [false, true, false])
        #expect(rows[1].id == "noName")
    }

    @Test("站点行：还没选中站点时一行都不打勾（面板照样列出全部站点）")
    func siteRowsWithoutSelection() {
        let rows = DiscoverSiteList.rows(sites: [makeSite(key: "wogg", name: "玩偶|4K")], selectedKey: "")
        #expect(rows.count == 1)
        #expect(!rows[0].isSelected)
        // 工具栏按钮与面板用的是同一个回落口径。
        #expect(DiscoverSiteList.title(for: makeSite(key: "wogg", name: "")) == "wogg")
    }

    @Test("站点面板与「切换」图标都能构造（面板宽高比取自录屏）")
    @MainActor
    func sitePanelConstructs() {
        _ = DiscoverSiteSwitchGlyph()
        _ = DiscoverSitePanel(
            sites: [makeSite(key: "wogg", name: "玩偶|4K")],
            selectedKey: "wogg",
            onSelect: { _ in }
        )
        #expect(DiscoverSitePanel.widthFraction > 0.5)
        #expect(DiscoverSitePanel.widthFraction < 1)
        #expect(DiscoverSitePanel.heightFraction > DiscoverSitePanel.widthFraction)
    }
}
