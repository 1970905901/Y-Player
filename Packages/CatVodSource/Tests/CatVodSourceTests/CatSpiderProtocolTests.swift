import CatVodCore
import CatVodNet
import Foundation
import Testing

@testable import CatVodSource

/// 记录请求的假传输层（同测试 target 内共享）。
actor CatSpiderRequestRecorder: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private let response: HTTPResponse

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }

    func lastRequest() -> HTTPRequest? {
        requests.last
    }
}

/// 测试辅助：构造带假传输层的客户端。
///
/// 注意站点 `api` 必须是真实形态 `http://127.0.0.1:<port>/spider/<key>`：
/// `CatSpiderHTTPClient` 的分派判定与 `CatSpider.java#matches` 一致，要求包含 `/spider/`。
func makeCatSpiderClient(
    response: String,
    site: Site? = nil
) throws -> (CatSpiderHTTPClient, CatSpiderRequestRecorder) {
    let api = try #require(URL(string: "http://127.0.0.1:9988/spider/cat"))
    let target = site ?? Site(key: "cat", name: "猫源", type: 3, api: api.absoluteString)
    let recorder = CatSpiderRequestRecorder(response: HTTPResponse(status: 200, body: Data(response.utf8)))
    let client = try #require(CatSpiderHTTPClient(site: target, transport: recorder))
    return (client, recorder)
}

/// 测试辅助：取出请求体 JSON 对象。
func catSpiderBody(of request: HTTPRequest?) -> [String: Any] {
    guard let data = request?.body else {
        return [:]
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@Suite("CatSpider 协议对齐（对齐 CatSpider.java）")
struct CatSpiderProtocolTests {
    @Test("站点匹配与 api 尾斜杠归一化")
    func siteMatching() throws {
        let matched = Site(key: "a", name: "A", type: 3, api: "http://127.0.0.1:9988/spider/")
        #expect(matched.isCatSpiderHTTP)

        let transport = CatSpiderRequestRecorder(response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let client = try #require(CatSpiderHTTPClient(site: matched, transport: transport))
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:9988/spider")

        let notMatched = Site(key: "b", name: "B", type: 3, api: "csp_Demo")
        #expect(!notMatched.isCatSpiderHTTP)
        #expect(CatSpiderHTTPClient(site: notMatched, transport: transport) == nil)
    }

    @Test("category：page 必须是数字，filters 是对象")
    func categoryPayload() async throws {
        let (client, recorder) = try makeCatSpiderClient(response: #"{"class":[],"list":[]}"#)
        _ = try await client.category(id: "movie", page: 3, filters: ["area": "大陆"])

        let request = await recorder.lastRequest()
        #expect(request?.url.path == "/spider/category")
        let payload = catSpiderBody(of: request)
        #expect(payload["id"] as? String == "movie")
        #expect(payload["page"] as? Int == 3)
        let filters = payload["filters"] as? [String: String]
        #expect(filters?["area"] == "大陆")
    }

    @Test("search：wd + page")
    func searchPayload() async throws {
        let (client, recorder) = try makeCatSpiderClient(response: #"{"list":[]}"#)
        _ = try await client.search(keyword: "海贼", page: 2)

        let request = await recorder.lastRequest()
        #expect(request?.url.path == "/spider/search")
        let payload = catSpiderBody(of: request)
        #expect(payload["wd"] as? String == "海贼")
        #expect(payload["page"] as? Int == 2)
    }

    @Test("请求头使用站点 header，超时来自站点 timeout")
    func requestHeadersAndTimeout() async throws {
        let api = try #require(URL(string: "http://127.0.0.1:9988/spider/cat"))
        let site = Site(
            key: "cat",
            name: "猫源",
            type: 3,
            api: api.absoluteString,
            timeout: 9,
            header: ["User-Agent": "YPlayer"]
        )
        let recorder = CatSpiderRequestRecorder(
            response: HTTPResponse(status: 200, body: Data(#"{"list":[]}"#.utf8))
        )
        let client = try #require(CatSpiderHTTPClient(site: site, transport: recorder))
        _ = try await client.home()

        let request = await recorder.lastRequest()
        #expect(request?.headers["User-Agent"] == "YPlayer")
        #expect(request?.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(request?.timeout == 9)
    }

    @Test("非 200 抛网络错误")
    func nonSuccessStatus() async throws {
        let api = try #require(URL(string: "http://127.0.0.1:9988/spider/cat"))
        let site = Site(key: "cat", name: "猫源", type: 3, api: api.absoluteString)
        let recorder = CatSpiderRequestRecorder(response: HTTPResponse(status: 500, body: Data()))
        let client = try #require(CatSpiderHTTPClient(site: site, transport: recorder))

        await #expect(throws: CatVodError.self) {
            _ = try await client.home()
        }
    }
}
