import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

@Suite("直播源加载：取清单 → 解析（M07a 接线）")
struct LiveRepositoryTests {
    /// 直播源模型字段多，一律走 JSON 构造（与生产路径同一条）。
    private func makeSource(_ json: String) throws -> LiveSource {
        try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    private func makeSource(
        name: String = "演示直播",
        url: String = "https://live.example.com/list.m3u8"
    ) throws -> LiveSource {
        let json = #"{"name":"\#(name)","url":"\#(url)","ua":"UA-live","header":{"Referer":"https://site.example.com/"}}"#
        return try makeSource(json)
    }

    private let playlist = """
    #EXTM3U
    #EXTINF:-1 group-title="央视",CCTV-1
    http://live.example.com/cctv1.m3u8
    """

    @Test("正常：带源级 header 取清单，解析出分组与编号")
    func loadsPlaylist() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(playlist.utf8)))
        let parsed = try await LiveRepository(transport: recorder).load(makeSource())

        #expect(parsed.groups.map(\.name) == ["央视"])
        #expect(parsed.groups.first?.channels.first?.number == "001")

        let request = await recorder.firstRequest()
        #expect(request?.url.absoluteString == "https://live.example.com/list.m3u8")
        #expect(request?.headers["User-Agent"] == "UA-live")
        #expect(request?.headers["Referer"] == "https://site.example.com/")
    }

    @Test("已经解析过的源直接返回，不再发请求（上游 `LiveParser.start` 的短路）")
    func skipsParsed() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(playlist.utf8)))
        let parsed = try await LiveRepository(transport: recorder).load(makeSource())
        let again = try await LiveRepository(transport: recorder).load(parsed)

        #expect(again.channelCount == parsed.channelCount)
        let count = await recorder.requests.count
        #expect(count == 1)
    }

    @Test("Spider 源（api 非空）明确报错，且不发请求")
    func spiderUnsupported() async throws {
        let recorder = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(playlist.utf8)))
        let source = try makeSource(#"{"name":"Spider源","url":"https://live.example.com/x","api":"csp_Live"}"#)
        do {
            _ = try await LiveRepository(transport: recorder).load(source)
            Issue.record("Spider 源应当明确拒绝")
        } catch let error as CatVodError {
            #expect(error.errorDescription?.contains("Spider") == true)
        }
        let count = await recorder.requests.count
        #expect(count == 0)
    }

    @Test("非 2xx → network；地址非法 → parseFailed")
    func failures() async throws {
        let failing = ParseRequestRecorder(response: HTTPResponse(status: 404, body: Data("<html>404</html>".utf8)))
        do {
            _ = try await LiveRepository(transport: failing).load(makeSource())
            Issue.record("404 应当被拒绝")
        } catch let error as CatVodError {
            guard case .network = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }

        let broken = ParseRequestRecorder(response: HTTPResponse(status: 200, body: Data(playlist.utf8)))
        let badURL = try makeSource(name: "坏地址", url: "not a url")
        do {
            _ = try await LiveRepository(transport: broken).load(badURL)
            Issue.record("非法地址应当被拒绝")
        } catch let error as CatVodError {
            guard case .parseFailed = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }
}
