@testable import CatVodCore
import Testing

/// 内置规则包资产（`Resources/hls_rules.json`）—— 把上游的**维护规则写成断言**。
///
/// 上游对内置规则定的门槛是「默认关闭 + 有『该删』和『不该删』两侧证据」。前一条能测，就测：
/// 万一以后有人往资产里塞一条 `enabledByDefault: true`，这里会先红。
/// 规则集当前是空的也有测试盯着 —— 那是**有意为空**，不是忘了加。
@Suite("内置广告规则包资产")
struct HLSBuiltinRulesTests {
    @Test("资产解析得出来，`schemaVersion` / 包 id 符合约定")
    func packageLoads() {
        let package = HLSBuiltinRules.package

        #expect(package.schemaVersion == HLSAdRulePackage.supportedSchemaVersion)
        #expect(package.packageId == "yplayer-builtin-hls")
        #expect(package.version >= 1)
    }

    @Test("规则集当前为空 —— 有意为之（没证据的规则不进内置集）")
    func ruleSetIsIntentionallyEmpty() {
        #expect(HLSBuiltinRules.rules.isEmpty)
    }

    @Test("以后加规则：必须默认关闭、id 唯一、正则编得出来")
    func futureRulesMustBeOffByDefaultAndValid() {
        let rules = HLSBuiltinRules.rules

        let allDisabledByDefault = rules.allSatisfy { !$0.enabledByDefault }
        #expect(allDisabledByDefault)
        #expect(Set(rules.map(\.id)).count == rules.count)
        let allCompile = rules.allSatisfy { (try? $0.compile()) != nil }
        #expect(allCompile)
    }

    @Test("状态键的源标识带上包 id 与版本")
    func sourceIDCarriesPackageIdentity() {
        #expect(HLSBuiltinRules.sourceID == "yplayer-builtin-hls@\(HLSBuiltinRules.package.version)")
    }
}
