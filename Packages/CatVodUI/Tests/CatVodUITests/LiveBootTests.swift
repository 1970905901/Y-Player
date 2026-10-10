@testable import CatVodUI
import Foundation
import Testing

/// 直播源的「开机自启」（M07d9）：本机覆盖两个方向都能拨、按源名分桶、落盘。
@Suite("直播源：开机自启")
@MainActor
struct LiveBootTests {
    /// 两个源：一个写了 `boot: true`，一个没写（用来验「默认跟源的字段」与「按源名分桶」）。
    /// 站点是必需的：配置没有任何可用站点时 `load()` 会直接失败（`configHasNoUsableSite`）。
    private static let config = """
    {"sites":[{"key":"a","name":"甲站","type":3,"api":"http://127.0.0.1:9988/spider/a"}],
     "lives":[{"name":"客厅","type":0,"url":"https://live.example.com/list.m3u8","boot":true},
              {"name":"备用","type":0,"url":"https://live.example.com/backup.m3u8"}]}
    """

    @Test("默认跟源的 boot；本机覆盖能关掉，重开还在（关掉就是关掉）")
    func overrideOffAndPersist() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load(Self.config)
        let model = fixture.model

        #expect(model.selectedLiveSource?.name == "客厅")
        #expect(model.liveBootEnabled)

        model.setLiveBoot(false)
        #expect(!model.liveBootEnabled)

        // 重开（同一份存档）：本机覆盖还在 —— 源里写的是 true，用户关掉不能被源的字段盖回来。
        let reopened = try fixture.reopenedModel()
        #expect(reopened.liveBootOverrides == ["客厅": false])
    }

    @Test("两个方向都能拨且按源名分桶；没写 boot 的源默认关")
    func bothWaysAndPerSource() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load(Self.config)
        let model = fixture.model

        model.setLiveBoot(false)
        model.setLiveBoot(true)
        #expect(model.liveBootEnabled)
        #expect(model.liveBootOverrides == ["客厅": true])
        // 另一个源没被牵连（覆盖按源名存）。
        #expect(model.liveBootOverrides["备用"] == nil)
    }

    @Test("源没写 boot、也没有本机覆盖：默认关（不猜）")
    func defaultsOff() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load("""
        {"sites":[{"key":"a","name":"甲站","type":3,"api":"http://127.0.0.1:9988/spider/a"}],
         "lives":[{"name":"客厅","type":0,"url":"https://live.example.com/list.m3u8"}]}
        """)

        #expect(!fixture.model.liveBootEnabled)
        #expect(fixture.model.liveBootOverrides.isEmpty)
    }
}
