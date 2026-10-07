import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

// 辅助（RoutingSearchTransport / searchResponse / cmsSite）见 ChangeSourceMatchTests.swift

@Suite("换源：多站点候选")
struct ChangeSourceServiceTests {
    @Test("跳过永久禁用与不可用站点，只查可换源的 CMS 站点")
    func skipsDisabledAndUnavailable() async {
        let transport = RoutingSearchTransport(responses: [
            "good.example.com": searchResponse(["海贼王"]),
            "other.example.com": searchResponse(["西游记"]),
            "disabled.example.com": searchResponse(["海贼王"]),
        ])
        let service = ChangeSourceService(client: CMSClient(transport: transport))
        let sites = [
            cmsSite("good"),
            cmsSite("other"),
            cmsSite("disabled", changeable: 0),
            // type=3 + csp_*.jar → 本平台不可用，必须跳过
            Site(key: "jar", name: "jar", type: 3, api: "csp_test.jar"),
        ]

        let candidates = await service.candidates(title: "海贼王", sites: sites, currentSiteKey: "good")
        let hosts = await transport.requestedHosts()
        let requestedDisabled = hosts.contains("disabled.example.com")
        let requestedEmptyHost = hosts.contains(where: { $0.isEmpty })

        #expect(candidates.count == 1)
        #expect(candidates.first?.site.key == "good")
        #expect(candidates.first?.isCurrent == true)
        #expect(!requestedDisabled)
        #expect(!requestedEmptyHost)
    }

    @Test("单站搜索失败被忽略，其它站点结果照常返回（best-effort）")
    func toleratesSiteFailure() async {
        let transport = RoutingSearchTransport(responses: [
            "good.example.com": searchResponse(["海贼王"]),
            // broken.example.com 没有配置响应 → 抛错
        ])
        let service = ChangeSourceService(client: CMSClient(transport: transport))
        let candidates = await service.candidates(
            title: "海贼王",
            sites: [cmsSite("broken"), cmsSite("good")],
            currentSiteKey: nil
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.site.key == "good")
    }

    @Test("排序：匹配度优先；无关片名被过滤")
    func ordering() async {
        let transport = RoutingSearchTransport(responses: [
            "current.example.com": searchResponse(["海贼王 剧场版", "西游记"]),
            "exact.example.com": searchResponse(["海贼王"]),
        ])
        let service = ChangeSourceService(client: CMSClient(transport: transport))
        let candidates = await service.candidates(
            title: "海贼王",
            sites: [cmsSite("current"), cmsSite("exact")],
            currentSiteKey: "current"
        )

        #expect(candidates.count == 2)
        #expect(candidates.first?.site.key == "exact")
        #expect(candidates.last?.site.key == "current")
    }

    @Test("maxSites 限制查询站点数量")
    func respectsMaxSites() async {
        let transport = RoutingSearchTransport(responses: [
            "a.example.com": searchResponse(["海贼王"]),
            "b.example.com": searchResponse(["海贼王"]),
            "c.example.com": searchResponse(["海贼王"]),
        ])
        let service = ChangeSourceService(client: CMSClient(transport: transport), maxSites: 1)
        let candidates = await service.candidates(
            title: "海贼王",
            sites: [cmsSite("a"), cmsSite("b"), cmsSite("c")],
            currentSiteKey: nil
        )
        let hosts = await transport.requestedHosts()

        #expect(candidates.count == 1)
        #expect(hosts.count == 1)
    }

    @Test("空片名不发起任何请求")
    func emptyTitle() async {
        let transport = RoutingSearchTransport(responses: ["a.example.com": searchResponse(["x"])])
        let service = ChangeSourceService(client: CMSClient(transport: transport))
        let candidates = await service.candidates(title: "   ", sites: [cmsSite("a")], currentSiteKey: nil)
        let requestCount = await transport.requestedHosts().count

        #expect(candidates.isEmpty)
        #expect(requestCount == 0)
    }
}
