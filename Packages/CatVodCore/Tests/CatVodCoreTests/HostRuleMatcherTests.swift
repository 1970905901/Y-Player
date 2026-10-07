import CatVodCore
import Testing

@Suite("host 规则匹配：containOrMatch 语义")
struct HostRuleMatcherTests {
    @Test("`*` 命中一切")
    func wildcard() {
        #expect(HostRuleMatcher.matches(text: "api.example.com", rule: "*"))
        #expect(HostRuleMatcher.matches(text: "127.0.0.1", rule: "*"))
    }

    @Test("子串（contains）命中：上游默认就是子串匹配")
    func containsMatch() {
        #expect(HostRuleMatcher.matches(text: "api.example.com", rule: "example.com"))
        #expect(HostRuleMatcher.matches(text: "https://cdn.example.com/x.m3u8", rule: "example.com"))
        #expect(!HostRuleMatcher.matches(text: "api.example.org", rule: "example.com"))
    }

    @Test("整串正则命中（Java `matches` 语义，必须覆盖整串）")
    func regularExpressionMatch() {
        #expect(HostRuleMatcher.matches(text: "api.example.com", rule: "^api\\..*\\.com$"))
        // 正则只覆盖子串时不算命中（contains 也不命中）。
        #expect(!HostRuleMatcher.matches(text: "xapi.example.com", rule: "^api\\..*\\.com$"))
    }

    @Test("非法正则退化为不命中，而不是抛错")
    func invalidPattern() {
        #expect(!HostRuleMatcher.matches(text: "api.example.com", rule: "^api\\(.com$"))
    }

    @Test("空规则与空文本都不命中")
    func emptyInputs() {
        #expect(!HostRuleMatcher.matches(text: "api.example.com", rule: ""))
        #expect(!HostRuleMatcher.matches(text: "api.example.com", rule: "   "))
        #expect(!HostRuleMatcher.matches(text: "", rule: "example.com"))
    }

    @Test("firstMatch 返回第一条命中的规则（用于日志说明是哪条规则生效）")
    func firstMatch() {
        let rules = ["other.com", "example.com", "*"]
        #expect(HostRuleMatcher.firstMatch(text: "api.example.com", rules: rules) == "example.com")
        #expect(HostRuleMatcher.firstMatch(text: "nothing.io", rules: rules) == "*")
        #expect(HostRuleMatcher.firstMatch(text: "nothing.io", rules: []) == nil)
    }

    @Test("通配判定：只看是否含 `*`（与上游 bean.Proxy 一致）")
    func wildcardDetection() {
        #expect(HostRuleMatcher.isWildcard("*.example.com"))
        #expect(HostRuleMatcher.isWildcard("*"))
        #expect(!HostRuleMatcher.isWildcard("example.com"))
    }
}
