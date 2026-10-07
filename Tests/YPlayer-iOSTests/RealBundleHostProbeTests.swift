import CatVodNet
import CatVodSource
import XCTest

/// 真 bundle（6.29 MB 的 `index.js`）端到端探针：**默认跳过**，需 `YPLAYER_NODE_PROBE=real-bundle`。
///
/// 单独成类、并且允许失败（CI 里 `continue-on-error`），原因是一次真实事故：
/// 模拟器上它跑到下载完成后 **13.5 秒**测试进程就消失了，XCTest 只留下
/// `Restarting after unexpected exit, crash, or test timeout`。
/// 这类「进程级失败」不能当作主线的红灯依据 —— 主线跑 `EmbeddedNodeHostTests`；
/// 这里负责回答「真 bundle 在 iOS 上到底能不能跑」，拿不到结论时也不能挡住别的验证。
///
/// 预载脚本（``CatVodNode/NodePreloadScript``）会把致命错误写成落盘日志，
/// 所以即便进程再次消失，也能从宿主日志里读到原因。
final class RealBundleHostProbeTests: XCTestCase {
    func testRealBundleReturnsSites() async throws {
        let mode = ProcessInfo.processInfo.environment["YPLAYER_NODE_PROBE"]
        guard mode == "real-bundle" else {
            throw XCTSkip("未设置 YPLAYER_NODE_PROBE=real-bundle：默认不跑（需要外网与完整 libnode 能力）")
        }

        let scriptURL = try await RealBundleFixture.localIndexJS()
        NodeProbeSupport.step("real bundle ready: \(scriptURL.path)")

        let service = JS2PHostService(
            transport: URLSessionTransport(),
            scriptURL: scriptURL,
            readinessTimeout: 120
        )

        NodeProbeSupport.step("host starting")
        let snapshot: HostConfigSnapshot
        do {
            snapshot = try await service.sites()
        } catch {
            let output = await service.recentOutput(limit: 60)
            let log = await NodeProbeSupport.logTail(of: service, lines: 60)
            XCTFail(
                """
                真 bundle 的宿主未能就绪：\(error)
                --- 宿主输出 ---
                \(output.joined(separator: "\n"))
                --- 落盘日志（关键：模块可用性与致命错误都在这里）---
                \(log.joined(separator: "\n"))
                --- 探针日志（落盘；宿主启动之后的步骤进不了 CI 日志，只有这里有）---
                \(NodeProbeSupport.probeLogText())
                """
            )
            return
        }
        NodeProbeSupport.step("host ready: \(snapshot.sites.count) sites")

        XCTAssertGreaterThan(snapshot.sites.count, 0, "真实宿主应至少给出一个站点")
        let first = try XCTUnwrap(snapshot.sites.first)
        XCTAssertFalse(first.key.isEmpty)
        XCTAssertTrue(first.isCatSpiderHTTP, "api 应形如 http://127.0.0.1:<port>/spider/...")

        await service.stop()
        NodeProbeSupport.dumpProbeLog()
    }
}
