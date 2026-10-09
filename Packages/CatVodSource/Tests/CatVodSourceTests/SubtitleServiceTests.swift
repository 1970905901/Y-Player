import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 记录请求的假传输层（与 `DanmakuServiceTests` 同一形态）。
private actor SubtitleTransport: HTTPTransport {
    private let response: HTTPResponse
    private(set) var requests: [HTTPRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

/// 字幕取用链（M09b）：挑源 / 下载 / 解析，以及「哪些不是错误」。
@Suite("字幕取用链")
struct SubtitleServiceTests {
    private let srt = """
    1
    00:00:01,000 --> 00:00:04,000
    第一句

    2
    00:00:05,000 --> 00:00:06,000
    第二句
    """

    private func source(_ url: String, format: String = "", language: String = "") -> SubtitleSource {
        SubtitleSource(name: "简中", url: url, language: language, format: format)
    }

    private func transport(_ body: String, status: Int = 200) -> SubtitleTransport {
        SubtitleTransport(response: HTTPResponse(status: status, body: Data(body.utf8)))
    }

    @Test("挑源：跳过没有地址的项，取第一条有地址的")
    func picksFirstWithURL() throws {
        let picked = try #require(SubtitleService.pick(from: [
            source(""),
            source("   "),
            source("https://a.example.com/1.srt"),
            source("https://a.example.com/2.srt"),
        ]))

        #expect(picked.url == "https://a.example.com/1.srt")
    }

    @Test("没有可用源：返回 nil，不抛错（站点没给字幕不是错误）")
    func noSourceIsNotAnError() async throws {
        let service = SubtitleService(transport: transport(srt))

        let loaded = try await service.load(from: [source(""), source("")])

        #expect(loaded == nil)
    }

    @Test("下载并解析：请求打到源的地址，cue 解析正确")
    func loadsAndParses() async throws {
        let transport = transport(srt)
        let service = SubtitleService(transport: transport)

        let loaded = try await service.load(from: [source("https://a.example.com/1.srt")])

        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://a.example.com/1.srt")
        #expect(loaded?.cues.count == 2)
        #expect(loaded?.cues.first?.text == "第一句")
        #expect(loaded?.source.url == "https://a.example.com/1.srt")
    }

    @Test("请求头按调用方给的原样带上（站点/结果 header 由上层合并）")
    func forwardsHeaders() async throws {
        let transport = transport(srt)
        let service = SubtitleService(transport: transport)

        _ = try await service.load(
            from: source("https://a.example.com/1.srt"),
            headers: ["Referer": "https://a.example.com/", "User-Agent": "UA-1"]
        )

        let request = try #require(await transport.requests.first)
        #expect(request.headers["Referer"] == "https://a.example.com/")
        #expect(request.headers["User-Agent"] == "UA-1")
    }

    @Test("格式透传：源的 `format` 参与判定（VTT 正文没有头也能认出来）")
    func passesFormat() async throws {
        let vtt = "00:00:01.000 --> 00:00:02.000\n正文"
        let service = SubtitleService(transport: transport(vtt))

        let loaded = try await service.load(from: [source("https://a.example.com/1", format: "text/vtt")])

        #expect(loaded?.cues.count == 1)
        #expect(loaded?.cues.first?.end == 2)
    }

    @Test("空响应体：下到了但没内容 → 空数组，不抛错")
    func emptyBodyIsNotAnError() async throws {
        let service = SubtitleService(transport: transport(""))

        let loaded = try await service.load(from: [source("https://a.example.com/1.srt")])

        #expect(loaded?.cues.isEmpty == true)
    }

    @Test("非 2xx：抛 network（带状态码与地址）")
    func rejectsNonSuccess() async throws {
        let service = SubtitleService(transport: transport("nope", status: 404))

        do {
            _ = try await service.load(from: [source("https://a.example.com/1.srt")])
            Issue.record("404 不该成功")
        } catch let error as CatVodError {
            guard case let .network(status, _, _) = error else {
                Issue.record("应该抛 network，实际是 \(error)")
                return
            }
            #expect(status == 404)
        }
    }

    @Test("地址不是合法 URL：抛 decoding（不是崩）")
    func rejectsBadURL() async throws {
        let service = SubtitleService(transport: transport(srt))

        do {
            _ = try await service.load(from: source("不是 URL"))
            Issue.record("非法地址不该成功")
        } catch let error as CatVodError {
            guard case let .decoding(path, _) = error else {
                Issue.record("应该抛 decoding，实际是 \(error)")
                return
            }
            #expect(path == "subtitle")
        }
    }
}
