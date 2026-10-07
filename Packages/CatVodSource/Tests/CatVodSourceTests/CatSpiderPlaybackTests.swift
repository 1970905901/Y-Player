import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

@Suite("CatSpider 播放与站点清单")
struct CatSpiderPlaybackTests {
    @Test("play：flag + id，并解析出播放地址")
    func playPayload() async throws {
        let (client, recorder) = try makeCatSpiderClient(response: #"{"url":"http://a/b.m3u8"}"#)
        let result = try await client.play(flag: "线路1", id: "video-1")

        let request = await recorder.lastRequest()
        #expect(request?.url.path.hasSuffix("/play") == true)
        let payload = catSpiderBody(of: request)
        #expect(payload["flag"] as? String == "线路1")
        #expect(payload["id"] as? String == "video-1")
        #expect(result.primaryPlaybackURL == "http://a/b.m3u8")
    }

    @Test("detail：id")
    func detailPayload() async throws {
        let (client, recorder) = try makeCatSpiderClient(
            response: #"{"list":[{"vod_id":"1","vod_play_from":"线路1","vod_play_url":"第1集$abc"}]}"#
        )
        let result = try await client.detail(id: "1")

        let request = await recorder.lastRequest()
        #expect(request?.url.path.hasSuffix("/detail") == true)
        #expect(catSpiderBody(of: request)["id"] as? String == "1")

        let lines = PlaylistParser.parse(
            playFrom: result.list[0].vodPlayFrom,
            playURL: result.list[0].vodPlayURL
        )
        #expect(lines.count == 1)
        #expect(lines[0].episodes.first?.url == "abc")
    }

    @Test("initialize / home / config 路由与方法")
    func lifecycleRoutes() async throws {
        let (client, recorder) = try makeCatSpiderClient(response: #"{"list":[]}"#)
        _ = try await client.initialize()
        _ = try await client.home()
        _ = try await client.configuration()

        let requests = await recorder.requests
        // 站点 api 为 `.../spider/<key>`，因此真实路径是 `/spider/<key>/<route>`；
        // 这里断言“末段路由名”，避免与站点 key 耦合。
        #expect(requests.map(\.url.lastPathComponent) == ["init", "home", "config"])
        #expect(requests.allSatisfy { $0.url.path.hasPrefix("/spider/") })
        let allPost = requests.allSatisfy { $0.method == .post }
        #expect(allPost)
    }
}
