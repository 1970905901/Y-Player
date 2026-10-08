@testable import CatVodCore
import Foundation
import Testing

/// 配置里 `groupRules` 的**形状**（M06d 同批修正的回归测试）。
///
/// 上游这个字段是 `GroupRule.arrayFrom(fetchArray(object, "groupRules"))` ——
/// 形状是 `id` / `name` / `regex`（**单条字符串**）/ `enabled` / `source` / `wrapBracket`，**没有 `hosts`**。
/// 本项目曾经按 `{name, hosts, regex: [String]}` 建模，后果同样是静默失效（解析成空规则）。
@Suite("配置里的 groupRules 形状（M06d 修正）")
struct SourceConfigGroupRulesTests {
    private func config(_ json: String) throws -> SourceConfig {
        try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8))
    }

    @Test("真形状能解析出来，并且能直接喂给分组条")
    func decodesRealShape() throws {
        let json = #"{"sites":[],"groupRules":[{"id":"g1","name":"井号分组","regex":"#(.+)$","enabled":true}]}"#
        let value = try config(json)

        #expect(value.groupRules.count == 1)
        let rule = try #require(value.groupRules.first)
        #expect(rule.id == "g1")
        #expect(rule.name == "井号分组")
        #expect(rule.regex == "#(.+)$")
        #expect(rule.source == GroupRule.sourceInterface)
        #expect(rule.enabled)
        #expect(rule.extract("前缀#分组A") == ["分组A"])
        // 抽出来的标签就是分组条要的东西
        #expect(GroupRuleConfig.extract("前缀#分组A", interfaceRules: value.groupRules) == ["分组A"])
    }

    @Test("没有 regex 的规则被整条丢掉（对齐上游 normalize）")
    func dropsRulesWithoutRegex() throws {
        let json = #"{"sites":[],"groupRules":[{"name":"空的"},{"name":"有","regex":"#(.+)$"}]}"#
        let value = try config(json)

        #expect(value.groupRules.count == 1)
        #expect(value.groupRules.first?.name == "有")
    }

    @Test("旧形状（`hosts` + `regex` 数组）会被整条丢掉，而不是静默半生效")
    func legacyShapeIsDropped() throws {
        let json = #"{"sites":[],"groupRules":[{"name":"旧的","hosts":["a.example.com"],"regex":["#(.+)$"]}]}"#
        let value = try config(json)

        #expect(value.groupRules.isEmpty)
    }

    @Test("缺 `source` / `enabled` 按上游补默认值（interface / 启用）")
    func fillsDefaults() throws {
        let json = #"{"sites":[],"groupRules":[{"name":"接口规则","regex":"#(.+)$"}]}"#
        let rule = try #require(try config(json).groupRules.first)

        #expect(rule.source == GroupRule.sourceInterface)
        #expect(rule.enabled)
        #expect(!rule.id.isEmpty)
    }
}
