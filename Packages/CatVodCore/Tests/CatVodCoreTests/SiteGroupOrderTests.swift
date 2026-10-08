@testable import CatVodCore
import Testing

/// 分组条顺序：**逐条对齐上游 `SiteGroupOrderStoreTest`**（那 7 条就是它的行为规格）。
///
/// 顺带说明为什么「合并可见顺序」这条非要有：分组条只显示有站点的分组，但排序按全集存 ——
/// 不然一个分组因为当下不可见被挤到末尾，下次它出现时位置就乱了。
@Suite("分组条顺序（对齐 SiteGroupOrderStoreTest）")
struct SiteGroupOrderTests {
    @Test("没有存过顺序时保持默认顺序")
    func orderKeepsDefaultWhenNoSavedOrder() {
        let groups = ["注入", "首页", "直播", "影视", "4K"]

        #expect(SiteGroupOrder.order(groups, savedOrder: []) == groups)
    }

    @Test("存过的按存的次序排前面，没存过的按默认顺序接在后面")
    func orderAppliesSavedThenAppendsUnknown() {
        let groups = ["注入", "首页", "直播", "影视", "4K", "新组"]

        #expect(SiteGroupOrder.order(groups, savedOrder: ["4K", "首页", "影视"])
            == ["4K", "首页", "影视", "注入", "直播", "新组"])
    }

    @Test("失效、空白、重复项一律忽略；原列表里的重复与空白也一并清掉")
    func orderIgnoresStaleBlankAndDuplicate() {
        let groups = ["首页", "影视", "4K", "影视", " "]

        #expect(SiteGroupOrder.order(groups, savedOrder: ["失效分组", "影视", "", "影视", "首页"])
            == ["影视", "首页", "4K"])
    }

    @Test("合并可见顺序时保留隐藏分组的槽位")
    func mergeVisibleOrderPreservesHiddenSlots() {
        let full = ["注入", "首页", "直播", "影视", "4K"]
        let visible = ["4K", "注入", "首页", "影视"]

        #expect(SiteGroupOrder.mergedVisibleOrder(fullOrder: full, visibleOrder: visible)
            == ["4K", "注入", "直播", "首页", "影视"])
    }

    @Test("可见列表为空时原样返回完整顺序")
    func mergeVisibleOrderKeepsFullOrderWhenVisibleEmpty() {
        let full = ["注入", "首页", "直播"]

        #expect(SiteGroupOrder.mergedVisibleOrder(fullOrder: full, visibleOrder: []) == full)
    }

    @Test("上移 / 下移一次一格")
    func moveChangesOnePositionAtATime() {
        var groups = ["A", "B", "C"]

        #expect(SiteGroupOrder.move(&groups, group: "B", direction: -1))
        #expect(groups == ["B", "A", "C"])
        #expect(SiteGroupOrder.move(&groups, group: "B", direction: 1))
        #expect(groups == ["A", "B", "C"])
    }

    @Test("越界、找不到、非法方向：返回 false 且不动数组")
    func moveRejectsBoundariesAndMissingGroups() {
        var groups = ["A", "B", "C"]

        #expect(!SiteGroupOrder.move(&groups, group: "A", direction: -1))
        #expect(!SiteGroupOrder.move(&groups, group: "C", direction: 1))
        #expect(!SiteGroupOrder.move(&groups, group: "missing", direction: 1))
        #expect(!SiteGroupOrder.move(&groups, group: "B", direction: 0))
        #expect(!SiteGroupOrder.move(&groups, group: "B", direction: 2))
        #expect(groups == ["A", "B", "C"])
    }
}
