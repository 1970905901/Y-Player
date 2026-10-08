@testable import CatVodCore
import Foundation
import Testing

/// HLS 规则包与启用状态。
///
/// 对齐参考实现 `HlsRulePackageTest`：包只认 `schemaVersion == 2`、坏 JSON 当空包、
/// 内置规则**默认关闭**（要显式打开），以及状态键的形状（第 3 条断言正是「源标识不进键」）。
@Suite("HLS 规则包与状态（对齐 HlsRulePackage / HlsRuleState）")
struct HLSAdRulePackageTests {
    private let packageJSON = #"{"schemaVersion":2,"packageId":"builtin-hls","version":2,"rules":["# +
        #"{"id":"builtin.example.v1","name":"示例规则","version":2,"enabledByDefault":false,"# +
        #""playlistHostSuffixes":["video.example.com"],"hostSuffixes":["ads.example.com"],"minimumSignals":1}]}"#

    @Test("解析带版本号的规则包")
    func parsesVersionedPackage() {
        let value = HLSAdRulePackage.parse(packageJSON)

        #expect(value.schemaVersion == 2)
        #expect(value.packageId == "builtin-hls")
        #expect(value.version == 2)
        #expect(value.rules.count == 1)
        #expect(value.rules.first?.id == "builtin.example.v1")
        #expect(value.rules.first?.name == "示例规则")
    }

    @Test("版本不认识 / 坏 JSON → 空包（不按认得出的字段凑合）")
    func malformedPackageFallsBackToEmpty() {
        #expect(HLSAdRulePackage.parse("not-json").rules.isEmpty)
        #expect(HLSAdRulePackage.parse(#"{"schemaVersion":1,"packageId":"x","rules":[]}"#).rules.isEmpty)
        #expect(HLSAdRulePackage.parse(#"{"schemaVersion":3,"packageId":"x","rules":[]}"#).packageId.isEmpty)
    }

    @Test("内置规则默认关闭：必须显式打开才生效，且状态键里不出现源标识原文")
    func builtinRuleRequiresExplicitOverride() throws {
        let rule = try #require(HLSAdRulePackage.parse(packageJSON).rules.first)
        let key = HLSAdRuleState.key(origin: "builtin", sourceID: "builtin-hls", ruleID: rule.id)

        #expect(!key.contains("builtin-hls"))
        #expect(!HLSAdRuleState.resolveEnabled(rule, key: key, overrides: [:]))
        #expect(HLSAdRuleState.resolveEnabled(rule, key: key, overrides: [key: true]))
    }

    @Test("本地开关优先于规则包的建议值")
    func overrideBeatsDefault() throws {
        let rule = try #require(HLSAdRule.parse(
            #"{"id":"builtin.example.v1","enabledByDefault":true,"playlistHostSuffixes":["v.example.com"],"minimumSignals":1}"#
        ))
        let key = HLSAdRuleState.key(origin: "builtin", sourceID: "builtin-hls", ruleID: rule.id)

        #expect(HLSAdRuleState.resolveEnabled(rule, key: key, overrides: [:]))
        #expect(!HLSAdRuleState.resolveEnabled(rule, key: key, overrides: [key: false]))
    }

    @Test("状态键：稳定、含来源与规则 id、不含源标识原文")
    func stateKeyShape() {
        let key = HLSAdRuleState.key(origin: "vod", sourceID: "https://example.com/a:b.json", ruleID: "r:1")

        #expect(key.hasPrefix("vod:"))
        #expect(key.hasSuffix(":r_1"))
        #expect(!key.contains("https://example.com"))
        // 同一输入必须每次都一样：不然「删了几段」的统计和开关状态会对不上
        let again = HLSAdRuleState.key(origin: "vod", sourceID: "https://example.com/a:b.json", ruleID: "r:1")
        #expect(key == again)
    }
}
