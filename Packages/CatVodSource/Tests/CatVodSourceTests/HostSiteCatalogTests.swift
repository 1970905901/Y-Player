import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 宿主 `/full-config` 的真实形态。
///
/// 字段与取值取自 M1.6 实测载荷（真实环境 85 条站点），这里裁剪成 5 条覆盖各种噪声：
/// 正常条目、`enable:false`、绝对 `api`、字符串数字/字符串布尔、缺 `api`。
/// 每行都拆短，避免 SwiftLint 的 `line_length`。
private let hostConfigFixture = #"""
{
  "video": {
    "danmuSearchUrl": "",
    "sites": [
      {
        "key": "nodejs_douban", "name": "豆瓣|首页", "type": 3, "indexs": 1,
        "enable": true, "searchable": 1, "quickSearch": 1, "filterable": 1,
        "api": "/spider/douban/3"
      },
      {
        "key": "nodejs_disabled", "name": "已禁用", "type": 3,
        "enable": false, "searchable": 1, "quickSearch": 1,
        "api": "/spider/off/3"
      },
      {
        "key": "legacy_abs", "name": "绝对地址", "type": 3,
        "enable": 1, "api": "http://example.com/spider/x/3"
      },
      {
        "key": "nodejs_strtype", "name": "字符串类型", "type": "4",
        "enable": "true", "searchable": 0, "api": "spider/rel/4"
      },
      {
        "key": "no_api", "name": "无地址", "type": 3, "enable": true
      }
    ]
  },
  "read": {"sites": []},
  "comic": {"sites": []},
  "music": {"sites": []},
  "pan": {"sites": []},
  "color": [{"light": {"bg": "https://example.com/bg.jpg"}}]
}
"""#

@Suite("宿主站点清单（GET /full-config 实测契约）")
struct HostSiteCatalogTests {
    private func makeCatalog(
        response: String,
        status: Int = 200
    ) -> (HostSiteCatalog, CatSpiderRequestRecorder) {
        let recorder = CatSpiderRequestRecorder(
            response: HTTPResponse(status: status, body: Data(response.utf8))
        )
        return (HostSiteCatalog(transport: recorder), recorder)
    }

    private func baseURL() throws -> URL {
        try #require(URL(string: "http://127.0.0.1:9988"))
    }

    @Test("请求 /full-config：补全相对 api、过滤禁用与缺 api 的站点")
    func decodeRealPayload() async throws {
        let (catalog, recorder) = makeCatalog(response: hostConfigFixture)
        let base = try baseURL()
        let snapshot = try await catalog.config(baseURL: base)

        // 5 条里 1 条被禁用、1 条缺 api → 可用 3 条。
        #expect(snapshot.sites.count == 3)
        #expect(snapshot.disabledSiteCount == 1)

        let douban = try #require(snapshot.sites.first { $0.key == "nodejs_douban" })
        #expect(douban.name == "豆瓣|首页")
        #expect(douban.type == 3)
        #expect(douban.indexs == 1)
        #expect(douban.api == "http://127.0.0.1:9988/spider/douban/3")
        // 补全后含 `/spider/`，正好满足 CatSpider.java#matches 的分派判定。
        #expect(douban.isCatSpiderHTTP)

        let absolute = try #require(snapshot.sites.first { $0.key == "legacy_abs" })
        #expect(absolute.api == "http://example.com/spider/x/3")

        let noisy = try #require(snapshot.sites.first { $0.key == "nodejs_strtype" })
        #expect(noisy.type == 4)
        #expect(noisy.searchable == 0)
        #expect(noisy.api == "http://127.0.0.1:9988/spider/rel/4")

        #expect(snapshot.sites.contains { $0.key == "nodejs_disabled" } == false)
        #expect(snapshot.sites.contains { $0.key == "no_api" } == false)

        let request = await recorder.lastRequest()
        #expect(request?.url.absoluteString == "http://127.0.0.1:9988/full-config")
        #expect(request?.method == .get)
    }

    @Test("absoluteAPI：绝对地址原样、相对地址补全、空值返回空")
    func absoluteAPI() throws {
        let base = try baseURL()
        let leading = HostSiteCatalog.absoluteAPI("/spider/a/3", baseURL: base)
        #expect(leading == "http://127.0.0.1:9988/spider/a/3")

        let bare = HostSiteCatalog.absoluteAPI("spider/a/3", baseURL: base)
        #expect(bare == "http://127.0.0.1:9988/spider/a/3")

        let https = HostSiteCatalog.absoluteAPI("https://x/y", baseURL: base)
        #expect(https == "https://x/y")

        let blank = HostSiteCatalog.absoluteAPI("   ", baseURL: base)
        #expect(blank.isEmpty)

        let trailing = try #require(URL(string: "http://127.0.0.1:9988/"))
        let normalized = HostSiteCatalog.absoluteAPI("/spider/a/3", baseURL: trailing)
        #expect(normalized == "http://127.0.0.1:9988/spider/a/3")
    }

    @Test("spiderKey 兜底：站点缺 key 时取 api 的 spider 段")
    func spiderKeyFallback() {
        let key = HostSiteCatalog.spiderKey(fromAPI: "http://127.0.0.1:9988/spider/douban/3")
        #expect(key == "douban")

        let none = HostSiteCatalog.spiderKey(fromAPI: "http://example.com/other")
        #expect(none.isEmpty)
    }

    @Test("health：只有 ok 为 true 且 2xx 才算可用")
    func health() async throws {
        let base = try baseURL()

        let (healthy, _) = makeCatalog(response: #"{"ok":true,"name":"CatVodSpiderios"}"#)
        let healthyResult = await healthy.health(baseURL: base)
        #expect(healthyResult)

        let (notOK, _) = makeCatalog(response: #"{"ok":false}"#)
        let notOKResult = await notOK.health(baseURL: base)
        #expect(notOKResult == false)

        let (garbage, _) = makeCatalog(response: "<html>")
        let garbageResult = await garbage.health(baseURL: base)
        #expect(garbageResult == false)

        let (failing, _) = makeCatalog(response: #"{"ok":true}"#, status: 500)
        let failingResult = await failing.health(baseURL: base)
        #expect(failingResult == false)
    }

    @Test("非 200 与非 JSON：分别抛网络错误与配置错误")
    func errorMapping() async throws {
        let base = try baseURL()

        let (failing, _) = makeCatalog(response: "", status: 503)
        await #expect(throws: CatVodError.self) {
            _ = try await failing.sites(baseURL: base)
        }

        let (garbage, _) = makeCatalog(response: "<html>")
        await #expect(throws: CatVodError.self) {
            _ = try await garbage.sites(baseURL: base)
        }
    }

    @Test("没有 video 分区时返回空清单，不抛错")
    func missingVideoSection() async throws {
        let (catalog, _) = makeCatalog(response: #"{"color":[]}"#)
        let sites = try await catalog.sites(baseURL: baseURL())
        #expect(sites.isEmpty)
    }
}
