import CatVodCore
import FlyingFox
@testable import CatVodNet
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 端到端：真的起一个监听端口的本机服务，用 `URLSession` 打过去。
///
/// 为什么必须有它：M6 的价值全在「真的能取到东西」，而 handler 单测看不到
/// 端口绑定、`waitUntilListening`、keep-alive、状态行、`Content-Length` 这些真实链路问题。
/// CI 的 macOS runner 上跑得起来，是最接近真机的信号。
@Suite("本地 HTTP 服务：端到端转发")
struct LocalHTTPServerTests {
    /// 起服务 → 跑断言 → 无论成败都停服务。
    private func withLocalServer(
        upstream: any HTTPTransport,
        maximumBodyBytes: Int = 32 * 1024 * 1024,
        _ body: (UInt16) async throws -> Void
    ) async throws {
        let handler = LocalProxyHandler(
            upstream: LocalProxyUpstreamClient(transport: upstream, maximumBodyBytes: maximumBodyBytes)
        )
        let server = LocalHTTPServer(
            configuration: LocalHTTPServer.Configuration(portRange: 9978 ... 9998),
            handler: handler
        )
        let port = try await server.start()
        do {
            try await body(port)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw CatVodError.localServer(reason: "本地服务返回的不是 HTTP 响应")
        }
        return (data, http)
    }

    @Test("起服务 → /health 就绪 → /proxy 注入 header 取上游 → 回实体")
    func proxyRoundTrip() async throws {
        let headers = ["Referer": "https://site.example.com/", "User-Agent": "YPlayer/0.1"]
        let upstream = StubUpstreamTransport(body: Data("#EXTM3U\n".utf8))
        try await withLocalServer(upstream: upstream) { port in
            let builder = LocalProxyURLBuilder(port: port)
            let health = try #require(builder.healthURL())
            let (healthBody, healthResponse) = try await fetch(health)
            #expect(healthResponse.statusCode == 200)
            #expect(String(data: healthBody, encoding: .utf8) == "ok")

            let target = "https://cdn.example.com/live/index.m3u8?token=abc"
            let url = try #require(builder.proxyURL(for: target, headers: headers))
            let (data, response) = try await fetch(url)

            #expect(response.statusCode == 200)
            #expect(String(data: data, encoding: .utf8) == "#EXTM3U\n")
            // 上游响应：保留 Content-Type，剥掉 Content-Encoding（实体已解压），补上 CORS。
            #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            #expect(response.value(forHTTPHeaderField: "Content-Encoding") == nil)
            #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")

            let snapshot = await upstream.lastRequest()
            let forwarded = try #require(snapshot)
            #expect(forwarded.url.absoluteString == target)
            #expect(forwarded.headers["Referer"] == "https://site.example.com/")
            #expect(forwarded.headers["User-Agent"] == "YPlayer/0.1")
        }
    }

    @Test("Range 请求透传：上游 206 与 Content-Range 原样回给播放器")
    func rangeForwarding() async throws {
        let upstream = StubUpstreamTransport(
            status: 206,
            headers: ["Content-Type": "video/mp2t", "Content-Range": "bytes 0-99/1000", "Accept-Ranges": "bytes"],
            body: Data(repeating: 0x41, count: 100)
        )
        try await withLocalServer(upstream: upstream) { port in
            let url = try #require(LocalProxyURLBuilder(port: port).proxyURL(for: "https://cdn.example.com/a.ts"))
            var request = URLRequest(url: url)
            request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)

            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 0-99/1000")
            #expect(data.count == 100)

            let snapshot = await upstream.lastRequest()
            let forwarded = try #require(snapshot)
            #expect(forwarded.headers["Range"] == "bytes=0-99")
        }
    }

    @Test("缺 url → 400；未知路径 → 404；上游失败 → 502")
    func errorPaths() async throws {
        let failing = StubUpstreamTransport(
            failure: CatVodError.network(status: nil, url: "https://cdn.example.com/a.ts", reason: "上游不可达")
        )
        try await withLocalServer(upstream: failing) { port in
            let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
            let (_, bad) = try await fetch(base.appendingPathComponent("proxy"))
            #expect(bad.statusCode == 400)

            let (_, missing) = try await fetch(base.appendingPathComponent("nothing"))
            #expect(missing.statusCode == 404)

            let url = try #require(LocalProxyURLBuilder(port: port).proxyURL(for: "https://cdn.example.com/a.ts"))
            let (_, failed) = try await fetch(url)
            #expect(failed.statusCode == 502)
        }
    }

    @Test("端口搜索：首端口被占用后仍能起来；重复 start 幂等；stop 后状态复位")
    func portFallback() async throws {
        let upstream = StubUpstreamTransport()
        let handler = LocalProxyHandler(upstream: LocalProxyUpstreamClient(transport: upstream))
        let configuration = LocalHTTPServer.Configuration(portRange: 9978 ... 9998)
        let first = LocalHTTPServer(configuration: configuration, handler: handler)
        let second = LocalHTTPServer(configuration: configuration, handler: handler)

        let firstPort = try await first.start()
        let secondPort = try await second.start()
        #expect(secondPort != firstPort)

        let reported = await second.port
        #expect(reported == secondPort)
        let state = await second.state
        #expect(state == .running(port: secondPort))

        let again = try await second.start()
        #expect(again == secondPort)

        await second.stop()
        await first.stop()
        let firstState = await first.state
        let secondBase = await second.baseURL
        #expect(firstState == .stopped)
        #expect(secondBase == nil)
    }
}
