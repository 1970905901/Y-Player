import CatVodCore
import Foundation
import Testing

@testable import CatVodNet

@Suite("URLSession 传输：配置归一化")
struct URLSessionTransportTests {
    private func makeTransport(_ configuration: URLSessionTransport.Configuration) -> URLSessionTransport {
        URLSessionTransport(configuration: configuration)
    }

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    @Test("默认 header 与请求 header 合并，请求优先")
    func headerMerge() throws {
        let transport = makeTransport(
            URLSessionTransport.Configuration(defaultHeaders: ["User-Agent": "Default", "Accept": "*/*"])
        )
        let request = HTTPRequest(url: try url("https://api.example.com/vod"), headers: ["User-Agent": "Custom"])
        let prepared = try transport.prepare(request)

        #expect(prepared.value(forHTTPHeaderField: "User-Agent") == "Custom")
        #expect(prepared.value(forHTTPHeaderField: "Accept") == "*/*")
    }

    @Test("按 host 注入 header（headers 规则）")
    func hostHeaderInjection() throws {
        let transport = makeTransport(
            URLSessionTransport.Configuration(hostHeaders: ["example.com": ["Referer": "https://example.com/"]])
        )
        let injected = try transport.prepare(HTTPRequest(url: try url("https://api.example.com/vod")))
        #expect(injected.value(forHTTPHeaderField: "Referer") == "https://example.com/")

        let untouched = try transport.prepare(HTTPRequest(url: try url("https://other.com/vod")))
        #expect(untouched.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test("广告域名拦截：精确、后缀与通配")
    func adBlocking() throws {
        let transport = makeTransport(
            URLSessionTransport.Configuration(blockedHosts: ["ad.example.com", "*.tracker.net"])
        )
        #expect(transport.isBlocked(host: "ad.example.com"))
        #expect(transport.isBlocked(host: "sub.tracker.net"))
        #expect(!transport.isBlocked(host: "example.com"))

        #expect(throws: CatVodError.self) {
            _ = try transport.prepare(HTTPRequest(url: try url("https://ad.example.com/banner.js")))
        }
    }

    @Test("超时：请求级优先，否则用默认值")
    func timeoutResolution() throws {
        let transport = makeTransport(URLSessionTransport.Configuration(defaultTimeout: 9))
        let withDefault = try transport.prepare(HTTPRequest(url: try url("https://api.example.com/vod")))
        #expect(withDefault.timeoutInterval == 9)

        let withOverride = try transport.prepare(
            HTTPRequest(url: try url("https://api.example.com/vod"), timeout: 20)
        )
        #expect(withOverride.timeoutInterval == 20)
    }

    @Test("方法、请求体与 URL 原样透传")
    func methodAndBody() throws {
        let transport = makeTransport(.default)
        let request = HTTPRequest.json(url: try url("http://127.0.0.1:9988/spider/cat/home"), body: Data("{}".utf8))
        let prepared = try transport.prepare(request)

        #expect(prepared.httpMethod == "POST")
        #expect(prepared.httpBody == Data("{}".utf8))
        #expect(prepared.url?.absoluteString == "http://127.0.0.1:9988/spider/cat/home")
        #expect(prepared.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    }

    @Test("从配置模型构造：headers 规则与 ads 生效")
    func configurationFromConfig() throws {
        var config = SourceConfig()
        config.ads = ["ad.example.com"]
        config.headers = [HeaderRule(host: "example.com", header: ["Referer": "https://example.com/"])]

        let transport = URLSessionTransport(configuration: URLSessionTransport.Configuration(config: config))
        let prepared = try transport.prepare(HTTPRequest(url: try url("https://api.example.com/vod")))
        #expect(prepared.value(forHTTPHeaderField: "Referer") == "https://example.com/")
        // isBlocked 为 nonisolated，无需 await
        #expect(transport.isBlocked(host: "ad.example.com"))
    }
}
