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
}
