import CatVodCore
import CatVodNet
import CatVodNode
@testable import CatVodSource
import Foundation
import Testing

/// 假运行时：可控地模拟「就绪 / 启动失败」，并记录 start/stop 次数。
actor FakeNodeRuntime: NodeRuntimeLaunching {
    enum Behavior: Sendable {
        case ready(URL)
        case failure(reason: String)
    }

    private let behavior: Behavior
    private let output: [String]
    private var startCount = 0
    private var stopCount = 0

    init(behavior: Behavior, output: [String] = []) {
        self.behavior = behavior
        self.output = output
    }

    func start() async throws -> URL {
        startCount += 1
        switch behavior {
        case let .ready(url):
            return url
        case let .failure(reason):
            throw FakeRuntimeFailure(reason: reason)
        }
    }

    func stop() async {
        stopCount += 1
    }

    func recentOutput(limit: Int) async -> [String] {
        Array(output.suffix(max(limit, 0)))
    }

    func counts() -> (start: Int, stop: Int) {
        (startCount, stopCount)
    }
}

/// 测试用错误（不动用 `CatVodNode` 的具体错误类型，保持测试 target 只依赖被测模块）。
struct FakeRuntimeFailure: Error, LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? {
        reason
    }
}

/// 按路径返回不同响应的假传输层：会话测试必须区分 `/health` 与 `/full-config`。
actor RoutedTransport: HTTPTransport {
    private let responses: [String: HTTPResponse]
    private var requestedPaths: [String] = []

    init(responses: [String: HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestedPaths.append(request.url.path)
        return responses[request.url.path] ?? HTTPResponse(status: 404, body: Data())
    }

    func paths() -> [String] {
        requestedPaths
    }
}

/// 与 M16P2 实测一致的宿主载荷（裁剪为 2 条：相对 api + 绝对 api）。
let hostSitesFixture = #"""
{
  "video": {
    "sites": [
      {
        "key": "nodejs_douban", "name": "豆瓣|首页", "type": 3, "indexs": 1,
        "enable": true, "searchable": 1, "quickSearch": 1, "api": "/spider/douban/3"
      },
      {
        "key": "legacy_abs", "name": "绝对地址", "type": 3,
        "enable": true, "api": "http://example.com/spider/x/3"
      }
    ]
  },
  "color": []
}
"""#

/// 便捷构造：健康响应 + 站点载荷。
func hostResponses(
    health: String = #"{"ok":true,"name":"CatVodSpiderios"}"#,
    healthStatus: Int = 200,
    config: String = hostSitesFixture,
    configStatus: Int = 200
) -> [String: HTTPResponse] {
    [
        "/health": HTTPResponse(status: healthStatus, body: Data(health.utf8)),
        "/full-config": HTTPResponse(status: configStatus, body: Data(config.utf8)),
    ]
}

@Suite("js2p 宿主会话（起 Node → 探活 → 取站点）")
struct JS2PHostServiceTests {
    private static func baseURL() throws -> URL {
        try #require(URL(string: "http://127.0.0.1:9988"))
    }

    private func readyRuntime(output: [String] = []) throws -> FakeNodeRuntime {
        FakeNodeRuntime(behavior: .ready(Self.baseURL()), output: output)
    }

    private func makeService(
        runtime: FakeNodeRuntime,
        responses: [String: HTTPResponse] = hostResponses()
    ) -> (JS2PHostService, RoutedTransport) {
        let transport = RoutedTransport(responses: responses)
        let script = URL(fileURLWithPath: "/tmp/index.js")
        let service = JS2PHostService(transport: transport, scriptURL: script, runtime: runtime)
        return (service, transport)
    }

    @Test("取站点：启动宿主 → 探活 → 补全相对 api")
    func loadsSites() async throws {
        let runtime = try readyRuntime()
        let (service, transport) = makeService(runtime: runtime)

        let snapshot = try await service.sites()

        #expect(snapshot.sites.count == 2)
        #expect(snapshot.disabledSiteCount == 0)

        let douban = try #require(snapshot.sites.first { $0.key == "nodejs_douban" })
        #expect(douban.api == "http://127.0.0.1:9988/spider/douban/3")

        let absolute = try #require(snapshot.sites.first { $0.key == "legacy_abs" })
        #expect(absolute.api == "http://example.com/spider/x/3")

        let baseURL = await service.currentBaseURL()
        #expect(baseURL?.absoluteString == "http://127.0.0.1:9988")

        // 先探活再取清单：顺序本身是契约的一部分（就绪行 ≠ 应用层可用）。
        let paths = await transport.paths()
        #expect(paths == ["/health", "/full-config"])

        let counts = await runtime.counts()
        #expect(counts.start == 1)
    }

    @Test("重复取站点只启动一次宿主（幂等）")
    func startIsIdempotent() async throws {
        let runtime = try readyRuntime()
        let (service, _) = makeService(runtime: runtime)

        _ = try await service.sites()
        _ = try await service.sites()
        _ = try await service.start()

        let counts = await runtime.counts()
        #expect(counts.start == 1)
        #expect(counts.stop == 0)
    }

    @Test("forceRestartHost：先停再起")
    func forceRestart() async throws {
        let runtime = try readyRuntime()
        let (service, _) = makeService(runtime: runtime)

        _ = try await service.sites()
        _ = try await service.sites(forceRestartHost: true)

        let counts = await runtime.counts()
        #expect(counts.start == 2)
        #expect(counts.stop == 1)
    }

    @Test("就绪行出现但探活不过：抛 hostNotReady，并附宿主输出")
    func healthGate() async throws {
        let runtime = try readyRuntime(output: ["Server listening at http://0.0.0.0:9988", "boom"])
        let (service, _) = makeService(runtime: runtime, responses: hostResponses(health: #"{"ok":false}"#))

        do {
            _ = try await service.start()
            Issue.record("应当抛出 hostNotReady")
        } catch let error as JS2PHostError {
            guard case let .hostNotReady(message) = error else {
                Issue.record("错误分支不符：\(error)")
                return
            }
            #expect(message.contains("GET /health"))
            #expect(message.contains("boom"))
        }

        let baseURL = await service.currentBaseURL()
        #expect(baseURL == nil)
    }

    @Test("启动失败：抛 runtimeUnavailable，并附最近输出")
    func launchFailure() async throws {
        let runtime = FakeNodeRuntime(
            behavior: .failure(reason: "未找到 node 可执行文件"),
            output: ["no node here"]
        )
        let (service, _) = makeService(runtime: runtime)

        do {
            _ = try await service.start()
            Issue.record("应当抛出 runtimeUnavailable")
        } catch let error as JS2PHostError {
            guard case let .runtimeUnavailable(message) = error else {
                Issue.record("错误分支不符：\(error)")
                return
            }
            #expect(message.contains("未找到 node 可执行文件"))
            #expect(message.contains("no node here"))
        }

        let counts = await runtime.counts()
        #expect(counts.start == 1)
    }

    @Test("站点请求失败：抛 sitesUnavailable")
    func sitesFailure() async throws {
        let runtime = try readyRuntime()
        let (service, _) = makeService(
            runtime: runtime,
            responses: hostResponses(configStatus: 500)
        )

        do {
            _ = try await service.sites()
            Issue.record("应当抛出 sitesUnavailable")
        } catch let error as JS2PHostError {
            guard case .sitesUnavailable = error else {
                Issue.record("错误分支不符：\(error)")
                return
            }
        }
    }

    @Test("stop 后 baseURL 清空，可再次启动")
    func stopAndRestart() async throws {
        let runtime = try readyRuntime()
        let (service, _) = makeService(runtime: runtime)

        _ = try await service.start()
        await service.stop()

        let afterStop = await service.currentBaseURL()
        #expect(afterStop == nil)
        let healthAfterStop = await service.health()
        #expect(healthAfterStop == false)

        _ = try await service.start()
        let counts = await runtime.counts()
        #expect(counts.start == 2)
        #expect(counts.stop == 1)
    }
}
