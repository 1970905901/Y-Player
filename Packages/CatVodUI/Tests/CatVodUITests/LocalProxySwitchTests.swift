import CatVodNet
@testable import CatVodUI
import Foundation
import Testing

/// 本地代理开关 ↔ 本机服务的对账（M06o）。
///
/// 为什么值得端到端（真的绑端口）：`stopLocalServer()` 从 M6 落地起**一个调用方都没有** ——
/// 关掉开关后监听 socket 还挂着、设置页那行说明还是旧文案；程序照样编译、别的单测照样绿
/// （与 M03P18 的「参数从来没人传」同一类断线）。做法照 CatVodNet 的 `LocalHTTPServerTests`：
/// 起真服务、看端口在不在。
@Suite("本地代理开关与服务对账")
@MainActor
struct LocalProxySwitchTests {
    /// 用例跑完无论如何都把服务停掉、临时目录清掉（服务留着就占着一个端口）。
    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        do {
            try await body(fixture.model)
        } catch {
            await fixture.model.stopLocalServer()
            throw error
        }
        await fixture.model.stopLocalServer()
    }

    /// `didSet` 那条路是异步的：给条件一点时间（最多 2 秒），别拿固定 sleep 赌时序。
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test("关掉开关：服务当场停、端口清掉、说明改成「已停止」；再打开又能起来")
    func switchOffStopsServer() async throws {
        try await withModel { model in
            // 默认是开的：一次对账就该把服务起起来。
            await model.syncLocalServerWithSwitch()
            #expect(model.localProxyPort != nil)
            #expect(model.localProxyNotice.contains("运行中"))

            model.isLocalProxyEnabled = false
            await model.syncLocalServerWithSwitch()
            #expect(model.localProxyPort == nil)
            #expect(model.localProxyNotice.contains("已停止"))
            let state: LocalHTTPServer.State? = await model.localServer?.state
            #expect(state == LocalHTTPServer.State.stopped)

            // 再打开：同一个 `LocalHTTPServer` 支持停完再起。
            model.isLocalProxyEnabled = true
            await model.syncLocalServerWithSwitch()
            #expect(model.localProxyPort != nil)
            #expect(model.localProxyNotice.contains("运行中"))
        }
    }

    @Test("开关本就关着：对账不去起服务，也不谎报「运行中」")
    func disabledSwitchNeverStartsServer() async throws {
        try await withModel { model in
            model.isLocalProxyEnabled = false
            await model.syncLocalServerWithSwitch()
            #expect(model.localProxyPort == nil)
            #expect(model.localServer == nil)
            #expect(!model.localProxyNotice.contains("运行中"))
        }
    }

    @Test("翻开关本身就走对账（didSet 那条路）：关掉后服务停、说明是「已停止」")
    func didSetReconciles() async throws {
        try await withModel { model in
            await model.syncLocalServerWithSwitch()
            #expect(model.localProxyPort != nil)

            model.isLocalProxyEnabled = false
            let stopped = await waitUntil { model.localProxyPort == nil }
            #expect(stopped)
            #expect(model.localProxyNotice.contains("已停止"))
        }
    }
}
