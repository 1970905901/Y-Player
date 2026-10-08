@testable import CatVodCore
@testable import CatVodUI
import Testing

/// 分组规则设置的存档：**接口摘要 → {关掉的 id, 自建规则}**（上游 `GroupRuleStore` 的两份合并成一份）。
@Suite("分组规则设置存档")
struct SiteGroupRuleBookTests {
    @Test("编码 / 解码往返（自建规则整个跟着走，正则不丢）")
    func roundTrip() {
        let book = [
            "cfg:abc": SiteGroupRuleSettings(
                disabledIDs: [GroupRuleConfig.builtinBracket, "i1"],
                userRules: [GroupRule.user(name: "井号", regex: "#(.+)$", wrapBracket: true)]
            ),
        ]

        let restored = SiteGroupRuleBook.decode(SiteGroupRuleBook.encode(book))

        #expect(restored == book)
        #expect(restored["cfg:abc"]?.userRules.first?.wrapBracket == true)
        #expect(restored["cfg:abc"]?.userRules.first?.source == GroupRule.sourceUser)
        // 抽标签能力也要一起活下来
        #expect(restored["cfg:abc"]?.userRules.first?.extract("站点#新组") == ["[新组]"])
    }

    @Test("脏存档当空，绝不抛")
    func brokenDataFallsBack() {
        #expect(SiteGroupRuleBook.decode(nil).isEmpty)
        #expect(SiteGroupRuleBook.decode("").isEmpty)
        #expect(SiteGroupRuleBook.decode("{").isEmpty)
        #expect(SiteGroupRuleBook.decode("[1,2]").isEmpty)
    }

    @Test("解码时清洗：空桶、空 id、没正则的规则都丢掉")
    func decodeSanitizes() {
        let raw = """
        {"": {"disabledIDs": ["a"]},
         "cfg:abc": {"disabledIDs": ["", "x"], "userRules": []}}
        """

        #expect(SiteGroupRuleBook.decode(raw) == ["cfg:abc": SiteGroupRuleSettings(disabledIDs: ["x"])])
    }

    @Test("写入 / 清空：两样都没有就把整桶删掉；没有桶名就原样返回")
    func recording() {
        let settings = SiteGroupRuleSettings(disabledIDs: ["builtin_bracket_tag"], userRules: [])
        let written = SiteGroupRuleBook.recording(settings, for: "cfg:1", in: [:])
        #expect(written == ["cfg:1": settings])

        #expect(SiteGroupRuleBook.recording(SiteGroupRuleSettings(), for: "cfg:1", in: written).isEmpty)
        #expect(SiteGroupRuleBook.recording(settings, for: "", in: written) == written)
        // 只动自己那一桶
        let two = SiteGroupRuleBook.recording(settings, for: "cfg:2", in: written)
        #expect(two.count == 2)
        #expect(two["cfg:1"] == settings)
    }
}
