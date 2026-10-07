import CatVodNet
import CatVodSource
import XCTest

/// 内嵌 Node（libnode）在**真实 iOS 运行时**里的确定性验证 —— M16P4 第 1、2、5 项。
///
/// 为什么不再拿 6.29 MB 的真 bundle 当主线：它把「libnode 能不能用」和
/// 「远端 bundle 今天是否正常 + 它用到的 Node API iOS 版是否支持」混在一个用例里，
/// 一旦出事只会以「进程消失」呈现，无法定位。改成自写的最小 bundle 后，
/// 这条用例只回答一个问题：**我们的宿主链路在真 iOS 上能不能跑通**。
///
/// 顺带回答另外两件事：
/// - 环境变量真的注入了吗？最小 bundle 的端口**只**来自 `DEV_HTTP_PORT`；
/// - 容器临时目录里的脚本 node 读得到吗？（真机 Bundle 不可写，脚本必须落在容器里）
final class EmbeddedNodeHostTests: XCTestCase {
    func testHostStartsServesCatalogAndCapturesReadiness() async throws {
        let scriptURL = try MiniBundleScript.materialize()
        NodeProbeSupport.step("mini bundle written: \(scriptURL.path)")

        let service = JS2PHostService(
            transport: URLSessionTransport(),
            scriptURL: scriptURL,
            readinessTimeout: 30
        )

        NodeProbeSupport.step("host starting")
        let snapshot: HostConfigSnapshot
        do {
            snapshot = try await service.sites()
        } catch {
            let output = await service.recentOutput(limit: 40)
            let log = await NodeProbeSupport.logTail(of: service)
            XCTFail(
                """
                内嵌 Node 未能就绪：\(error)
                --- 宿主输出 ---
                \(output.joined(separator: "\n"))
                --- 落盘日志 ---
                \(log.joined(separator: "\n"))
                """
            )
            return
        }
        NodeProbeSupport.step("host ready")

        // 站点清单能取到，就证明「就绪行 -> 端口 -> baseURL -> HTTP」整条链是通的。
        XCTAssertEqual(snapshot.sites.count, 1, "最小 bundle 只声明一个站点")
        let site = try XCTUnwrap(snapshot.sites.first)
        XCTAssertEqual(site.key, "nodejs_probe")
        XCTAssertTrue(site.isCatSpiderHTTP, "相对 api 必须被补成含 /spider/ 的绝对地址")
        XCTAssertTrue(site.api.hasPrefix("http://127.0.0.1:"), "宿主模式下 api 必须指向本机宿主")

        // 就绪行本身也要能从捕获到的 stdout 里看到（文案与 docs/js2p宿主契约.md 一致）。
        let output = await service.recentOutput(limit: 40)
        XCTAssertTrue(
            output.contains { $0.contains("CatVodSpiderios listening on") },
            "stdout 捕获里应包含就绪行；最近输出：\(output.suffix(6))"
        )

        NodeProbeSupport.step("assertions done")
        // iOS 上 stop() 只断开日志采集（node_start 不可逆），这里只确认不崩。
        await service.stop()
        // fd 还原之后再回读落盘日志：这样成功路径也能在 CI 里看到完整步骤序列。
        NodeProbeSupport.dumpProbeLog()
    }
}
