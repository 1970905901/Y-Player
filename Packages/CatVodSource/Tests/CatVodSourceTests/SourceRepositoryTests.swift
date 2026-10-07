import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 按 URL 返回预设响应的传输层（同模块测试共享）。
actor StubTransport: HTTPTransport {
    private let responses: [String: (Int, Data)]
    private(set) var requested: [String] = []

    init(responses: [String: (Int, Data)]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requested.append(request.url.absoluteString)
        guard let entry = responses[request.url.absoluteString] else {
            throw CatVodError.network(status: 404, url: request.url.absoluteString, reason: "no stub")
        }
        return HTTPResponse(status: entry.0, body: entry.1)
    }

    func requestCount() -> Int {
        requested.count
    }
}

/// 创建临时缓存目录。
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("yplayer-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 测试用最小 JSON 配置。
let sampleJSONConfig = #"{"sites":[{"key":"cms","name":"CMS","type":1,"api":"https://api.example.com/vod"}]}"#

@Suite("源配置加载：JSON 通道")
struct SourceRepositoryTests {
    @Test("联网加载并落地缓存")
    func jsonLoad() async throws {
        let directory = try makeTempDirectory()
        let url = "https://cfg.example.com/config.json"
        let repository = SourceRepository(
            transport: StubTransport(responses: [url: (200, Data(sampleJSONConfig.utf8))]),
            cacheDirectory: directory
        )

        let loaded = try await repository.load(configURL: url)
        #expect(loaded.kind == .json)
        #expect(loaded.config.sites.count == 1)
        #expect(loaded.config.resolvedHomeSite?.key == "cms")
        #expect(!loaded.usedCache)

        let cached = try #require(loaded.cachedURL)
        #expect(FileManager.default.fileExists(atPath: cached.path))
    }

    @Test("网络失败退回缓存并给出告警")
    func jsonOfflineFallback() async throws {
        let directory = try makeTempDirectory()
        let url = "https://cfg.example.com/config.json"
        let online = SourceRepository(
            transport: StubTransport(responses: [url: (200, Data(sampleJSONConfig.utf8))]),
            cacheDirectory: directory
        )
        _ = try await online.load(configURL: url)

        // 第二次：网络完全不可用（无任何 stub）
        let offline = SourceRepository(transport: StubTransport(responses: [:]), cacheDirectory: directory)
        let loaded = try await offline.load(configURL: url)
        #expect(loaded.usedOfflineFallback)
        #expect(loaded.config.sites.count == 1)
        #expect(loaded.warnings.contains { $0.contains("本地缓存配置") })
    }

    @Test("msg 非空视为错误响应")
    func errorResponse() async throws {
        let directory = try makeTempDirectory()
        let url = "https://cfg.example.com/bad.json"
        let repository = SourceRepository(
            transport: StubTransport(responses: [url: (200, Data(#"{"msg":"配置已失效","sites":[]}"#.utf8))]),
            cacheDirectory: directory
        )
        await #expect(throws: CatVodError.self) {
            _ = try await repository.load(configURL: url)
        }
    }

    @Test("内联 JSON 直接解析，不落盘")
    func inlineConfig() async throws {
        let directory = try makeTempDirectory()
        let repository = SourceRepository(transport: StubTransport(responses: [:]), cacheDirectory: directory)
        let loaded = try await repository.load(configURL: sampleJSONConfig)
        #expect(loaded.kind == .json)
        #expect(loaded.originURL == nil)
        #expect(loaded.config.sites.count == 1)
    }
}
