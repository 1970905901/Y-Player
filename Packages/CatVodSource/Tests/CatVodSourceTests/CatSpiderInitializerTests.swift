import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 按路径给不同响应的假传输层：`/init` 与动作需要能返回不同状态码。
private actor CatSpiderRouteRecorder: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private let responses: [String: HTTPResponse]
    private let fallback: HTTPResponse

    init(
        responses: [String: HTTPResponse] = [:],
        fallback: HTTPResponse = HTTPResponse(status: 200, body: Data(#"{"list":[]}"#.utf8))
    ) {
        self.responses = responses
        self.fallback = fallback
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses[request.url.lastPathComponent] ?? fallback
    }

    func paths() -> [String] {
        requests.map(\.url.lastPathComponent)
    }

    func count(of path: String) -> Int {
        paths().filter { $0 == path }.count
    }

    /// 返回**可 Sendable** 的文本体：直接返回 `[String: Any]` 会被 Swift 6 拒绝
    /// （`non-sendable result type '[String : Any]' cannot be sent from actor-isolated context`，
    /// 这是 SwiftPM tests 本轮抓到的编译错误）。
    func bodyText(ofFirst path: String) -> String? {
        guard let request = requests.first(where: { $0.url.lastPathComponent == path }),
              let data = request.body
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private func spiderSite(key: String = "cat") -> Site {
    Site(key: key, name: key, type: 3, api: "http://127.0.0.1:9988/spider/\(key)/3")
}

private func cmsSite() -> Site {
    Site(key: "cms", name: "CMS", type: 1, api: "https://cms.example.com/api.php/provide/vod")
}

/// js2p 站点的 `POST /init` 生命周期（对齐参考实现 `CatSpider.java` 的 `Spider.init`）。
///
/// 这些用例存在的理由：`initialize()` 之前**只在单测里被调用过**，应用流程一次都没发 ——
/// 对「init 是空实现」的站点看不出来，对真有实现的站点（实测 `wogg` 的 init 返回 siteUrl）就缺了一步。
@Suite("CatSpider 站点初始化（POST /init 只发一次）")
struct CatSpiderInitializerTests {
    @Test("同一站点的多个动作只 init 一次，且 init 在动作之前")
    func initOncePerSite() async throws {
        let transport = CatSpiderRouteRecorder()
        let initializer = CatSpiderInitializer()
        let client = SiteClient(transport: transport, initializer: initializer)
        let site = spiderSite()

        _ = try await client.home(site: site)
        _ = try await client.home(site: site)

        // Swift Testing 的宏参数里不能写 await（本仓库踩过：见 docs/构建与分发.md 陷阱 2），
        // 一律先取到局部变量再断言。
        let paths = await transport.paths()
        let failures = await initializer.failureCount()
        #expect(paths == ["init", "home", "home"])
        #expect(failures == 0)
    }

    @Test("init 载荷是空 JSON 对象（逐行对齐 CatSpider.java 的 new JsonObject()）")
    func initPayload() async throws {
        let transport = CatSpiderRouteRecorder()
        let client = SiteClient(transport: transport, initializer: CatSpiderInitializer())

        _ = try await client.home(site: spiderSite())

        // 载荷编码按字典序，空对象就是 `{}`（逐行对齐 CatSpider.java 的 new JsonObject()）。
        let body = await transport.bodyText(ofFirst: "init")
        #expect(body == "{}")
    }

    @Test("并发调用共享同一次 init（不会各发一遍）")
    func concurrentCallsShareOneInit() async throws {
        let transport = CatSpiderRouteRecorder()
        let client = SiteClient(transport: transport, initializer: CatSpiderInitializer())
        let site = spiderSite()

        async let first: SpiderResult = client.home(site: site)
        async let second: SpiderResult = client.search(site: site, keyword: "x", page: 1)
        _ = try await (first, second)

        let initCount = await transport.count(of: "init")
        let total = await transport.paths().count
        #expect(initCount == 1)
        #expect(total == 3)
    }

    @Test("不同站点各自 init 一次（记忆键是 api 全路径）")
    func separateSitesInitSeparately() async throws {
        let transport = CatSpiderRouteRecorder()
        let client = SiteClient(transport: transport, initializer: CatSpiderInitializer())

        _ = try await client.home(site: spiderSite(key: "a"))
        _ = try await client.home(site: spiderSite(key: "b"))
        _ = try await client.home(site: spiderSite(key: "a"))

        let initCount = await transport.count(of: "init")
        let paths = await transport.paths()
        #expect(initCount == 2)
        #expect(paths == ["init", "home", "init", "home", "home"])
    }

    @Test("init 失败不阻断动作，但记下原因（参考实现同样只记日志）")
    func initFailureDoesNotBlockAction() async throws {
        let transport = CatSpiderRouteRecorder(
            responses: ["init": HTTPResponse(status: 404, body: Data("{}".utf8))]
        )
        let initializer = CatSpiderInitializer()
        let client = SiteClient(transport: transport, initializer: initializer)

        // 动作照常执行（这里 /home 返回 200 空列表），错误由动作自己承担。
        let result = try await client.home(site: spiderSite())
        #expect(result.list.isEmpty)

        let paths = await transport.paths()
        let failures = await initializer.failureCount()
        let note = await initializer.failureNote(forBaseURL: "http://127.0.0.1:9988/spider/cat/3")
        #expect(paths == ["init", "home"])
        #expect(failures == 1)
        #expect(note?.contains("/init") == true)
    }

    @Test("init 失败后不会在每个动作前重试（与参考实现一致：每个实例只 init 一次）")
    func initFailureIsNotRetried() async throws {
        let transport = CatSpiderRouteRecorder(
            responses: ["init": HTTPResponse(status: 500, body: Data())]
        )
        let client = SiteClient(transport: transport, initializer: CatSpiderInitializer())
        let site = spiderSite()

        _ = try await client.home(site: site)
        _ = try await client.home(site: site)

        let initCount = await transport.count(of: "init")
        #expect(initCount == 1)
    }

    @Test("CMS 站点不参与 init（它没有这个生命周期）")
    func cmsSiteNeverInitializes() async throws {
        let transport = CatSpiderRouteRecorder()
        let initializer = CatSpiderInitializer()
        let client = SiteClient(transport: transport, initializer: initializer)

        _ = try await client.home(site: cmsSite())
        _ = try await client.category(site: cmsSite(), categoryID: "1", page: 1)

        let initCount = await transport.count(of: "init")
        let failures = await initializer.failureCount()
        #expect(initCount == 0)
        #expect(failures == 0)
    }
}
