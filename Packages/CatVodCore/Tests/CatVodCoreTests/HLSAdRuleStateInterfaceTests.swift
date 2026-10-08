@testable import CatVodCore
import Testing

/// 接口广告规则（`hlsRules`）的生效判定与状态键（M06h）。
///
/// 与规则包那套分开测：包里的规则走 `resolveEnabled`（本地开关 > `enabledByDefault` > 关），
/// 接口规则走 `resolveInterfaceEnabled`（**基准是规则自己写的 `enabled`**，本地开关两个方向都能覆盖）。
/// 两者混了会很隐蔽：包规则默认关、接口规则默认看接口怎么写，判错就是「规则看着开了其实没跑」。
@Suite("接口广告规则的开关")
struct HLSAdRuleStateInterfaceTests {
    private func rule(id: String, enabled: Bool?) throws -> HLSAdRule {
        let value = enabled.map { $0 ? "true" : "false" } ?? "null"
        let json = """
        {"id":"\(id)","enabled":\(value),
         "playlistHostSuffixes":["video.example.com"],
         "hostSuffixes":["ads.example.com"],
         "minimumSignals":1}
        """
        return try #require(HLSAdRule.parse(json))
    }

    @Test("基准：规则自己写 `enabled: true` 才算开（对齐上游 compileExternal）")
    func baseIsRuleOwnEnabled() throws {
        let on = try rule(id: "r1", enabled: true)
        let off = try rule(id: "r2", enabled: false)
        let unset = try rule(id: "r3", enabled: nil)

        #expect(HLSAdRuleState.resolveInterfaceEnabled(on, key: "k", overrides: [:]))
        #expect(!HLSAdRuleState.resolveInterfaceEnabled(off, key: "k", overrides: [:]))
        #expect(!HLSAdRuleState.resolveInterfaceEnabled(unset, key: "k", overrides: [:]))
    }

    @Test("本地开关两个方向都能覆盖：接口说开的能关，接口没开的能开")
    func overridesBothDirections() throws {
        let on = try rule(id: "r1", enabled: true)
        let unset = try rule(id: "r3", enabled: nil)

        #expect(!HLSAdRuleState.resolveInterfaceEnabled(on, key: "k", overrides: ["k": false]))
        #expect(HLSAdRuleState.resolveInterfaceEnabled(unset, key: "k", overrides: ["k": true]))
        // 别的键上的开关不影响这一条
        #expect(!HLSAdRuleState.resolveInterfaceEnabled(unset, key: "k", overrides: ["other": true]))
    }

    @Test("状态键：来源 + 源标识摘要（16 位）+ 规则 id，且不含明文源标识")
    func keyHidesSource() {
        let source = "https://example.com/config?token=secret"
        let key = HLSAdRuleState.key(origin: "hlsRules", sourceID: source, ruleID: "r1")

        #expect(key.hasPrefix("hlsRules:"))
        #expect(key.hasSuffix(":r1"))
        #expect(!key.contains("example.com"))
        #expect(!key.contains("secret"))
        #expect(key.count == "hlsRules:".count + 16 + ":r1".count)
    }

    @Test("`interfaceEntries`：列表与过滤用同一份键，覆盖值也一致")
    func entriesShareKeyAndState() throws {
        let rules = try [rule(id: "r1", enabled: true), rule(id: "r2", enabled: false)]
        let probe = HLSAdRuleState.interfaceEntries(rules, origin: "hlsRules", sourceID: "u", overrides: [:])
        let entries = HLSAdRuleState.interfaceEntries(
            rules,
            origin: "hlsRules",
            sourceID: "u",
            overrides: [probe[1].key: true]
        )

        #expect(entries.map(\.isEnabled) == [true, true])
        #expect(entries.map(\.key) == probe.map(\.key))
        #expect(entries[0].id == entries[0].key)
    }
}
