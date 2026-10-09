import CatVodNet
import CatVodSource
@testable import CatVodUI
import Foundation
import Testing

/// 按路径分发的 TMDB 桩：搜索 / 图集 / 指定条目详情各给一份，并记录全部请求。
private actor TMDBMatchStub: HTTPTransport {
    private var requests: [String] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        requests.append(url)
        if url.contains("/search/multi") {
            return HTTPResponse(status: 200, headers: [:], body: Data(Self.searchBody.utf8))
        }
        if url.contains("/images") {
            return HTTPResponse(status: 200, headers: [:], body: Data(Self.imagesBody.utf8))
        }
        if url.contains("/movie/603") {
            return HTTPResponse(status: 200, headers: [:], body: Data(Self.detailBody.utf8))
        }
        return HTTPResponse(status: 404)
    }

    func requestCount(matching fragment: String) -> Int {
        requests.filter { $0.contains(fragment) }.count
    }

    private static let searchBody = """
    {"results":[{"id":1,"media_type":"tv","name":"自动搜到的","overview":"","poster_path":"/p.jpg","backdrop_path":"/b.jpg","genre_ids":[]}]}
    """

    private static let detailBody = """
    {"id":603,"title":"手动指定的电影","overview":"手动简介","poster_path":"/p2.jpg","backdrop_path":"/b2.jpg","genres":[{"id":16}]}
    """

    private static let imagesBody = #"{"backdrops":[{"file_path":"/x1.jpg"}]}"#
}

/// 手动匹配元信息（M11 片 5）的接线：选定的那一条真的替代了自动搜索，且落盘、能恢复。
@Suite("手动匹配元信息接线")
@MainActor
struct TMDBMatchWiringTests {
    private func makeConfigured() throws -> (fixture: AppModelFixture, stub: TMDBMatchStub) {
        let stub = TMDBMatchStub()
        let fixture = try AppModelFixture(tmdbTransport: stub)
        fixture.model.tmdbConfig = TMDBConfig(apiKey: "k", imageProxy: "")
        return (fixture, stub)
    }

    @Test("指定了手动匹配就不再搜：直接取那一条的详情")
    func manualMatchSkipsSearch() async throws {
        let (fixture, stub) = try makeConfigured()
        defer { fixture.tearDown() }

        fixture.model.setTMDBMatchKey(TMDBMatchKey(kind: .movie, id: 603), for: "仙逆")
        let outcome = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)

        guard case let .found(bundle) = outcome else {
            Issue.record("指定了手动匹配就该拿到详情")
            return
        }
        #expect(bundle.metadata.title == "手动指定的电影")
        #expect(bundle.metadata.id == 603)
        #expect(bundle.metadata.isAnimation)
        let searches = await stub.requestCount(matching: "/search/multi")
        // 带 `?` 才是详情那一次：`/movie/603/images` 也含 `/movie/603`（第一版这里就数错了）。
        let detailRounds = await stub.requestCount(matching: "/movie/603?")
        let backdropRounds = await stub.requestCount(matching: "/movie/603/images")
        #expect(searches == 0)
        #expect(detailRounds == 1)
        #expect(backdropRounds == 1)
    }

    @Test("改手动匹配会作废会话缓存：下一轮不再拿旧的自动结果")
    func settingMatchInvalidatesCache() async throws {
        let (fixture, _) = try makeConfigured()
        defer { fixture.tearDown() }

        let automatic = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)
        guard case let .found(autoBundle) = automatic else {
            Issue.record("先该自动搜到")
            return
        }
        #expect(autoBundle.metadata.title == "自动搜到的")

        fixture.model.setTMDBMatchKey(TMDBMatchKey(kind: .movie, id: 603), for: "仙逆")
        let manual = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)
        guard case let .found(manualBundle) = manual else {
            Issue.record("换了手动匹配就该拿详情")
            return
        }
        #expect(manualBundle.metadata.title == "手动指定的电影")
    }

    @Test("恢复自动匹配：回到搜索那条路")
    func clearingMatchGoesBackToSearch() async throws {
        let (fixture, stub) = try makeConfigured()
        defer { fixture.tearDown() }

        fixture.model.setTMDBMatchKey(TMDBMatchKey(kind: .movie, id: 603), for: "仙逆")
        _ = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)

        fixture.model.setTMDBMatchKey(nil, for: "仙逆")
        let outcome = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)

        guard case let .found(bundle) = outcome else {
            Issue.record("恢复自动后该能搜到")
            return
        }
        #expect(bundle.metadata.title == "自动搜到的")
        let searches = await stub.requestCount(matching: "/search/multi")
        #expect(searches == 1)
    }

    @Test("落盘：重开模型手动匹配还在，加载键 token 随之变化")
    func matchPersistsAndMovesLoadKey() throws {
        let (fixture, _) = try makeConfigured()
        defer { fixture.tearDown() }

        #expect(fixture.model.tmdbMatchToken(for: "仙逆") == "auto")
        fixture.model.setTMDBMatchKey(TMDBMatchKey(kind: .tv, id: 42), for: "仙逆")
        #expect(fixture.model.tmdbMatchToken(for: "仙逆") == "tv:42")

        let reopened = try fixture.reopenedModel()
        #expect(reopened.tmdbMatchToken(for: "仙逆") == "tv:42")
        #expect(reopened.tmdbMatchBook.key(for: "仙逆") == TMDBMatchKey(kind: .tv, id: 42))
    }

    @Test("搜候选：面板要的是原始候选列表（电影与剧集都在）")
    func searchCandidatesReturnRawList() async throws {
        let (fixture, _) = try makeConfigured()
        defer { fixture.tearDown() }

        let results = try await fixture.model.tmdbSearchCandidates("仙逆")
        #expect(results.count == 1)
        #expect(results.first?.id == 1)
    }
}
