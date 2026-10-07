import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 按 URL 前缀路由的假传输层：聚合解析的每个成员地址都不同，单一响应不够用。
private actor RouterTransport: HTTPTransport {
    private let routes: [String: HTTPResponse]
    private let delays: [String: Duration]
    private(set) var requestedURLs: [String] = []

    init(routes: [String: HTTPResponse], delays: [String: Duration] = [:]) {
        self.routes = routes
        self.delays = delays
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let text = request.url.absoluteString
        requestedURLs.append(text)
        for (prefix, delay) in delays where text.hasPrefix(prefix) {
            try await Task.sleep(for: delay)
        }
        for (prefix, response) in routes where text.hasPrefix(prefix) {
            return response
        }
        return HTTPResponse(status: 404, body: Data("no route".utf8))
    }
}

@Suite("type=4 聚合解析（JSON 侧竞速）：对齐上游 ParseJob.superParse")
struct AggregateParserTests {
    /// 合法地址（长度 > 40，满足上游 `checkResult`）。
    private let okBody = #"{"url":"https://cdn.example.com/real/stream.m3u8?token=abcdefgh"}"#

    private func jsonParser(_ name: String, url: String) -> ParserRule {
        ParserRule(name: name, type: ParserKind.json.rawValue, url: url)
    }

    private func plan(_ parsers: [ParserRule]) -> AggregateParsePlan {
        AggregateParsePlan(parsers: parsers, flag: "线路1")
    }

    private func jsonResponse(_ body: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(body.utf8))
    }

    @Test("谁先成功算谁：快的成员失败、慢的成员成功 → 返回慢的那个")
    func firstSuccessWins() async throws {
        let transport = RouterTransport(
            routes: [
                "https://slow.example.com": jsonResponse(okBody),
                "https://fast.example.com": HTTPResponse(status: 500, body: Data("boom".utf8)),
            ],
            delays: ["https://slow.example.com": .milliseconds(60)]
        )
        let members = [
            jsonParser("慢的", url: "https://slow.example.com/jx?url="),
            jsonParser("快的", url: "https://fast.example.com/jx?url="),
        ]
        let parsed = try await AggregateParser(transport: transport)
            .parse(plan(members), webURL: "https://cdn.example.com/a.m3u8")

        #expect(parsed.from == "慢的")
        #expect(parsed.url == "https://cdn.example.com/real/stream.m3u8?token=abcdefgh")
    }

    @Test("全部失败：把所有成员的原因带回错误里")
    func allFailed() async throws {
        let transport = RouterTransport(routes: [:])
        let members = [
            jsonParser("甲", url: "https://a.example.com/jx?url="),
            jsonParser("乙", url: "https://b.example.com/jx?url="),
        ]
        do {
            _ = try await AggregateParser(transport: transport)
                .parse(plan(members), webURL: "https://cdn.example.com/a.m3u8")
            Issue.record("所有成员都是 404，应当判为失败")
        } catch let error as CatVodError {
            guard case let .parseFailed(flag, reason) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(flag == "线路1")
            #expect(reason.contains("2 个解析器"))
            #expect(reason.contains("甲"))
            #expect(reason.contains("乙"))
        }
    }

    @Test("没有 type=1 成员时不发请求：明确说明需要 Web 嗅探")
    func noJSONMember() async throws {
        let transport = RouterTransport(routes: [:])
        let webOnly = [
            ParserRule(name: "Web", type: ParserKind.web.rawValue, url: "https://w.example.com/go?url="),
        ]
        do {
            _ = try await AggregateParser(transport: transport)
                .parse(plan(webOnly), webURL: "https://cdn.example.com/a.m3u8")
            Issue.record("只有 type=0 时 JSON 侧应当明确拒绝")
        } catch let error as CatVodError {
            #expect(error.errorDescription?.contains("Web 嗅探") == true)
        }
        let requested = await transport.requestedURLs
        #expect(requested.isEmpty)
    }

    @Test("成功成员的 header 来自响应（上游 getHeader）")
    func carriesResponseHeaders() async throws {
        let body = #"{"url":"https://cdn.example.com/real/stream.m3u8?token=abcdefgh","Referer":"https://site.example.com/"}"#
        let transport = RouterTransport(routes: ["https://only.example.com": jsonResponse(body)])
        let members = [jsonParser("唯一", url: "https://only.example.com/jx?url=")]
        let parsed = try await AggregateParser(transport: transport)
            .parse(plan(members), webURL: "https://cdn.example.com/a.m3u8", headers: ["User-Agent": "result-UA"])

        #expect(parsed.headers["Referer"] == "https://site.example.com/")
        #expect(parsed.from == "唯一")
    }
}
