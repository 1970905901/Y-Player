import CatVodCore
import Testing

@Suite("代理规则选择与地址解析")
struct ProxyRuleResolverTests {
    private func rule(_ name: String, hosts: [String], urls: [String]) -> ProxyRule {
        ProxyRule(name: name, hosts: hosts, urls: urls)
    }

    @Test("地址解析：http / socks5 / 带账号密码")
    func endpointParsing() throws {
        let http = try #require(ProxyEndpoint(url: "http://127.0.0.1:1080"))
        #expect(http.scheme == .http)
        #expect(http.host == "127.0.0.1")
        #expect(http.port == 1080)
        #expect(http.userInfo == nil)

        let socks = try #require(ProxyEndpoint(url: "socks5://user:pass@10.0.0.9:1081"))
        #expect(socks.scheme == .socks)
        #expect(socks.username == "user")
        #expect(socks.password == "pass")
    }

    @Test("地址解析：缺端口 / 端口越界 / 协议不认识都丢弃")
    func endpointRejection() {
        #expect(ProxyEndpoint(url: "http://127.0.0.1") == nil)
        #expect(ProxyEndpoint(url: "http://127.0.0.1:0") == nil)
        #expect(ProxyEndpoint(url: "http://127.0.0.1:99999") == nil)
        #expect(ProxyEndpoint(url: "ftp://127.0.0.1:21") == nil)
        #expect(ProxyEndpoint(url: "127.0.0.1:1080") == nil)
    }

    @Test("非通配规则优先：即使通配规则排在前面也先命中具体规则")
    func specificRulesWin() {
        let resolver = ProxyRuleResolver(rules: [
            rule("wild", hosts: ["*"], urls: ["socks5://127.0.0.1:1081"]),
            rule("cdn", hosts: ["cdn.example.com"], urls: ["http://127.0.0.1:1080"]),
        ])
        let selection = resolver.selection(forHost: "cdn.example.com")
        #expect(selection.ruleName == "cdn")
        #expect(selection.endpoints.first?.scheme == .http)
    }

    @Test("同优先级保持配置顺序（上游 List.sort 稳定）")
    func stableOrder() {
        let resolver = ProxyRuleResolver(rules: [
            rule("first", hosts: ["example.com"], urls: ["http://127.0.0.1:1080"]),
            rule("second", hosts: ["example.com"], urls: ["http://127.0.0.1:1081"]),
        ])
        #expect(resolver.selection(forHost: "api.example.com").ruleName == "first")
    }

    @Test("规则命中但没有可用地址 → 直连")
    func hitWithoutEndpoint() {
        let resolver = ProxyRuleResolver(rules: [rule("broken", hosts: ["example.com"], urls: ["ftp://x:1"])])
        let selection = resolver.selection(forHost: "api.example.com")
        #expect(selection.isDirect)
        #expect(selection.ruleName.isEmpty)
    }

    @Test("没有规则命中 → 直连")
    func noMatch() {
        let resolver = ProxyRuleResolver(rules: [rule("cdn", hosts: ["cdn.example.com"], urls: ["http://127.0.0.1:1080"])])
        #expect(resolver.selection(forHost: "other.example.com").isDirect)
        #expect(resolver.isEmpty == false)
        #expect(ProxyRuleResolver().isEmpty)
    }

    @Test("本地地址永不走代理（本地服务必须能直连自己）")
    func localHostsBypass() {
        let resolver = ProxyRuleResolver(rules: [rule("all", hosts: ["*"], urls: ["socks5://127.0.0.1:1081"])])
        #expect(resolver.selection(forHost: "127.0.0.1").isDirect)
        #expect(resolver.selection(forHost: "localhost").isDirect)
        #expect(!resolver.selection(forHost: "example.com").isDirect)
        #expect(ProxyRuleResolver.isLocal(host: "::1"))
    }

    @Test("多地址按配置顺序返回，认证信息取第一条带 userInfo 的")
    func multipleEndpoints() {
        let resolver = ProxyRuleResolver(rules: [
            rule("multi", hosts: ["example.com"], urls: ["http://127.0.0.1:1080", "socks5://user:pass@127.0.0.1:1081"]),
        ])
        let selection = resolver.selection(forHost: "example.com")
        #expect(selection.endpoints.map(\.port) == [1080, 1081])
        #expect(selection.userInfo == "user:pass")
    }
}
