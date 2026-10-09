import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// TMDB 客户端（M11）：解析、URL 参数、错误分类 —— 全用桩传输，不打网。
struct TMDBClientTests {
    /// 记录每次请求的地址，并按预设返回。
    private struct Stub: HTTPTransport {
        let status: Int
        let body: String
        let captured: Box

        final class Box: @unchecked Sendable {
            var urls: [URL] = []
        }

        init(status: Int = 200, body: String, captured: Box = Box()) {
            self.status = status
            self.body = body
            self.captured = captured
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            captured.urls.append(request.url)
            return HTTPResponse(status: status, headers: [:], body: Data(body.utf8))
        }
    }

    private func client(_ stub: Stub, apiKey: String = "k") -> TMDBClient {
        TMDBClient(config: TMDBConfig(apiKey: apiKey, imageProxy: ""), transport: stub)
    }

    @Test("搜索：多类型结果收成模型，电视剧的 name 也会当成标题")
    func searchParses() async throws {
        let stub = Stub(body: """
        {"results":[
          {"id":1,"media_type":"tv","name":"仙逆","overview":"凡人修仙","poster_path":"/p.jpg","backdrop_path":"/b.jpg","genre_ids":[16,10759]},
          {"id":2,"media_type":"movie","title":"绿灯军团","overview":"","poster_path":"/p2.jpg","backdrop_path":"","genre_ids":[]},
          {"id":3,"media_type":"person","name":"某人"}
        ]}
        """)
        let results = try await client(stub).search("仙逆")
        #expect(results.count == 2) // person 被丢掉
        #expect(results[0].title == "仙逆")
        #expect(results[0].kind == .tv)
        #expect(results[0].isAnimation) // genre 16
        #expect(results[1].title == "绿灯军团")
        #expect(!results[1].isAnimation)
    }

    @Test("搜索会带上 language 与 api_key，代理生效时地址被改写")
    func searchURL() async throws {
        let box = Stub.Box()
        let stub = Stub(body: #"{"results":[]}"#, captured: box)
        let proxied = TMDBClient(
            config: TMDBConfig(apiKey: "k", apiProxy: "https://p.example/x?u={url}"),
            transport: stub,
            language: "zh-CN"
        )
        _ = try await proxied.search("仙逆")
        let url = try #require(box.urls.first?.absoluteString)
        #expect(url.hasPrefix("https://p.example/x?u=https://api.themoviedb.org/3/search/multi?"))
        #expect(url.contains("api_key=k"))
        #expect(url.contains("language=zh-CN"))
    }

    @Test("详情：电影读 title、电视剧读 name，genres 收成 id 数组")
    func detailsParsesBothShapes() async throws {
        let tv = try await client(Stub(body: """
        {"id":9,"name":"仙逆","overview":"简介","poster_path":"/p.jpg","backdrop_path":"/b.jpg","genres":[{"id":16},{"id":18}]}
        """)).details(kind: .tv, id: 9)
        #expect(tv.kind == .tv)
        #expect(tv.title == "仙逆")
        #expect(tv.isAnimation)

        let movie = try await client(Stub(body: """
        {"id":10,"title":"绿灯军团","overview":"","poster_path":"","backdrop_path":""}
        """)).details(kind: .movie, id: 10)
        #expect(movie.kind == .movie)
        #expect(movie.title == "绿灯军团")
        #expect(movie.overview.isEmpty)
    }

    @Test("图集：只取有 file_path 的背景图（轮播/随机的输入）")
    func backdropsParses() async throws {
        let stub = Stub(body: #"{"backdrops":[{"file_path":"/a.jpg"},{"file_path":""},{"file_path":"/b.jpg"}]}"#)
        let paths = try await client(stub).backdrops(kind: .tv, id: 9)
        #expect(paths == ["/a.jpg", "/b.jpg"])
    }

    @Test("没配 key：不发请求，直接给 notConfigured")
    func notConfigured() async throws {
        let box = Stub.Box()
        let stub = Stub(body: #"{"results":[]}"#, captured: box)
        await #expect(throws: TMDBError.notConfigured) {
            _ = try await client(stub, apiKey: "").search("仙逆")
        }
        #expect(box.urls.isEmpty) // 没打无效请求
    }

    @Test("状态码非 2xx 与解不出来，分成两种错")
    func errorClassification() async throws {
        await #expect(throws: TMDBError.badStatus(429)) {
            _ = try await client(Stub(status: 429, body: "{}")).search("x")
        }
        await #expect(throws: TMDBError.self) {
            _ = try await client(Stub(body: "not json")).search("x")
        }
    }
}
