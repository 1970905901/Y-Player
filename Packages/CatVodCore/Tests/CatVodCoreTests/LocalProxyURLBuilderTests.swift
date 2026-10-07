import CatVodCore
import Foundation
import Testing

@Suite("本地代理地址与参数编解码")
struct LocalProxyURLBuilderTests {
    private let builder = LocalProxyURLBuilder(port: 9978)

    @Test("目标地址可原样还原（含查询串）")
    func urlRoundTrip() throws {
        let target = "https://cdn.example.com/live/index.m3u8?token=abc&sign=1"
        let url = try #require(builder.proxyURL(for: target, headers: ["Referer": "https://site.example.com/"]))
        #expect(url.path == "/proxy")

        let decoded = try #require(LocalProxyURLBuilder.decode(url: url))
        #expect(decoded.url == target)
        #expect(decoded.headers == ["Referer": "https://site.example.com/"])
    }

    @Test("header 值里的特殊字符与中文都能原样往返")
    func headerRoundTrip() throws {
        let headers = [
            "Cookie": "a=1; b=2",
            "User-Agent": "okhttp/4.12.0 (中文注释)",
            "X-Token": "a:b;c,d=e",
        ]
        let url = try #require(builder.proxyURL(for: "https://cdn.example.com/a.m3u8", headers: headers))
        let decoded = try #require(LocalProxyURLBuilder.decode(url: url))
        #expect(decoded.headers == headers)
    }

    @Test("没有 header 时不带 h 参数")
    func noHeaderParameter() throws {
        let url = try #require(builder.proxyURL(for: "https://cdn.example.com/a.m3u8"))
        #expect(!url.absoluteString.contains("h="))
    }

    @Test("缺 url 参数无法还原")
    func missingTarget() throws {
        let url = try #require(URL(string: "http://127.0.0.1:9978/proxy?h=abc"))
        #expect(LocalProxyURLBuilder.decode(url: url) == nil)
        #expect(LocalProxyURLBuilder.decode(url: builder.baseURL) == nil)
    }

    @Test("base64 非法时 header 表退化为空，而不是抛错")
    func invalidHeaderPayload() {
        #expect(LocalProxyURLBuilder.decodeHeaders("!!!not-base64!!!").isEmpty)
        #expect(LocalProxyURLBuilder.decodeHeaders(nil).isEmpty)
        #expect(LocalProxyURLBuilder.decodeHeaders("").isEmpty)
        // 合法 base64 但不是 JSON 对象。
        #expect(LocalProxyURLBuilder.decodeHeaders(Data("[1,2]".utf8).base64EncodedString()).isEmpty)
    }

    @Test("health 地址")
    func healthURL() throws {
        let url = try #require(builder.healthURL())
        #expect(url.absoluteString == "http://127.0.0.1:9978/health")
    }
}
