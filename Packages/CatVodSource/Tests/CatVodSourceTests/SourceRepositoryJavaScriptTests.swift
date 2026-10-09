import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 会「换版本」的桩：同一个地址先后给不同响应 —— 用来验上游发新版那条路。
///
/// 没用共享的 `StubTransport`：那个的响应表在 init 时就固定了，模拟不了「版本变了」。
private actor UpdatingStub: HTTPTransport {
    private var responses: [String: (Int, Data)]

    init(_ initial: [String: (Int, Data)]) {
        responses = initial
    }

    func update(_ url: String, body: Data) {
        responses[url] = (200, body)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let entry = responses[request.url.absoluteString] else {
            throw CatVodError.network(status: 404, url: request.url.absoluteString, reason: "no stub")
        }
        return HTTPResponse(status: entry.0, body: entry.1)
    }
}

@Suite("js2p 增量更新")
struct SourceRepositoryJavaScriptTests {
    private let jsURL = "https://9280.kstore.vip/ceshi/index.js"

    @Test("首次下载并校验摘要；二次命中缓存，只请求摘要不重下 bundle")
    func cacheHitSkipsBundleDownload() async throws {
        let directory = try makeTempDirectory()
        let bundle = Data(repeating: 0x41, count: 1024)
        let digest = MD5.hexDigest(of: bundle)
        let stub = StubTransport(responses: [
            jsURL + ".md5": (200, Data(digest.utf8)),
            jsURL: (200, bundle),
        ])
        let repository = SourceRepository(transport: stub, cacheDirectory: directory)

        let first = try await repository.load(configURL: jsURL)
        #expect(first.kind == .javaScript)
        #expect(first.digest == digest)
        #expect(!first.usedCache)
        #expect(first.warnings.contains { $0.contains("Node") })
        let afterFirst = await stub.requestCount()

        let second = try await repository.load(configURL: jsURL)
        #expect(second.usedCache)
        #expect(second.digest == digest)
        let secondRoundRequests = await stub.requestCount() - afterFirst
        // 命中缓存时只有 1 次请求（摘要文件），不会重新下载 6 MB bundle
        #expect(secondRoundRequests == 1)
    }

    @Test("摘要不一致时拒绝写入缓存")
    func digestMismatchRejected() async throws {
        let directory = try makeTempDirectory()
        let stub = StubTransport(responses: [
            jsURL + ".md5": (200, Data(MD5.hexDigest(of: "expected").utf8)),
            jsURL: (200, Data("tampered".utf8)),
        ])
        let repository = SourceRepository(transport: stub, cacheDirectory: directory)
        await #expect(throws: CatVodError.self) {
            _ = try await repository.load(configURL: jsURL)
        }
    }

    @Test("源缓存时间设成「永不」也不跳过 .md5 校验（拿不到摘要才回退缓存）")
    func neverExpiringCacheStillVerifiesDigest() async throws {
        let directory = try makeTempDirectory()
        let bundle = Data(repeating: 0x43, count: 256)
        let digest = MD5.hexDigest(of: bundle)
        let stub = StubTransport(responses: [
            jsURL + ".md5": (200, Data(digest.utf8)),
            jsURL: (200, bundle),
        ])
        let repository = SourceRepository(transport: stub, cacheDirectory: directory)

        _ = try await repository.load(configURL: jsURL)
        let afterFirst = await stub.requestCount()

        // 「永不失效」在这里**不成立**：JS 源不给「纯本地」结论，必须去校验摘要。
        let cachedShortcut = try await repository.loadCached(configURL: jsURL, maxAge: nil)
        #expect(cachedShortcut == nil)

        // 走校验那条路：摘要一致 → 命中缓存，只请求了摘要，没重下 bundle。
        let second = try await repository.load(configURL: jsURL)
        #expect(second.usedCache)
        let secondRound = await stub.requestCount() - afterFirst
        #expect(secondRound == 1)
    }

    @Test("上游发了新 bundle：自动重下（旧版本卡住的那条路）")
    func changedDigestDownloadsNewBundle() async throws {
        let directory = try makeTempDirectory()
        let oldBundle = Data(repeating: 0x44, count: 256)
        let newBundle = Data(repeating: 0x45, count: 512)
        let stub = UpdatingStub([
            jsURL + ".md5": (200, Data(MD5.hexDigest(of: oldBundle).utf8)),
            jsURL: (200, oldBundle),
        ])
        let repository = SourceRepository(transport: stub, cacheDirectory: directory)
        let first = try await repository.load(configURL: jsURL)
        #expect(!first.usedCache)

        // 上游换版本：摘要与内容都变。
        await stub.update(jsURL + ".md5", body: Data(MD5.hexDigest(of: newBundle).utf8))
        await stub.update(jsURL, body: newBundle)

        let updated = try await repository.load(configURL: jsURL)
        #expect(!updated.usedCache)
        #expect(updated.digest == MD5.hexDigest(of: newBundle))
        let written = try Data(contentsOf: #require(updated.cachedURL))
        #expect(written == newBundle)
    }

    @Test("forceRefresh 强制重新下载")
    func forceRefresh() async throws {
        let directory = try makeTempDirectory()
        let bundle = Data(repeating: 0x42, count: 512)
        let stub = StubTransport(responses: [
            jsURL + ".md5": (200, Data(MD5.hexDigest(of: bundle).utf8)),
            jsURL: (200, bundle),
        ])
        let repository = SourceRepository(transport: stub, cacheDirectory: directory)
        _ = try await repository.load(configURL: jsURL)

        let refreshed = try await repository.load(configURL: jsURL, forceRefresh: true)
        #expect(!refreshed.usedCache)
        #expect(refreshed.digest == MD5.hexDigest(of: bundle))
    }
}
