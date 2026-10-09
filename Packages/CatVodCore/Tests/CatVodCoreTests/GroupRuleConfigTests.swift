@testable import CatVodCore
import Foundation
import Testing

/// 分组规则的**生效集合**（对齐上游 `GroupRuleConfig`）：内置 + 接口规则 − 关掉的，再合并抽标签。
@Suite("分组规则的生效集合（对齐 GroupRuleConfig）")
struct GroupRuleConfigTests {
    @Test("内置 + 接口规则一起抽，结果去重且保持顺序")
    func mergesAndDedupes() {
        let interfaceRule = GroupRule.user(name: "井号", regex: "#(.+)$")

        let groups = GroupRuleConfig.extract("[主力]站点A#新组", interfaceRules: [interfaceRule])

        #expect(groups == ["主力", "新组"])
    }

    @Test("关掉某条内置规则后它不再抽标签（另外三条照旧）")
    func disabledBuiltinIsSkipped() {
        let text = "[主力]站点A|4K"

        #expect(GroupRuleConfig.extract(text) == ["主力", "4K"])
        #expect(GroupRuleConfig.extract(text, disabledIDs: [GroupRuleConfig.builtinBracket]) == ["4K"])
    }

    @Test("接口规则自己写了 `enabled=false`、或正则编不出来：都不生效")
    func inactiveInterfaceRulesAreSkipped() {
        let off = GroupRule(
            id: "off",
            name: "关掉",
            regex: "#(.+)$",
            enabled: false,
            source: GroupRule.sourceInterface
        )
        let broken = GroupRule(id: "broken", name: "坏", regex: "(", source: GroupRule.sourceInterface)

        let active = GroupRuleConfig.activeRules(interfaceRules: [off, broken])

        #expect(!active.contains { $0.id == "off" })
        #expect(!active.contains { $0.id == "broken" })
        #expect(active.count == GroupRuleConfig.builtins.count)
    }

    @Test("空文本不抽（省得让四条规则空跑）")
    func emptyTextIsIgnored() {
        #expect(GroupRuleConfig.extract("").isEmpty)
    }

    @Test("候选顺序：内置 → 接口 → 用户（顺序决定标签先后，照上游 entries()）")
    func entryOrderMatchesUpstream() {
        let interfaceRule = GroupRule(id: "i1", name: "接口", regex: "I(.+)$", source: GroupRule.sourceInterface)
        let userRule = GroupRule(id: "u1", name: "用户", regex: "U(.+)$", source: GroupRule.sourceUser)

        let entries = GroupRuleConfig.entries(interfaceRules: [interfaceRule], userRules: [userRule])

        #expect(entries.map(\.rule.id) == (GroupRuleConfig.builtins.map(\.id) + ["i1", "u1"]))
        let allEnabled = entries.allSatisfy(\.isEnabled)
        #expect(allEnabled)
    }

    @Test("用户自建规则参与抽标签，也能按 id 关掉")
    func userRulesParticipate() {
        let userRule = GroupRule(
            id: "u1",
            name: "用户",
            regex: "U(.+)$",
            source: GroupRule.sourceUser,
            wrapBracket: true
        )

        #expect(GroupRuleConfig.extract("站点U爸妈用", userRules: [userRule]) == ["[爸妈用]"])
        #expect(GroupRuleConfig.extract("站点U爸妈用", userRules: [userRule], disabledIDs: ["u1"]).isEmpty)

        // 用户规则自己写 `enabled=false` 也不生效
        let off = GroupRule(
            id: "u2",
            name: "关掉",
            regex: "U(.+)$",
            enabled: false,
            source: GroupRule.sourceUser
        )
        #expect(GroupRuleConfig.extract("站点U爸妈用", userRules: [off]).isEmpty)
    }

    @Test("内置规则只看「有没有被本地关掉」，不看它自己的 enabled（上游判法）")
    func builtinIgnoresOwnEnabledFlag() {
        #expect(GroupRuleConfig.entries().first?.isEnabled == true)
        #expect(GroupRuleConfig.entries(disabledIDs: [GroupRuleConfig.builtinBracket]).first?.isEnabled == false)
    }

    @Test("条数统计：生效 N / 候选 M（设置页那一行用它）")
    func counts() {
        let userRule = GroupRule(id: "u1", name: "用户", regex: "U(.+)$", source: GroupRule.sourceUser)
        let builtinCount = GroupRuleConfig.builtins.count

        #expect(GroupRuleConfig.totalCount(userRules: [userRule]) == builtinCount + 1)
        #expect(GroupRuleConfig.enabledCount(userRules: [userRule]) == builtinCount + 1)
        #expect(GroupRuleConfig.enabledCount(userRules: [userRule], disabledIDs: ["u1"]) == builtinCount)

        // 编不出正则的规则不算「生效」，但仍算「候选」
        let broken = GroupRule(id: "b1", name: "坏", regex: "(", source: GroupRule.sourceUser)
        #expect(GroupRuleConfig.enabledCount(userRules: [broken]) == builtinCount)
        #expect(GroupRuleConfig.totalCount(userRules: [broken]) == builtinCount + 1)
    }

    @Test("没有 id 的接口 / 用户规则直接跳过（对齐上游 `TextUtils.isEmpty(rule.getId())`）")
    func rulesWithoutIDAreSkipped() {
        let anonymous = GroupRule(id: "", name: "没 id", regex: "U(.+)$", source: GroupRule.sourceUser)

        #expect(GroupRuleConfig.totalCount(userRules: [anonymous]) == GroupRuleConfig.builtins.count)
    }
}
