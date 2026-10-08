@testable import CatVodCore
import Testing

/// 站点显示名与搜索命中：**逐条对齐上游 `SiteNameRulesTest`**（那 7 条就是行为规格）。
///
/// 这里最容易做错的两件事：改名之后**标签要跟着新名重抽**（否则分组条还是旧标签），
/// 以及「把名字改回原来的样子」必须真的能还原（不能存成一条看起来一样的自定义名）。
@Suite("站点显示名与搜索（对齐 SiteNameRulesTest）")
struct SiteNameRulesTests {
    @Test("自定义名覆盖原始名，分组标签按新名抽")
    func customNameOverridesRawNameAndGroups() {
        let raw = "[荐][采集]影视天堂"
        let custom = "[主力][短剧]我的一号站"

        #expect(SiteNameRules.effectiveName(rawName: raw, customName: custom) == custom)
        #expect(SiteNameRules.groups(rawName: raw, customName: custom) == ["主力", "短剧"])
    }

    @Test("自定义名是空白时回落原始名，标签也按原始名抽")
    func blankCustomNameFallsBackToRawNameAndGroups() {
        #expect(SiteNameRules.effectiveName(rawName: "[原始]站源A", customName: "  ") == "[原始]站源A")
        #expect(SiteNameRules.groups(rawName: "[原始]站源A", customName: "") == ["原始"])
    }

    @Test("自定义名里没有标签：原始名的标签也跟着消失（改名是整套替换，不是叠加）")
    func customNameWithoutTagsRemovesRawGroups() {
        #expect(SiteNameRules.groups(rawName: "[原始]站源A", customName: "我的站").isEmpty)
    }

    @Test("同一分组出现多次只留一个，顺序按首次出现")
    func groupsAreOrderedAndDeduplicated() {
        #expect(SiteNameRules.groups(rawName: "", customName: "[主力][备用][主力]我的站") == ["主力", "备用"])
    }

    @Test("搜索命中：新名 / 原名 / 站点 key 任一包含关键词即可")
    func searchMatchesCustomNameRawNameAndKey() {
        let raw = "XYQ线路一"
        let custom = "[主力]爸妈用"
        let key = "csp_xxx"

        #expect(SiteNameRules.matchesSearch(rawName: raw, customName: custom, key: key, keyword: "爸妈"))
        #expect(SiteNameRules.matchesSearch(rawName: raw, customName: custom, key: key, keyword: "xyq"))
        #expect(SiteNameRules.matchesSearch(rawName: raw, customName: custom, key: key, keyword: "CSP_XXX"))
        #expect(SiteNameRules.matchesSearch(rawName: raw, customName: custom, key: key, keyword: "主力"))
        #expect(!SiteNameRules.matchesSearch(rawName: raw, customName: custom, key: key, keyword: "音乐"))
    }

    @Test("关键词为空（或只有空白）时不过滤")
    func emptyKeywordMatchesEverything() {
        #expect(SiteNameRules.matchesSearch(rawName: "", customName: "", key: "k", keyword: ""))
        #expect(SiteNameRules.matchesSearch(rawName: "", customName: "", key: "k", keyword: "   "))
    }

    @Test("改成和原名一样（含首尾空白）不算自定义名 —— 不落盘")
    func unchangedOriginalNameIsNotStoredAsCustomName() {
        #expect(SiteNameRules.customNameForStorage(rawName: "📁｜文件｜浏览", inputName: "📁｜文件｜浏览").isEmpty)
        #expect(SiteNameRules.customNameForStorage(rawName: "📁｜文件｜浏览", inputName: "  📁｜文件｜浏览  ").isEmpty)
    }

    @Test("真改了名、或加了标签：都要落盘")
    func editedNameOrAddedTagsAreStored() {
        #expect(SiteNameRules.customNameForStorage(rawName: "📁｜文件｜浏览", inputName: "  [本地]📁｜文件｜浏览  ")
            == "[本地]📁｜文件｜浏览")
        #expect(SiteNameRules.customNameForStorage(rawName: "📁｜文件｜浏览", inputName: "我的文件") == "我的文件")
    }

    @Test("显示名：生效名为空才回落站点 key")
    func displayNameFallsBackToKey() {
        #expect(SiteNameRules.displayName(rawName: "", customName: "", key: "csp_x") == "csp_x")
        #expect(SiteNameRules.displayName(rawName: "XYQ线路一", customName: "  ", key: "csp_x") == "XYQ线路一")
        #expect(SiteNameRules.displayName(rawName: "XYQ线路一", customName: "[主力]爸妈用", key: "csp_x") == "[主力]爸妈用")
    }
}
