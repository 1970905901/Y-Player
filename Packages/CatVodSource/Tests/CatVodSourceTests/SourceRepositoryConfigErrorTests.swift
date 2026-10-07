import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 真机踩坑回归（2026-10-07）：把 `index.js.md5` 当接口填进去，原来会得到
/// `配置不可用：配置不是合法 JSON：dataCorrupted(…)` 这种毫无线索的报错。
///
/// 对齐参考实现（webhtv `NodeBundle`）后，`.js.md5` 是**正规输入**：
/// 归一化成 `.js` 下载、bundle 固定落盘成 `index.js`，不需要也不该有任何"已纠正"告警。
@Suite("源配置加载：正规输入与可读的失败说明")
struct SourceRepositoryConfigErrorTests {
    private let jsURL = "https://9280.kstore.vip/ceshi/index.js"

    @Test("填 index.js.md5（正规输入）：按去掉 .md5 的地址下载，落盘为 index.js")
    func digestInputIsAccepted() async throws {
        let bundle = Data(repeating: 0x41, count: 4096)
        let stub = StubTransport(responses: [
            jsURL + ".md5": (200, Data(MD5.hexDigest(of: bundle).utf8)),
            jsURL: (200, bundle),
        ])
        let repository = try SourceRepository(transport: stub, cacheDirectory: makeTempDirectory())

        let loaded = try await repository.load(configURL: jsURL + ".md5")

        #expect(loaded.kind == .javaScript)
        #expect(loaded.originURL?.absoluteString == jsURL)
        // 参考实现把 bundle 固定存成 index.js：bundle 靠 argv[1] 结尾判断是否自启动
        #expect(loaded.cachedURL?.lastPathComponent == ConfigLocator.scriptFileName)
        let cacheDirectoryName = loaded.cachedURL?.deletingLastPathComponent().lastPathComponent ?? ""
        #expect(cacheDirectoryName.hasPrefix("bundle-"))
        #expect(loaded.digest == MD5.hexDigest(of: bundle))
    }

    @Test("普通 .md5 地址返回摘要文本：给出去哪找正确地址的说明")
    func digestBodyGivesActionableMessage() async throws {
        let url = "https://example.com/tvbox/config.md5"
        let digest = "35dcc10d533153dbb94298792664ad04"
        let repository = try SourceRepository(
            transport: StubTransport(responses: [url: (200, Data(digest.utf8))]),
            cacheDirectory: makeTempDirectory()
        )

        do {
            _ = try await repository.load(configURL: url)
            Issue.record("应当抛出配置错误")
        } catch let error as CatVodError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("MD5 校验文本"))
            #expect(text.contains("index.js"))
            // 不再把 DecodingError 原文甩给用户。
            #expect(!text.contains("dataCorrupted"))
        }
    }

    @Test("远端返回 JS 脚本（地址没以 .js 结尾）：提示确认扩展名")
    func scriptBodyGivesHint() async throws {
        let url = "https://example.com/tvbox/config"
        let body = Data("!function(){console.log(1)}()".utf8)
        let repository = try SourceRepository(
            transport: StubTransport(responses: [url: (200, body)]),
            cacheDirectory: makeTempDirectory()
        )

        do {
            _ = try await repository.load(configURL: url)
            Issue.record("应当抛出配置错误")
        } catch let error as CatVodError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("JS 脚本"))
            #expect(text.contains(".js"))
        }
    }
}
