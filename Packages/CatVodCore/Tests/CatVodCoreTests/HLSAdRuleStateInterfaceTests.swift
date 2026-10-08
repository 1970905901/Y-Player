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

/// 规则包那套生效判定（与接口规则**分开**测：包规则默认关）。
///
/// 两套判定搞混的后果很隐蔽：包规则明明是「默认关、要显式打开」，用错基准之后会变成
/// 「只要包作者写了 `enabledByDefault: true` 就自动生效」，用户会突然被删片段。
@Suite("规则包条目的开关语义")
struct HLSAdRuleStatePackageTests {
    private func rule(id: String, defaultOn: Bool) throws -> HLSAdRule {
        let json = """
        {"id":"\(id)","enabledByDefault":\(defaultOn),
         "playlistHostSuffixes":["video.example.com"],
         "hostSuffixes":["ads.example.com"],
         "minimumSignals":1}
        """
        return try #require(HLSAdRule.parse(json))
    }

    @Test("基准是包的 `enabledByDefault`（不是规则写没写 `enabled`）")
    func baseIsPackageDefault() throws {
        let off = try rule(id: "p1", defaultOn: false)
        let on = try rule(id: "p2", defaultOn: true)

        let entries = HLSAdRuleState.packageEntries([off, on], origin: "builtin", sourceID: "pkg@1", overrides: [:])

        #expect(entries.map(\.isEnabled) == [false, true])
    }

    @Test("本地开关两个方向都压过包的默认值")
    func overridesWin() throws {
        let off = try rule(id: "p1", defaultOn: false)
        let on = try rule(id: "p2", defaultOn: true)
        let probe = HLSAdRuleState.packageEntries([off, on], origin: "builtin", sourceID: "pkg@1", overrides: [:])

        let entries = HLSAdRuleState.packageEntries(
            [off, on],
            origin: "builtin",
            sourceID: "pkg@1",
            overrides: [probe[0].key: true, probe[1].key: false]
        )

        #expect(entries.map(\.isEnabled) == [true, false])
    }

    @Test("同 id 的包规则与接口规则不会串味（来源进键）")
    func originsDoNotCollide() throws {
        let rule = try rule(id: "same", defaultOn: false)

        let builtinKey = HLSAdRuleState.key(origin: "builtin", sourceID: "s", ruleID: rule.id)
        let interfaceKey = HLSAdRuleState.key(origin: "hlsRules", sourceID: "s", ruleID: rule.id)

        #expect(builtinKey != interfaceKey)
    }
}
