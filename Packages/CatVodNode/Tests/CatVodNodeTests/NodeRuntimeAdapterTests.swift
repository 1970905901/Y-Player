#if os(macOS)
import Foundation
import Testing

@testable import CatVodNode

/// 用 `/bin/sh` 冒充 node：
/// 脚本文件名固定为 `index.js`（满足自启动契约的文件名条件），可执行文件由 `executableOverride` 指定，
/// 这样就能在 CI 上**真实**跑通「进程启动 → 读 stdout → 解析就绪行 → 超时 / 早退」整条宿主链路。
private func makeScript(_ body: String) throws -> (directory: URL, script: URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("yplayer-node-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("index.js")
    try body.write(to: script, atomically: true, encoding: .utf8)
    return (directory, script)
}

private func makeAdapter(
    script: URL,
    preferredPort: Int = 19771,
    timeout: TimeInterval = 8
) -> NodeRuntimeAdapter {
    NodeRuntimeAdapter(configuration: NodeRuntimeConfiguration(
        scriptURL: script,
        preferredPort: preferredPort,
        readinessTimeout: timeout,
        executableOverride: URL(fileURLWithPath: "/bin/sh")
    ))
}

@Suite("Node 宿主适配（macOS 进程链路）")
struct NodeRuntimeAdapterTests {
    @Test("就绪行给出实际端口，baseURL 指向回环地址")
    func readsReadinessFromRealProcess() async throws {
        let (directory, script) = try makeScript("""
        #!/bin/sh
        echo "messageToDart queryProfile"
        echo "CatVodSpiderios listening on http://127.0.0.1:${DEV_HTTP_PORT:-0}"
        sleep 5
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = makeAdapter(script: script, preferredPort: 19801)
        let url = try await adapter.start()
        // 端口由脚本读 DEV_HTTP_PORT 打印 → 同时验证了环境变量注入确实生效
        #expect(url.absoluteString == "http://127.0.0.1:19801")

        let status = await adapter.status()
        #expect(status.isReady)
        #expect(status.port == 19801)

        await adapter.stop()
        let stopped = await adapter.status()
        #expect(!stopped.isRunning)
        #expect(!stopped.isReady)
    }

    @Test("没有就绪行时按超时结束，并附带最近输出")
    func timesOutWithOutput() async throws {
        let (directory, script) = try makeScript("""
        #!/bin/sh
        echo "starting up"
        sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = makeAdapter(script: script, timeout: 1)
        do {
            _ = try await adapter.start()
            Issue.record("应当抛出就绪超时")
        } catch let error as NodeRuntimeError {
            guard case let .readinessTimeout(seconds, output) = error else {
                Issue.record("错误类型不符：\(error)")
                await adapter.stop()
                return
            }
            #expect(seconds == 1)
            #expect(output.contains("starting up"))
        }
        await adapter.stop()
    }

    @Test("就绪前退出：报出退出码与输出")
    func exitsBeforeReady() async throws {
        let (directory, script) = try makeScript("""
        #!/bin/sh
        echo "bundle failed to start" 1>&2
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = makeAdapter(script: script, timeout: 8)
        do {
            _ = try await adapter.start()
            Issue.record("应当抛出「就绪前退出」错误")
        } catch let error as NodeRuntimeError {
            guard case let .exitedBeforeReady(code, output) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(code == 3)
            #expect(output.contains("bundle failed to start"))
        }
    }

    @Test("脚本名不满足自启动契约时直接拒绝（不启动进程）")
    func rejectsNonIndexScript() async throws {
        let (directory, script) = try makeScript("#!/bin/sh\necho hi\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let renamed = script.deletingLastPathComponent().appendingPathComponent("bundle.js")
        try FileManager.default.moveItem(at: script, to: renamed)

        let adapter = makeAdapter(script: renamed)
        do {
            _ = try await adapter.start()
            Issue.record("应当抛出配置错误")
        } catch let error as NodeRuntimeError {
            guard case .invalidConfiguration = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }
}
#endif
