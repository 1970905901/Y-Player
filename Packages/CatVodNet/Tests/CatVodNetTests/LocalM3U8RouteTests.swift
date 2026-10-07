import CatVodCore
@testable import CatVodNet
import FlyingFox
import Foundation
import Testing

@Suite("本地服务 /m3u8：清单改写（对齐上游 M3u8.java）")
struct LocalM3U8RouteTests {
    private let playlistURL = "https://cdn.example.com/live/index.m3u8"
    private let host = "127.0.0.1:9978"

    private func makeRequest(
        query: [FlyingFox.HTTPRequest.QueryItem],
        headers: [HTTPHeader: String] = [:],
        method: HTTPMethod = .GET
    ) -> FlyingFox.HTTPRequest {
        var allHeaders: [HTTPHeader: String] = [.host: host]
        for (key, value) in headers {
            allHeaders[key] = value
        }
        return FlyingFox.HTTPRequest(method: method, version: .http11, path: "/m3u8", query: query, headers: allHeaders)
    }

    private func makeHandler(
        headers: [String: String] = [:],
        body: Data,
        status: Int = 200
    ) -> LocalProxyHandler {
        let upstream = StubUpstreamTransport(status: status, headers: headers, body: body)
        return LocalProxyHandler(upstream: LocalProxyUpstreamClient(transport: upstream))
    }

    private func urlQuery(_ url: String, injected: String? = nil) -> [FlyingFox.HTTPRequest.QueryItem] {
        var items = [FlyingFox.HTTPRequest.QueryItem(name: "url", value: url)]
        if let injected {
            items.append(FlyingFox.HTTPRequest.QueryItem(name: "h", value: injected))
        }
        return items
    }

    @Test("路由：`/m3u8` 归到 m3u8（前缀命中）")
    func routing() {
        #expect(LocalProxyHandler.route(forPath: "/m3u8") == .m3u8)
        #expect(LocalProxyHandler.route(forPath: "/m3u8/child") == .m3u8)
        #expect(LocalProxyHandler.route(forPath: "/proxy") == .proxy)
    }

    @Test("清单：分片与 `URI=\"…\"` 改成走本机 /m3u8；长度重算、编码头去掉、不许缓存")
    func rewritesPlaylist() async throws {
        let playlist = "#EXTM3U\n#EXTINF:5.0,\nseg.ts\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n"
        let handler = makeHandler(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(playlist.utf8))
        let response = try await handler.handleRequest(makeRequest(query: urlQuery(playlistURL)))

        #expect(response.statusCode == .ok)
        #expect(response.headers[HTTPHeader("Content-Type")] == "application/vnd.apple.mpegurl; charset=utf-8")
        let body = try await response.bodyData
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("http://127.0.0.1:9978/m3u8?url=https%3A%2F%2Fcdn.example.com%2Flive%2Fseg.ts"))
        #expect(text.contains("URI=\"http://127.0.0.1:9978/m3u8?url=https%3A%2F%2Fcdn.example.com%2Flive%2Fkey.bin\""))
        #expect(response.headers[HTTPHeader("Content-Length")] == String(body.count))
        #expect(response.headers[HTTPHeader("Content-Encoding")] == nil)
        #expect(response.headers[HTTPHeader("Cache-Control")]?.contains("no-store") == true)
    }

    @Test("分片：不是清单就原样转发（状态码与正文都不动）")
    func passesThroughSegment() async throws {
        let handler = makeHandler(headers: ["Content-Type": "video/mp2t"], body: Data(repeating: 0x47, count: 20))
        let response = try await handler.handleRequest(makeRequest(query: urlQuery("https://cdn.example.com/live/seg.ts")))

        #expect(response.statusCode == .ok)
        let body = try await response.bodyData
        #expect(body.count == 20)
    }

    @Test("注入 header 逐跳带下去：子清单地址里带同一个 h（否则分片会 403）")
    func carriesInjectedHeaders() async throws {
        let playlist = "#EXTM3U\n#EXTINF:5.0,\nhttps://cdn.example.com/live/seg.ts\n"
        let injected = LocalProxyURLBuilder.encodeHeaders(["Referer": "https://site.example.com/"])
        let handler = makeHandler(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(playlist.utf8))
        let response = try await handler.handleRequest(makeRequest(query: urlQuery(playlistURL, injected: injected)))

        let body = try await response.bodyData
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("&h=" + injected))
    }

    @Test("上游错误原样透传：不改写、不掩盖状态码")
    func passthroughUpstreamError() async throws {
        let handler = makeHandler(
            headers: ["Content-Type": "application/vnd.apple.mpegurl"],
            body: Data("<html>403</html>".utf8),
            status: 403
        )
        let response = try await handler.handleRequest(makeRequest(query: urlQuery(playlistURL)))
        #expect(response.statusCode == .forbidden)
        let body = try await response.bodyData
        #expect(String(data: body, encoding: .utf8) == "<html>403</html>")
    }

    @Test("缺 url → 400（与 /proxy 同一套解析）")
    func badRequest() async throws {
        let handler = makeHandler(headers: [:], body: Data())
        let response = try await handler.handleRequest(makeRequest(query: []))
        #expect(response.statusCode == .badRequest)
    }
}
