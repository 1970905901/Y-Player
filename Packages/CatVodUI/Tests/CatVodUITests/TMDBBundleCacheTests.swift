import CatVodNet
import CatVodSource
@testable import CatVodUI
import Foundation
import Testing

/// 按路径分发的 TMDB 桩：搜索与图集各给一份 JSON，并记录全部请求。
private actor TMDBRoutingStub: HTTPTransport {
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
        return HTTPResponse(status: 404)
    }

    func requestCount(matching fragment: String) -> Int {
        requests.filter { $0.contains(fragment) }.count
    }

    private static let searchBody = """
    {"results":[{"id":1,"media_type":"tv","name":"仙逆","overview":"凡人修仙","poster_path":"/p.jpg","backdrop_path":"/b.jpg","genre_ids":[16]}]}
    """

    private static let imagesBody = #"{"backdrops":[{"file_path":"/x1.jpg"},{"file_path":"/x2.jpg"}]}"#
}

/// 元信息缓存与合流（M11「选集卡片接图」的地基）：顶部与卡片共用的那一份怎么存取。
@Suite("TMDB 元信息缓存与合流")
@MainActor
struct TMDBBundleCacheTests {
    /// 配好 key 的夹具 + 桩：不走网、不发真请求。
    private func makeConfigured() throws -> (fixture: AppModelFixture, stub: TMDBRoutingStub) {
        let stub = TMDBRoutingStub()
        let fixture = try AppModelFixture(tmdbTransport: stub)
        fixture.model.tmdbConfig = TMDBConfig(apiKey: "k", imageProxy: "")
        return (fixture, stub)
    }

    @Test("缓存命中：同片名同模式第二次不发请求")
    func cacheHitsAvoidSecondRound() async throws {
        let (fixture, stub) = try makeConfigured()
        defer { fixture.tearDown() }

        let first = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)
        let second = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)

        guard case let .found(a) = first, case let .found(b) = second else {
            Issue.record("两次都该命中")
            return
        }
        #expect(a.metadata.title == "仙逆")
        #expect(b.posterSet.urls == a.posterSet.urls)
        let searches = await stub.requestCount(matching: "/search/multi")
        let imageRounds = await stub.requestCount(matching: "/images")
        #expect(searches == 1)
        #expect(imageRounds == 1)
    }

    @Test("并发合流：同时要同一片只发一轮请求")
    func concurrentCallsCoalesce() async throws {
        let (fixture, stub) = try makeConfigured()
        defer { fixture.tearDown() }

        async let first = fixture.model.tmdbBundle(for: "仙逆", mode: .rotate)
        async let second = fixture.model.tmdbBundle(for: "仙逆", mode: .rotate)
        async let third = fixture.model.tmdbBundle(for: "仙逆", mode: .rotate)
        let firstOutcome = await first
        let secondOutcome = await second
        let thirdOutcome = await third
        let outcomes = [firstOutcome, secondOutcome, thirdOutcome]

        let foundCount = outcomes.filter { outcome in
            if case .found = outcome {
                return true
            }
            return false
        }.count
        let searches = await stub.requestCount(matching: "/search/multi")
        #expect(foundCount == 3)
        #expect(searches == 1)
    }

    @Test("模式不同：重建取图集（缓存里换成新模式的）")
    func modeMismatchRefetches() async throws {
        let (fixture, stub) = try makeConfigured()
        defer { fixture.tearDown() }

        _ = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)
        let rotated = await fixture.model.tmdbBundle(for: "仙逆", mode: .rotate)

        guard case let .found(bundle) = rotated else {
            Issue.record("换模式后仍该拿到结果")
            return
        }
        #expect(bundle.mode == .rotate)
        let searches = await stub.requestCount(matching: "/search/multi")
        #expect(searches == 2)
    }

    @Test("没配 key / 刮削关：不发请求，状态说清")
    func guardsReturnStates() async throws {
        let stub = TMDBRoutingStub()
        let fixture = try AppModelFixture(tmdbTransport: stub)
        defer { fixture.tearDown() }

        let unconfigured = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)
        guard case .notConfigured = unconfigured else {
            Issue.record("没配 key 应给 notConfigured")
            return
        }

        fixture.model.tmdbConfig = TMDBConfig(apiKey: "k", imageProxy: "")
        fixture.model.tmdbScrapeEnabled = false
        let disabled = await fixture.model.tmdbBundle(for: "仙逆", mode: .fixed)
        guard case .disabled = disabled else {
            Issue.record("刮削关应给 disabled")
            return
        }

        let total = await stub.requestCount(matching: "")
        #expect(total == 0)
    }
}
