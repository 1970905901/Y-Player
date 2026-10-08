@testable import CatVodCore
@testable import CatVodNet
import Foundation
import Testing

/// 代理接线（M06j）：端点 → 会话字典、代理确实被用上、认证只答代理那一侧。
///
/// 一条刻意的取舍：这里**不去连真的代理**（CI 上没有），而是把代理指向一个必定连不上的本机端口 ——
/// 只要请求因此失败，就说明「这次请求确实走了代理」；直连的话它会去连真站点（CI 上未必有网）。
@Suite("代理接线（端点 / 会话池 / 认证）")
struct ProxySupportTests {
    private func endpoint(_ text: String) throws -> ProxyEndpoint {
        try #require(ProxyEndpoint(url: text))
    }

    @Test("HTTP 代理：`HTTP` 与 `HTTPS` 两套键都要给（只给 HTTPS 会漏掉明文请求）")
    func httpDictionary() throws {
        let dictionary = try endpoint("http://127.0.0.1:8888").connectionProxyDictionary

        #expect(dictionary["HTTPEnable"] as? Int == 1)
        #expect(dictionary["HTTPProxy"] as? String == "127.0.0.1")
        #expect(dictionary["HTTPPort"] as? Int == 8888)
        #expect(dictionary["HTTPSEnable"] as? Int == 1)
        #expect(dictionary["HTTPSProxy"] as? String == "127.0.0.1")
        #expect(dictionary["HTTPSPort"] as? Int == 8888)
        #expect(dictionary["SOCKSEnable"] == nil)
    }

    @Test("SOCKS 代理：只有一套键，而且不带认证（系统不支持）")
    func socksDictionary() throws {
        let value = try endpoint("socks5://user:pass@127.0.0.1:1080")
        let dictionary = value.connectionProxyDictionary

        #expect(dictionary["SOCKSEnable"] as? Int == 1)
        #expect(dictionary["SOCKSProxy"] as? String == "127.0.0.1")
        #expect(dictionary["SOCKSPort"] as? Int == 1080)
        #expect(dictionary["HTTPProxy"] == nil)
        // 凭据解析出来了，但字典里没有它的位置 —— 这是平台限制，不是漏了
        #expect(value.username == "user")
        #expect(value.password == "pass")
    }

    @Test("配了代理：请求确实走代理（指向连不上的端口，失败即证明走的是代理）")
    func proxyIsUsed() async throws {
        let dead = try endpoint("http://127.0.0.1:9")
        var configuration = URLSessionTransport.Configuration(defaultTimeout: 5)
        configuration.proxyResolver = { _ in dead }
        let transport = URLSessionTransport(configuration: configuration)
        let url = try #require(URL(string: "https://example.com/"))

        await #expect(throws: CatVodError.self) {
            _ = try await transport.send(HTTPRequest(url: url))
        }
    }

    @Test("解析器返回 nil 时走直连，且解析器确实被问到过")
    func directWhenNoEndpoint() async throws {
        let asked = LockedFlag()
        var configuration = URLSessionTransport.Configuration(defaultTimeout: 2)
        configuration.proxyResolver = { _ in
            asked.mark()
            return nil
        }
        let transport = URLSessionTransport(configuration: configuration)
        // 直连一个本机没人听的端口：连不上是预期内的（我们要断言的是「问过解析器」）
        let url = try #require(URL(string: "https://127.0.0.1:9/"))
        _ = try? await transport.send(HTTPRequest(url: url))

        #expect(asked.value)
    }

    @Test("认证：只答代理的挑战，站点认证一律交回系统")
    func authOnlyForProxy() {
        #expect(ProxyAuthDelegate.shouldAnswer(proxyType: "http", hasCredential: true))
        #expect(!ProxyAuthDelegate.shouldAnswer(proxyType: nil, hasCredential: true))
        #expect(!ProxyAuthDelegate.shouldAnswer(proxyType: "http", hasCredential: false))
        #expect(!ProxyAuthDelegate.shouldAnswer(proxyType: nil, hasCredential: false))
    }
}

/// 极简线程安全的布尔标记（测试里用来断言「闭包被问过」）。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func mark() {
        lock.lock()
        flagged = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }
}
