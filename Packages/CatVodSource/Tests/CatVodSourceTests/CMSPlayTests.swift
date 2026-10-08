import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 记录请求的假传输层。
///
/// 这里要断言两件事：**请求形状**（`play` / `flag` / `extend`）与**「不该发请求时一颗都没发」**。
private actor PlayTransport: HTTPTransport {
    private let response: HTTPResponse
    private(set) var requests: [HTTPRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

/// `type=4` 站点的 play 接口（M06n）。
///
/// 依据是上游 `SiteApi.playerContent` 的 `site.getType() == 4` 分支（源码已取到
/// `Tools/out/upstream/SiteApi.java`）：请求 `play` + `flag`，响应用 `Result.fromJson` 解，
/// `flag` 缺了才回填；`header` 是「响应已有就不覆盖」（`setHeader(Map)` 的 `if (getHeader().isEmpty())`）。
@Suite("type=4 播放接口")
struct CMSPlayTests {
    private func site(type: Int = 4) -> Site {
        Site(key: "http4", name: "HTTP4", type: type, api: "https://api.example.com/vod")
    }

    private func transport(_ json: String) -> PlayTransport {
        PlayTransport(response: HTTPResponse(status: 200, body: Data(json.utf8)))
    }

    private func parameters(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test("请求形状：只带 `play` + `flag`，不带 `ac` / `ids`")
    func requestShape() async throws {
        let transport = transport(#"{"url":"https://cdn.example.com/ep1.m3u8","parse":0}"#)

        _ = try await CMSClient(transport: transport).play(site: site(), flag: "线路1", playID: "abc")

        let request = try #require(await transport.requests.first)
        let params = parameters(request)
        #expect(params["play"] == "abc")
        #expect(params["flag"] == "线路1")
        #expect(params["ac"] == nil)
        #expect(params["ids"] == nil)
    }

    @Test("`ext` 非空时顺带补 `extend`（上游 `call()` 的行为）")
    func extendsParam() async throws {
        let transport = transport(#"{"url":"https://cdn.example.com/ep1.m3u8"}"#)
        var site = site()
        site.ext = .string("https://a.example.com/ext.json")

        _ = try await CMSClient(transport: transport).play(site: site, flag: "线路1", playID: "abc")

        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString.contains("extend="))
    }

    @Test("直链响应：`parse=0` 拿到地址且不需要解析")
    func directPlayback() async throws {
        let transport = transport(#"{"url":"https://cdn.example.com/ep1.m3u8","parse":0}"#)

        let result = try await CMSClient(transport: transport).play(site: site(), flag: "线路1", playID: "abc")

        #expect(result.primaryPlaybackURL == "https://cdn.example.com/ep1.m3u8")
        #expect(!result.requiresParsing)
    }

    @Test("`parse=1` 与 `jx=1` 都要走解析链")
    func requiresParsing() async throws {
        let parseTransport = transport(#"{"url":"https://cdn.example.com/ep1.m3u8","parse":1}"#)
        let jxTransport = transport(#"{"url":"https://cdn.example.com/ep1.m3u8","jx":1}"#)

        let byParse = try await CMSClient(transport: parseTransport).play(site: site(), flag: "线路1", playID: "abc")
        let byJx = try await CMSClient(transport: jxTransport).play(site: site(), flag: "线路1", playID: "abc")

        #expect(byParse.requiresParsing)
        #expect(byJx.requiresParsing)
    }

    @Test("`parse` 缺失时按直链处理（上游 `getParse()` 缺省 0）")
    func missingParseDefaultsToZero() async throws {
        let transport = transport(#"{"url":"https://cdn.example.com/ep1.m3u8"}"#)

        let result = try await CMSClient(transport: transport).play(site: site(), flag: "线路1", playID: "abc")

        #expect(!result.requiresParsing)
    }

    @Test("`flag`：响应给了就用响应的，没给才回填请求的")
    func flagFallback() async throws {
        let silent = transport(#"{"url":"https://cdn.example.com/a.m3u8"}"#)
        let loud = transport(#"{"url":"https://cdn.example.com/a.m3u8","flag":"线路2"}"#)

        let filled = try await CMSClient(transport: silent).play(site: site(), flag: "线路1", playID: "abc")
        let kept = try await CMSClient(transport: loud).play(site: site(), flag: "线路1", playID: "abc")

        #expect(filled.flag == "线路1")
        #expect(kept.flag == "线路2")
    }

    @Test("`url` 三种形态都认（字符串 / 成对数组 / 对象 values+position）")
    func urlShapes() async throws {
        let single = transport(#"{"url":"https://cdn.example.com/a.m3u8"}"#)
        let paired = transport(#"{"url":["标清","https://cdn.example.com/sd.m3u8","高清","https://cdn.example.com/hd.m3u8"]}"#)
        let object = transport(#"{"url":{"values":[{"n":"高清","v":"https://cdn.example.com/hd.m3u8"}],"position":0}}"#)

        let a = try await CMSClient(transport: single).play(site: site(), flag: "线路1", playID: "abc")
        let b = try await CMSClient(transport: paired).play(site: site(), flag: "线路1", playID: "abc")
        let c = try await CMSClient(transport: object).play(site: site(), flag: "线路1", playID: "abc")

        #expect(a.primaryPlaybackURL == "https://cdn.example.com/a.m3u8")
        #expect(b.primaryPlaybackURL == "https://cdn.example.com/sd.m3u8")
        #expect(c.primaryPlaybackURL == "https://cdn.example.com/hd.m3u8")
        #expect(b.url.entries.count == 2)
    }

    @Test("响应带 header 时保留（上游只在空的时候才用站点 header）")
    func keepsResponseHeader() async throws {
        let transport = transport(#"{"url":"https://cdn.example.com/a.m3u8","header":{"User-Agent":"UA-1"}}"#)

        let result = try await CMSClient(transport: transport).play(site: site(), flag: "线路1", playID: "abc")

        #expect(result.header["User-Agent"] == "UA-1")
    }

    @Test("类型不对：抛 unsupported，并且**一颗请求都不发**")
    func rejectsNonType4() async throws {
        let transport = transport(#"{"url":"https://cdn.example.com/a.m3u8"}"#)

        do {
            _ = try await CMSClient(transport: transport).play(site: site(type: 1), flag: "线路1", playID: "abc")
            Issue.record("类型 1 不该走 play 接口")
        } catch let error as CatVodError {
            guard case let .unsupported(feature, _) = error else {
                Issue.record("应该抛 unsupported，实际是 \(error)")
                return
            }
            #expect(feature == "play")
        }

        let requests = await transport.requests
        #expect(requests.isEmpty)
    }

    @Test("非 2xx：抛 network，带状态码")
    func rejectsNonSuccess() async throws {
        let transport = PlayTransport(response: HTTPResponse(status: 500, body: Data("boom".utf8)))

        do {
            _ = try await CMSClient(transport: transport).play(site: site(), flag: "线路1", playID: "abc")
            Issue.record("500 不该成功")
        } catch let error as CatVodError {
            guard case let .network(status, _, _) = error else {
                Issue.record("应该抛 network，实际是 \(error)")
                return
            }
            #expect(status == 500)
        }
    }

    @Test("响应不是合法 JSON：抛 decoding，路径里带 `/play`")
    func rejectsMalformedBody() async throws {
        let transport = transport("<html>不是 JSON</html>")

        do {
            _ = try await CMSClient(transport: transport).play(site: site(), flag: "线路1", playID: "abc")
            Issue.record("畸形响应不该成功")
        } catch let error as CatVodError {
            guard case let .decoding(path, _) = error else {
                Issue.record("应该抛 decoding，实际是 \(error)")
                return
            }
            #expect(path.contains("/play"))
        }
    }
}
