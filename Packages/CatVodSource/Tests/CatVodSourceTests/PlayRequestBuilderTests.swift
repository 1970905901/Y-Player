import CatVodCore
import CatVodNet
import Foundation
import Testing

@testable import CatVodSource

@Suite("播放请求构造（对齐 SiteApi.playerContent）")
struct PlayRequestBuilderTests {
    @Test("类型 0/1/2：直链且无站点 playUrl 时直接播放")
    func directPlayback() throws {
        let site = Site(key: "cms", name: "CMS", type: 1, api: "https://api.example.com/vod")
        let request = try PlayRequestBuilder.makeRequest(
            site: site,
            flag: "线路1",
            playID: "https://cdn.example.com/a.m3u8"
        )
        #expect(request.source == .direct)
        #expect(!request.requiresParsing)
    }

    @Test("类型 0/1/2：非直链需要解析")
    func needsParsing() throws {
        let site = Site(key: "cms", name: "CMS", type: 1, api: "https://api.example.com/vod")
        let request = try PlayRequestBuilder.makeRequest(site: site, flag: "线路1", playID: "video-1001")
        #expect(request.requiresParsing)
    }

    @Test("类型 0/1/2：站点级 playUrl 存在时需要解析")
    func sitePlayUrlForcesParsing() throws {
        let site = Site(
            key: "cms",
            name: "CMS",
            type: 1,
            api: "https://api.example.com/vod",
            playUrl: "parse:演示解析"
        )
        let request = try PlayRequestBuilder.makeRequest(
            site: site,
            flag: "线路1",
            playID: "https://cdn.example.com/a.m3u8"
        )
        #expect(request.requiresParsing)
        #expect(request.sitePlayUrl == "parse:演示解析")
    }

    @Test("类型 4：生成 play + flag 请求")
    func type4PlayRequest() throws {
        let site = Site(key: "http4", name: "HTTP4", type: 4, api: "https://api.example.com/vod")
        let request = try PlayRequestBuilder.makeRequest(site: site, flag: "线路2", playID: "abc")
        guard case let .http(httpRequest) = request.source else {
            Issue.record("类型 4 应生成 HTTP 播放请求")
            return
        }
        let items = URLComponents(url: httpRequest.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let parameters = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(parameters["play"] == "abc")
        #expect(parameters["flag"] == "线路2")
    }

    @Test("类型 3：交给 Spider，不本地判定直链")
    func spiderPlayRequest() throws {
        let site = Site(key: "cat", name: "猫源", type: 3, api: "http://127.0.0.1:9988/spider")
        let request = try PlayRequestBuilder.makeRequest(site: site, flag: "线路1", playID: "x")
        #expect(request.source == .spider)
        #expect(request.requiresParsing)
    }
}
