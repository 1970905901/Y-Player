import CatVodCore
import Testing

@Suite("本地代理的 header 转发策略")
struct ProxyForwardingPolicyTests {
    @Test("逐跳 header 与 Host 一律不透传")
    func hopByHopDropped() {
        let merged = ProxyForwardingPolicy.upstreamRequestHeaders(
            client: [
                "Connection": "keep-alive",
                "Host": "127.0.0.1:9978",
                "Transfer-Encoding": "chunked",
                "Range": "bytes=0-99",
                "User-Agent": "AVPlayer",
            ],
            injected: [:]
        )
        #expect(merged["Range"] == "bytes=0-99")
        #expect(merged["User-Agent"] == "AVPlayer")
        #expect(merged["Connection"] == nil)
        #expect(merged["Host"] == nil)
        #expect(merged["Transfer-Encoding"] == nil)
    }

    @Test("白名单外的请求 header 丢弃（不把本机 header 泄漏给源站）")
    func nonWhitelistedDropped() {
        let merged = ProxyForwardingPolicy.upstreamRequestHeaders(
            client: ["X-Custom": "1", "Accept-Language": "zh-CN", "Accept-Encoding": "gzip"],
            injected: [:]
        )
        #expect(merged["Accept-Language"] == "zh-CN")
        #expect(merged["X-Custom"] == nil)
        // Accept-Encoding 不在白名单内：由传输层（URLSession）自己协商编码。
        #expect(merged["Accept-Encoding"] == nil)
    }

    @Test("注入 header 覆盖客户端同名（大小写不敏感，只留一条）")
    func injectedOverridesClient() {
        let merged = ProxyForwardingPolicy.upstreamRequestHeaders(
            client: ["Referer": "https://player.example.com/"],
            injected: ["referer": "https://site.example.com/"]
        )
        #expect(merged.count == 1)
        #expect(merged["referer"] == "https://site.example.com/")
    }

    @Test("响应 header：保留实体与缓存相关，剥掉 Content-Encoding / Content-Length / 逐跳")
    func responseFiltering() {
        let headers = ProxyForwardingPolicy.clientResponseHeaders(upstream: [
            "Content-Type": "video/mp2t",
            "Content-Range": "bytes 0-99/1000",
            "Accept-Ranges": "bytes",
            "Content-Encoding": "gzip",
            "Content-Length": "100",
            "Transfer-Encoding": "chunked",
            "Set-Cookie": "a=1",
            "Access-Control-Allow-Origin": "https://site.example.com",
        ])
        #expect(headers["Content-Type"] == "video/mp2t")
        #expect(headers["Content-Range"] == "bytes 0-99/1000")
        #expect(headers["Accept-Ranges"] == "bytes")
        #expect(headers["Content-Encoding"] == nil)
        #expect(headers["Content-Length"] == nil)
        #expect(headers["Transfer-Encoding"] == nil)
        #expect(headers["Set-Cookie"] == nil)
        // 源站的 CORS 头不带 `*`，会被我们改写为 `*`（Web 嗅探要能读响应体）。
        #expect(headers["Access-Control-Allow-Origin"] == "*")
    }

    @Test("逐跳判定（大小写不敏感）")
    func hopByHopDetection() {
        #expect(ProxyForwardingPolicy.isHopByHop("Connection"))
        #expect(ProxyForwardingPolicy.isHopByHop("transfer-encoding"))
        #expect(!ProxyForwardingPolicy.isHopByHop("Range"))
        #expect(ProxyForwardingPolicy.isForwardableResponseHeader("CONTENT-TYPE"))
        #expect(!ProxyForwardingPolicy.isForwardableResponseHeader("Set-Cookie"))
    }
}
