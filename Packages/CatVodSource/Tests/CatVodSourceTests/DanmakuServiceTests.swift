import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 记录请求的假传输层：弹幕链要按「搜索」和「下载文件」两种地址分别作答，
/// 而且**请求形状本身**（GET 还是 POST、表单字段、Content-Type）就是要断言的东西。
private actor RecordingTransport: HTTPTransport {
    private let routes: [String: HTTPResponse]
    private let failures: Set<String>
    private(set) var requests: [HTTPRequest] = []

    init(routes: [String: HTTPResponse], failures: Set<String> = []) {
        self.routes = routes
        self.failures = failures
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let text = request.url.absoluteString
        if failures.contains(where: { text.hasPrefix($0) }) {
            throw CatVodError.network(status: nil, url: text, reason: "连不上")
        }
        for (prefix, response) in routes where text.hasPrefix(prefix) {
            return response
        }
        return HTTPResponse(status: 404, body: Data("no route".utf8))
    }
}

/// 弹幕取用链（M08b）：搜索地址策略要真的落到请求上，下载解析要真的串起来。
@Suite("弹幕取用链")
struct DanmakuServiceTests {
    private func xml(_ entries: [(String, String)]) -> String {
        let body = entries.map { #"<d p="\#($0.0)">\#($0.1)</d>"# }.joined()
        return #"<?xml version="1.0" encoding="UTF-8"?><i>"# + body + "</i>"
    }

    @Test("基地址：搜索是 POST 表单，字段与 Content-Type 都对")
    func searchPostsForm() async throws {
        let transport = RecordingTransport(routes: [
            "https://d.example.com/danmaku": HTTPResponse(status: 200, body: Data(#"[]"#.utf8)),
        ])
        let service = DanmakuService(transport: transport)

        _ = try await service.search(api: "https://d.example.com", name: "片名", episode: "第1集")

        let recorded = await transport.requests
        let request = try #require(recorded.first)
        let body = try #require(request.body)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://d.example.com/danmaku")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(String(data: body, encoding: .utf8)
            == "episode=%E7%AC%AC1%E9%9B%86&name=%E7%89%87%E5%90%8D")
    }

    @Test("模板地址：搜索是 GET，名字编进 URL")
    func searchGetsTemplate() async throws {
        let transport = RecordingTransport(routes: [:])
        let service = DanmakuService(transport: transport)

        _ = try? await service.search(api: "https://d.example.com/x?n={name}&e={episode}", name: "片名", episode: "1")

        let recorded = await transport.requests
        let request = try #require(recorded.first)
        #expect(request.method == .get)
        #expect(request.body == nil)
        #expect(request.url.absoluteString.contains("n=%E7%89%87%E5%90%8D"))
    }

    @Test("一次到位：搜到候选 → 下载 → 解析成弹幕行（按时间排序）")
    func loadFullChain() async throws {
        let transport = RecordingTransport(routes: [
            "https://d.example.com/danmaku": HTTPResponse(
                status: 200,
                body: Data(#"[{"name":"甲源","url":"https://f.example.com/1.xml"}]"#.utf8)
            ),
            "https://f.example.com/1.xml": HTTPResponse(
                status: 200,
                body: Data(xml([("3.0,1,25,16777215", "晚的"), ("1.0,5,25,0", "早的")]).utf8)
            ),
        ])
        let service = DanmakuService(transport: transport)

        let lines = try await service.load(api: "https://d.example.com", name: "片名", episode: "1")
        let requested = await transport.requests

        #expect(lines.map(\.text) == ["早的", "晚的"])
        #expect(lines.map(\.time) == [1.0, 3.0])
        #expect(requested.count == 2)
    }

    @Test("没搜到候选：返回空数组而不是抛错（界面上不该是「错误」）")
    func emptySearchIsNotAnError() async throws {
        let transport = RecordingTransport(routes: [
            "https://d.example.com/danmaku": HTTPResponse(status: 200, body: Data(#"[]"#.utf8)),
        ])
        let service = DanmakuService(transport: transport)

        #expect(try await service.load(api: "https://d.example.com", name: "片名", episode: "1").isEmpty)
    }

    @Test("网络失败：抛 CatVodError（要能区分「搜不到」和「连不上」）")
    func transportFailureThrows() async throws {
        let transport = RecordingTransport(routes: [:], failures: ["https://d.example.com"])
        let service = DanmakuService(transport: transport)

        await #expect(throws: CatVodError.self) {
            _ = try await service.search(api: "https://d.example.com", name: "片名", episode: "1")
        }
    }

    @Test("文件 404：抛错（候选本身不行，交给上层决定要不要换一条）")
    func fileFailureThrows() async throws {
        let transport = RecordingTransport(routes: [
            "https://d.example.com/danmaku": HTTPResponse(
                status: 200,
                body: Data(#"[{"url":"https://f.example.com/missing.xml"}]"#.utf8)
            ),
        ])
        let service = DanmakuService(transport: transport)

        await #expect(throws: CatVodError.self) {
            _ = try await service.load(api: "https://d.example.com", name: "片名", episode: "1")
        }
    }

    @Test("空地址：不发请求、不抛错")
    func emptyAPIYieldsNothing() async throws {
        let transport = RecordingTransport(routes: [:])
        let service = DanmakuService(transport: transport)

        let found = try await service.search(api: "", name: "片名", episode: "1")
        let requested = await transport.requests

        #expect(found.isEmpty)
        #expect(requested.isEmpty)
    }
}
