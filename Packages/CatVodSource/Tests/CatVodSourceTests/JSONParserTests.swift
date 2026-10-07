import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 记录**完整请求**（URL/header/超时）的假传输层：既有 `StubTransport` 只记 URL，断言 header 不够用。
actor ParseRequestRecorder: HTTPTransport {
    private let response: HTTPResponse
    private(set) var requests: [HTTPRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }

    func firstRequest() -> HTTPRequest? {
        requests.first
    }
}

@Suite("type=1 JSON 解析器（对齐上游 ParseJob.jsonParse）")
struct JSONParserTests {
    private let parserURL = "https://p.example.com/jx?url="
    private let webURL = "https://cdn.example.com/a.m3u8"
    private let okBody = #"{"url":"https://cdn.example.com/real/stream.m3u8?token=abcdefghijklmnop"}"#

    private func makeJob(
        name: String = "解析A",
        type: Int = ParserKind.json.rawValue,
        header: [String: String] = [:],
        timeout: TimeInterval = 15
    ) -> ParseJob {
        ParseJob(
            parser: ParserRule(name: name, type: type, url: parserURL, ext: ParserExt(header: header)),
            webURL: webURL,
            flag: "线路1",
            headers: ["User-Agent": "result-UA"],
            timeout: timeout,
            origin: .jsonPrefix
        )
    }

    private func jsonResponse(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(body.utf8))
    }

    @Test("正常：取 url、来源名、响应没有 header 时回落解析器/结果 header")
    func success() async throws {
        let recorder = ParseRequestRecorder(response: jsonResponse(okBody))
        let parsed = try await JSONParser(transport: recorder).parse(makeJob())

        #expect(parsed.url == "https://cdn.example.com/real/stream.m3u8?token=abcdefghijklmnop")
        #expect(parsed.from == "解析A")
        #expect(parsed.headers["User-Agent"] == "result-UA")

        let request = await recorder.firstRequest()
        #expect(request?.url.absoluteString == parserURL + webURL)
        #expect(request?.method == .get)
        #expect(request?.timeout == 15)
        #expect(request?.headers["User-Agent"] == "result-UA")
    }

    @Test("url 为空 → 回退 data.url")
    func dataURLFallback() async throws {
        let body = #"{"url":"","data":{"url":"https://cdn.example.com/real/stream.m3u8?token=abcdefghij"}}"#
        let recorder = ParseRequestRecorder(response: jsonResponse(body))
        let parsed = try await JSONParser(transport: recorder).parse(makeJob())
        #expect(parsed.url == "https://cdn.example.com/real/stream.m3u8?token=abcdefghij")
    }

    @Test("地址过短（≤ 40）→ 按协议判失败")
    func tooShort() async {
        await expectParseFailure(#"{"url":"https://a.com/b.m3u8"}"#)
    }

    @Test("地址为空 → parseFailed")
    func emptyURL() async {
        await expectParseFailure(#"{"code":0,"msg":"没地址"}"#)
    }

    @Test("非 2xx → network（带上状态码）")
    func nonSuccessStatus() async {
        let recorder = ParseRequestRecorder(response: jsonResponse("bad gateway", status: 502))
        do {
            _ = try await JSONParser(transport: recorder).parse(makeJob())
            Issue.record("502 应当被拒绝")
        } catch let error as CatVodError {
            guard case let .network(status, _, _) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(status == 502)
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test("响应不是合法 JSON → decoding")
    func invalidJSON() async {
        let recorder = ParseRequestRecorder(response: jsonResponse("<html>502</html>"))
        do {
            _ = try await JSONParser(transport: recorder).parse(makeJob())
            Issue.record("HTML 应当被拒绝")
        } catch let error as CatVodError {
            guard case .decoding = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test("解析器自带 ext.header 优先于结果 header（请求也用它）")
    func parserHeaderWins() async throws {
        let recorder = ParseRequestRecorder(response: jsonResponse(okBody))
        _ = try await JSONParser(transport: recorder)
            .parse(makeJob(header: ["Referer": "https://p.example.com/"], timeout: 8))

        let request = await recorder.firstRequest()
        #expect(request?.headers["Referer"] == "https://p.example.com/")
        #expect(request?.headers["User-Agent"] == nil)
        #expect(request?.timeout == 8)
    }

    @Test("响应里有 Referer → 只认响应给的那几个 header（不再回落）")
    func responseHeadersWin() async throws {
        let body = #"{"url":"https://cdn.example.com/real/stream.m3u8?token=abcdefghijklmnop","Referer":"https://site.example.com/"}"#
        let recorder = ParseRequestRecorder(response: jsonResponse(body))
        let parsed = try await JSONParser(transport: recorder).parse(makeJob())
        #expect(parsed.headers["Referer"] == "https://site.example.com/")
        #expect(parsed.headers["User-Agent"] == nil)
    }

    @Test("type=0（Web）不是 JSON 解析器的活 → unsupported")
    func rejectsWebKind() async {
        let recorder = ParseRequestRecorder(response: jsonResponse(okBody))
        do {
            _ = try await JSONParser(transport: recorder).parse(makeJob(type: ParserKind.web.rawValue))
            Issue.record("type=0 应当被拒绝")
        } catch let error as CatVodError {
            guard case .unsupported = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test("JAR（type=2）不可用 → unsupported（原因含 JVM）")
    func rejectsJar() async {
        let recorder = ParseRequestRecorder(response: jsonResponse(okBody))
        do {
            _ = try await JSONParser(transport: recorder).parse(makeJob(type: ParserKind.jarJson.rawValue))
            Issue.record("JAR 解析器应当被拒绝")
        } catch let error as CatVodError {
            guard case let .unsupported(_, reason) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(reason.contains("JVM"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    /// 断言某个响应体必然导致 `parseFailed`（过短 / 空地址两类共用）。
    private func expectParseFailure(_ body: String) async {
        let recorder = ParseRequestRecorder(response: jsonResponse(body))
        do {
            _ = try await JSONParser(transport: recorder).parse(makeJob())
            Issue.record("应当判为解析失败：\(body)")
        } catch let error as CatVodError {
            guard case .parseFailed = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }
}
