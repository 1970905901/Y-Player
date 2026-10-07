import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

@Suite("站点客户端分发（CMS vs CatSpider HTTP）")
struct SiteClientDispatchTests {
    private func recorder(_ body: String = #"{"list":[]}"#) -> CatSpiderRequestRecorder {
        CatSpiderRequestRecorder(response: HTTPResponse(status: 200, body: Data(body.utf8)))
    }

    private func spiderSite(
        api: String = "http://127.0.0.1:9988/spider/douban/3",
        key: String = "nodejs_douban"
    ) -> Site {
        Site(key: key, name: "豆瓣|首页", type: 3, api: api)
    }

    @Test("type 1（JSON CMS）：走 CMSClient，首页裸 GET、分类带 ac/t/pg")
    func cmsSiteUsesCMSClient() async throws {
        let recorder = recorder()
        let client = SiteClient(transport: recorder)
        let site = Site(key: "cms", name: "CMS", type: 1, api: "https://cms.example.com/api.php/provide/vod")

        _ = try await client.home(site: site)
        _ = try await client.category(site: site, categoryID: "1", page: 2)

        let requests = await recorder.requests
        #expect(requests.count == 2)

        // 首页：类型 0/1/2 不带业务参数（逐行对齐 SiteApi.java）。
        // 注意：组装层对空参数也会设置 queryItems，URL 末尾因此可能留下一个 `?`，
        // 所以这里断言 host/path + 参数为空，而不是做整串字符串比较。
        let home = try #require(requests.first)
        #expect(home.method == .get)
        #expect(home.url.host == "cms.example.com")
        #expect(home.url.path == "/api.php/provide/vod")
        let homeQuery = home.url.query ?? ""
        #expect(homeQuery.isEmpty)

        // 分类：ac=detail + t=<分类ID> + pg=<页码>。
        let categoryURL = try #require(requests.last?.url.absoluteString)
        #expect(categoryURL.contains("ac=detail"))
        #expect(categoryURL.contains("t=1"))
        #expect(categoryURL.contains("pg=2"))
    }

    @Test("type 3 且 api 含 /spider/（js2p 宿主站点）：走 CatSpiderHTTPClient，POST 到 /home")
    func catSpiderSiteUsesSpiderClient() async throws {
        let recorder = recorder()
        let client = SiteClient(transport: recorder)

        _ = try await client.home(site: spiderSite())

        let request = await recorder.lastRequest()
        #expect(request?.method == .post)
        #expect(request?.url.absoluteString == "http://127.0.0.1:9988/spider/douban/3/home")
    }

    @Test("搜索 / 分类 / 详情按类型分发到对应路由")
    func routesDispatch() async throws {
        let recorder = recorder()
        let client = SiteClient(transport: recorder)
        let site = spiderSite()

        _ = try await client.search(site: site, keyword: "海贼", page: 2)
        _ = try await client.category(site: site, categoryID: "1", page: 3, extend: ["area": "大陆"])
        _ = try await client.detail(site: site, vodID: "42")

        let requests = await recorder.requests
        let paths = requests.map(\.url.lastPathComponent)
        #expect(paths == ["search", "category", "detail"])
        let allPost = requests.allSatisfy { $0.method == .post }
        #expect(allPost)
    }

    @Test("CatSpider 的 play 走 POST /play（flag + id）")
    func spiderPlay() async throws {
        let recorder = recorder(#"{"url":"http://a/b.m3u8"}"#)
        let client = SiteClient(transport: recorder)

        let result = try await client.play(site: spiderSite(), flag: "线路1", id: "video-1")

        #expect(result.primaryPlaybackURL == "http://a/b.m3u8")
        let request = await recorder.lastRequest()
        #expect(request?.url.lastPathComponent == "play")
    }

    @Test("type 3 但平台不支持（csp_*.jar）：抛 unsupported，且不发任何请求")
    func unsupportedSpiderDoesNotSend() async throws {
        let recorder = recorder()
        let client = SiteClient(transport: recorder)
        let site = Site(key: "jar", name: "JAR Spider", type: 3, api: "csp_AppYsV2", jar: "csp_AppYsV2.jar")

        do {
            _ = try await client.home(site: site)
            Issue.record("应当抛出 unsupported")
        } catch let error as CatVodError {
            guard case let .unsupported(feature, reason) = error else {
                Issue.record("错误分支不符：\(error)")
                return
            }
            #expect(feature == "spider")
            #expect(reason.contains("JVM"))
        }

        let requests = await recorder.requests
        #expect(requests.isEmpty)
    }

    @Test("api 以 /spider 结尾（缺尾斜杠）：仍按不支持处理，并说明是协议判定问题")
    func spiderWithoutTrailingSlash() throws {
        let recorder = recorder()
        let client = SiteClient(transport: recorder)
        let site = spiderSite(api: "http://127.0.0.1:9988/spider", key: "bare")

        do {
            _ = try client.resolve(site)
            Issue.record("应当抛出 unsupported")
        } catch let error as CatVodError {
            guard case let .unsupported(feature, reason) = error else {
                Issue.record("错误分支不符：\(error)")
                return
            }
            #expect(feature == "spider")
            #expect(reason.contains("/spider/"))
        }
    }

    @Test("CMS 站点的 play：明确不支持（播放地址来自详情）")
    func cmsPlayUnsupported() async throws {
        let recorder = recorder()
        let client = SiteClient(transport: recorder)
        let site = Site(key: "cms", name: "CMS", type: 1, api: "https://cms.example.com/api.php/provide/vod")

        do {
            _ = try await client.play(site: site, flag: "1", id: "2")
            Issue.record("应当抛出 unsupported")
        } catch let error as CatVodError {
            guard case let .unsupported(feature, _) = error else {
                Issue.record("错误分支不符：\(error)")
                return
            }
            #expect(feature == "play")
        }

        let requests = await recorder.requests
        #expect(requests.isEmpty)
    }
}
