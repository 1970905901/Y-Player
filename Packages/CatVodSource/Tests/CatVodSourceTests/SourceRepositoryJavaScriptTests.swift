import CatVodCore
@testable import CatVodSource
import Foundation
import Testing

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
