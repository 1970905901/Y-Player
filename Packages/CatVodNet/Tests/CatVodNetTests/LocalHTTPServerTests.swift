import CatVodCore
@testable import CatVodNet
import FlyingFox
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

    @Test("流式取回：URLSessionTransport.stream 的块拼起来就是整份响应（M25P2）")
    func streamingTransportReadsBody() async throws {
        // 200KB：跨过实现里 64KB 攒块的边界，块数不止一块
        let blob = Data(repeating: 0x41, count: 200_000)
        let upstream = StubUpstreamTransport(body: blob)
        try await withLocalServer(upstream: upstream) { port in
            let target = "https://cdn.example.com/movie.mp4"
            let url = try #require(LocalProxyURLBuilder(port: port).proxyURL(for: target))
            let transport = URLSessionTransport()

            let stream = try await transport.stream(HTTPRequest(url: url))
            #expect(stream.status == 200)
            var received = Data()
            for try await chunk in stream.chunks {
                received.append(chunk)
            }
            #expect(received == blob)
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

    /// 轮询等条件成立（超时即失败）：流式断言要等「客户端收到字节」，别拿 sleep 赌。
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test("边下边发（M06p）：上游还没写完，客户端就已经拿到第一块")
    func streamingServesBeforeUpstreamFinishes() async throws {
        let gate = AsyncGate()
        let upstream = StubStreamingTransport(
            pieces: [Data("first-".utf8), Data("second".utf8)],
            gate: gate
        )
        try await withLocalServer(upstream: upstream) { port in
            let url = try #require(LocalProxyURLBuilder(port: port).proxyURL(for: "https://cdn.example.com/movie.mp4"))
            let collector = StreamingBodyCollector()
            let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
            let task = session.dataTask(with: URLRequest(url: url))
            defer { task.cancel() }
            task.resume()

            // 上游正卡在闸门里：这会儿客户端能拿到第一块，就说明服务端没在等「整份下完」
            let early = await waitUntil { collector.body.count >= 6 }
            #expect(early)
            #expect(collector.body == Data("first-".utf8))
            #expect(!collector.didFinish)

            gate.open()
            let finished = await waitUntil { collector.didFinish }
            #expect(finished)
            #expect(collector.body == Data("first-second".utf8))
            #expect(collector.statusCode == 200)
        }
    }

    @Test("边下边发：上游给了 Content-Length 就按它发（不知道长度时才走 chunked）")
    func streamingKeepsContentLength() async throws {
        let payload = Data(repeating: 0x41, count: 8192)
        let upstream = StubStreamingTransport(
            headers: ["Content-Type": "video/mp4", "Content-Length": String(payload.count)],
            pieces: [payload.prefix(4096), payload.suffix(4096)]
        )
        try await withLocalServer(upstream: upstream) { port in
            let url = try #require(LocalProxyURLBuilder(port: port).proxyURL(for: "https://cdn.example.com/movie.mp4"))
            let (data, response) = try await fetch(url)
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Content-Length") == String(payload.count))
            #expect(data == payload)
        }
    }

    @Test("边下边发：上游非 2xx 走缓冲那条 —— 状态码与错误体原样回")
    func streamingErrorStatusStaysBuffered() async throws {
        let upstream = StubStreamingTransport(
            status: 404,
            headers: [:],
            pieces: [Data("not-found".utf8)]
        )
        try await withLocalServer(upstream: upstream) { port in
            let url = try #require(LocalProxyURLBuilder(port: port).proxyURL(for: "https://cdn.example.com/movie.mp4"))
            let (data, response) = try await fetch(url)
            #expect(response.statusCode == 404)
            #expect(String(data: data, encoding: .utf8) == "not-found")
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

/// 流式收体：`URLSessionDataTask` + 委托把收到的字节与状态记下来，测试轮询读
/// （`URLSession.bytes` 的迭代器没法在断言里限时中断，这个盒子更顺手）。
private final class StreamingBodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received = Data()
    private var response: HTTPURLResponse?
    private var finished = false

    var body: Data {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var statusCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return response?.statusCode
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        received.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        _ = error
        lock.lock()
        finished = true
        lock.unlock()
    }
}
