import CatVodCore
@testable import CatVodNet
import FlyingFox
import Foundation
import Testing

@Suite("本地代理：请求解析与路由")
struct LocalProxyRouteTests {
    private let target = "https://cdn.example.com/live/index.m3u8"

    private func makeRequest(
        path: String = "/proxy",
        query: [FlyingFox.HTTPRequest.QueryItem] = [],
        headers: [HTTPHeader: String] = [:],
        method: HTTPMethod = .GET,
        body: Data = Data()
    ) -> FlyingFox.HTTPRequest {
        FlyingFox.HTTPRequest(method: method, version: .http11, path: path, query: query, headers: headers, body: body)
    }

    private func makeHandler(upstream: any HTTPTransport) -> LocalProxyHandler {
        LocalProxyHandler(upstream: LocalProxyUpstreamClient(transport: upstream))
    }

    /// `/proxy?url=…&h=…` 的查询项（`h` 只在有 header 时带上）。
    private func query(_ url: String, headers: [String: String] = [:]) -> [FlyingFox.HTTPRequest.QueryItem] {
        var items = [FlyingFox.HTTPRequest.QueryItem(name: "url", value: url)]
        if !headers.isEmpty {
            let encoded = LocalProxyURLBuilder.encodeHeaders(headers)
            items.append(FlyingFox.HTTPRequest.QueryItem(name: "h", value: encoded))
        }
        return items
    }

    @Test("query 形态：url + h 还原成目标与注入 header")
    func decodeFromQuery() async throws {
        let injected = ["Referer": "https://site.example.com/"]
        let request = makeRequest(query: [
            FlyingFox.HTTPRequest.QueryItem(name: "url", value: target),
            FlyingFox.HTTPRequest.QueryItem(name: "h", value: LocalProxyURLBuilder.encodeHeaders(injected)),
        ])
        let decoded = try #require(try await LocalProxyRequestDecoder.decode(request))
        #expect(decoded.url.absoluteString == target)
        #expect(decoded.headers["Referer"] == "https://site.example.com/")
        #expect(decoded.method == .get)
    }

    @Test("POST 形态：请求体 JSON 还原（含上游方法）")
    func decodeFromBody() async throws {
        let json = #"{"url":"https://cdn.example.com/a.ts","headers":{"User-Agent":"UA"},"method":"POST"}"#
        let request = makeRequest(method: .POST, body: Data(json.utf8))
        let decoded = try #require(try await LocalProxyRequestDecoder.decode(request))
        #expect(decoded.url.absoluteString == "https://cdn.example.com/a.ts")
        #expect(decoded.headers["User-Agent"] == "UA")
        #expect(decoded.method == .post)
    }

    @Test("缺 url / 非法请求体都返回 nil（由处理器给出 400）")
    func decodeFailures() async throws {
        let missing = try await LocalProxyRequestDecoder.decode(makeRequest())
        let emptyBody = try await LocalProxyRequestDecoder.decode(makeRequest(method: .POST))
        let broken = makeRequest(method: .POST, body: Data("{not json".utf8))
        let brokenResult = try await LocalProxyRequestDecoder.decode(broken)
        #expect(missing == nil)
        #expect(emptyBody == nil)
        #expect(brokenResult == nil)
    }

    @Test("客户端 header：只透传白名单项，注入项覆盖同名（含大小写不同）")
    func clientHeaderForwarding() async throws {
        let request = makeRequest(
            query: query(target, headers: ["referer": "https://site/"]),
            headers: [
                .range: "bytes=0-99",
                .host: "127.0.0.1:9978",
                .connection: "keep-alive",
                HTTPHeader("X-Player"): "internal",
                HTTPHeader("Referer"): "https://player/",
            ]
        )
        let decoded = try #require(try await LocalProxyRequestDecoder.decode(request))
        #expect(decoded.headers["Range"] == "bytes=0-99")
        #expect(decoded.headers["referer"] == "https://site/")
        #expect(decoded.headers["Host"] == nil)
        #expect(decoded.headers["Connection"] == nil)
        #expect(decoded.headers["X-Player"] == nil)
        // 客户端与注入项的 `Referer` 只留一条。
        #expect(decoded.headers.count == 2)
    }

    @Test("路由：按前缀分流，未识别路径不处理")
    func routes() {
        #expect(LocalProxyHandler.route(forPath: "/proxy") == .proxy)
        #expect(LocalProxyHandler.route(forPath: "/proxy/anything") == .proxy)
        #expect(LocalProxyHandler.route(forPath: "/health") == .health)
        #expect(LocalProxyHandler.route(forPath: "/") == .root)
        #expect(LocalProxyHandler.route(forPath: "/spider/cat/home") == nil)
    }

    @Test("/health 返回 ok，根路径返回服务标识")
    func healthAndRoot() async throws {
        let handler = makeHandler(upstream: StubUpstreamTransport())
        let health = try await handler.handleRequest(makeRequest(path: "/health"))
        #expect(health.statusCode == .ok)
        let healthBody = try await health.bodyData
        #expect(String(data: healthBody, encoding: .utf8) == "ok")

        let root = try await handler.handleRequest(makeRequest(path: "/"))
        #expect(root.statusCode == .ok)
    }

    @Test("未识别路径抛 HTTPUnhandledError（FlyingFox 会转成 404）")
    func unknownRoute() async throws {
        let handler = makeHandler(upstream: StubUpstreamTransport())
        do {
            _ = try await handler.handleRequest(makeRequest(path: "/spider/cat/home"))
            Issue.record("未知路径应当抛 HTTPUnhandledError")
        } catch is HTTPUnhandledError {
            // 预期
        }
    }

    @Test("缺少 url 参数 → 400 + JSON 原因")
    func badRequest() async throws {
        let handler = makeHandler(upstream: StubUpstreamTransport())
        let response = try await handler.handleRequest(makeRequest())
        #expect(response.statusCode == .badRequest)
        let body = try await response.bodyData
        #expect(String(data: body, encoding: .utf8)?.contains("url") == true)
    }

    @Test("OPTIONS 预检直接返回 204（Web 嗅探要跨域）")
    func preflight() async throws {
        let handler = makeHandler(upstream: StubUpstreamTransport())
        let response = try await handler.handleRequest(makeRequest(method: .OPTIONS))
        #expect(response.statusCode == .noContent)
        #expect(response.headers[HTTPHeader("Access-Control-Allow-Origin")] == "*")
    }

    @Test("HEAD：仍然取上游，但不带响应体")
    func headRequest() async throws {
        let upstream = StubUpstreamTransport(body: Data(repeating: 0x41, count: 512))
        let handler = makeHandler(upstream: upstream)
        let response = try await handler.handleRequest(makeRequest(query: query(target), method: .HEAD))

        #expect(response.statusCode == .ok)
        let body = try await response.bodyData
        #expect(body.isEmpty)
        let count = await upstream.requestCount
        #expect(count == 1)
    }

    @Test("上游失败 → 502 + 可读原因；上游状态码原样透传（含 206 与 Content-Range）")
    func upstreamResults() async throws {
        let failing = StubUpstreamTransport(
            failure: CatVodError.network(status: nil, url: target, reason: "上游不可用")
        )
        let failed = try await makeHandler(upstream: failing).handleRequest(makeRequest(query: query(target)))
        #expect(failed.statusCode == .badGateway)
        let reason = try await failed.bodyData
        #expect(String(data: reason, encoding: .utf8)?.contains("上游不可用") == true)

        let ranged = StubUpstreamTransport(
            status: 206,
            headers: ["Content-Type": "video/mp2t", "Content-Range": "bytes 0-99/1000"],
            body: Data(repeating: 0x42, count: 100)
        )
        let partial = try await makeHandler(upstream: ranged).handleRequest(makeRequest(query: query(target)))
        #expect(partial.statusCode == .partialContent)
        #expect(partial.headers[HTTPHeader("Content-Range")] == "bytes 0-99/1000")
    }

    @Test("落盘转发：传输层带落盘能力时，超过缓冲上限的响应照常回（M06b 流式转发）")
    func downloadingTransportBypassesBufferLimit() async throws {
        let payload = Data(repeating: 0x44, count: 4096)
        let upstream = StubDownloadingTransport(body: payload)
        // 上限故意压到 1KB：缓冲那条会 502，落盘这条必须照常回。
        let handler = LocalProxyHandler(
            upstream: LocalProxyUpstreamClient(transport: upstream, maximumBodyBytes: 1024)
        )
        let response = try await handler.handleRequest(makeRequest(query: query(target)))
        #expect(response.statusCode == .ok)
        let body = try await response.bodyData
        #expect(body.count == 4096)
        let count = await upstream.requestCount
        #expect(count == 1)
    }

    @Test("落盘文件清扫：超过宽限期的清掉、新的留着（M06b）")
    func tempFileSweep() throws {
        let fresh = try LocalProxyTempFiles.makeFileURL()
        try Data([1, 2, 3]).write(to: fresh)
        defer { try? FileManager.default.removeItem(at: fresh) }
        let old = try LocalProxyTempFiles.makeFileURL()
        try Data([4, 5, 6]).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-LocalProxyTempFiles.maximumAge - 60)],
            ofItemAtPath: old.path
        )
        LocalProxyTempFiles.sweep()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("响应体超过上限 → 502，而不是静默截断")
    func bodyLimit() async throws {
        let upstream = StubUpstreamTransport(body: Data(repeating: 0x43, count: 4096))
        let handler = LocalProxyHandler(
            upstream: LocalProxyUpstreamClient(transport: upstream, maximumBodyBytes: 1024)
        )
        let response = try await handler.handleRequest(makeRequest(query: query(target)))
        #expect(response.statusCode == .badGateway)
        let body = try await response.bodyData
        #expect(String(data: body, encoding: .utf8)?.contains("上限") == true)
    }
}

/// 落盘缓冲与清扫（M06p）：宽限期 + 配额的**纯策略**单测，加上缓冲的生命周期。
///
/// 为什么把策略抽出来单测：清扫动的是共享的临时目录，集成测试里没法安全地造「超配额」场面
/// （并行跑的其他用例也有文件在目录里）—— 策略是纯函数，输入输出直接钉死。
@Suite("落盘缓冲与清扫：宽限期 + 配额（M06p）")
struct LocalProxyStorageTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ name: String, size: Int64, age: TimeInterval, inUse: Bool = false) -> LocalProxySweepEntry {
        LocalProxySweepEntry(
            url: URL(fileURLWithPath: "/tmp/YPlayerProxy/\(name)"),
            size: size,
            modified: base.addingTimeInterval(-age),
            inUse: inUse
        )
    }

    @Test("宽限期：老的清、新的留（与 M06b 同口径）")
    func agedOnly() {
        let entries = [
            entry("old-a.tmp", size: 10, age: 20 * 60),
            entry("old-b.tmp", size: 20, age: 16 * 60),
            entry("fresh.tmp", size: 30, age: 60),
        ]
        let doomed = LocalProxyTempFiles.plan(entries: entries, now: base, quota: 1000)
        #expect(doomed == [entries[0].url, entries[1].url])
    }

    @Test("配额：超了就按「最旧先清」，清到线内就停")
    func quotaOldestFirst() {
        let entries = [
            entry("newest.tmp", size: 40, age: 10),
            entry("oldest.tmp", size: 40, age: 300),
            entry("middle.tmp", size: 40, age: 200),
        ]
        // 总 120、配额 80：只清最旧的一个就回到线内
        let loose = LocalProxyTempFiles.plan(entries: entries, now: base, quota: 80)
        #expect(loose == [entries[1].url])
        // 配额压到 40：还得再清一个（第二旧）
        let tighter = LocalProxyTempFiles.plan(entries: entries, now: base, quota: 40)
        #expect(tighter == [entries[1].url, entries[2].url])
    }

    @Test("在用的永不进结果：单个大文件自己超过配额也照发；它照样算进总量")
    func inUseIsNeverEvicted() {
        let entries = [
            entry("playing.tmp", size: 500, age: 300, inUse: true),
            entry("junk.tmp", size: 500, age: 100),
        ]
        let doomed = LocalProxyTempFiles.plan(entries: entries, now: base, quota: 0)
        #expect(doomed == [entries[1].url])
    }

    @Test("缓冲生命周期：建出来就登记在册、文件真在；释放即注销 + 删文件（M06p 的「发完即删」）")
    func bufferReleasesFileOnDeinit() throws {
        let url = try LocalProxyTempFiles.makeFileURL()
        var buffer: LocalProxyFileBuffer? = try LocalProxyFileBuffer(fileURL: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(LocalProxyTempFiles.inUseCount >= 1)
        buffer = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("上游提前收尾：读侧抛「对不上」，不把短的实体当正常结束（M06p）")
    func truncatedWriteThrows() async throws {
        let url = try LocalProxyTempFiles.makeFileURL()
        let buffer = try LocalProxyFileBuffer(fileURL: url)
        let stream = HTTPStream(
            status: 200,
            headers: ["Content-Length": "100"],
            chunks: AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data("short".utf8))
                continuation.finish()
            }
        )
        buffer.attach(stream)
        var received = Data()
        var caught: (any Error)?
        do {
            for try await chunk in buffer.makeBody() {
                received.append(chunk)
            }
        } catch {
            caught = error
        }
        #expect(received == Data("short".utf8))
        #expect(caught is LocalProxyFileBuffer.BufferError)
    }
}
