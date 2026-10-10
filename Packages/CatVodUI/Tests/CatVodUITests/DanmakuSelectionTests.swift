@testable import CatVodUI
import CatVodCore
import Testing

/// 手动选弹幕 / 换关键词重搜的接线（M03P25）。
///
/// 只测**不联网**的那些分支：重搜「没得搜」的三条原因、选一条取不到内容的源、回到自动时清干净。
/// 真正下载与解析弹幕文件那一步在 `CatVodSource` 的单测里（离线夹具）—— 这里不碰网络。
@Suite("播放页选弹幕：接线")
@MainActor
struct DanmakuSelectionTests {
    @Test("重搜搜不了时，把原因如实带回来（开关 / 关键词 / 地址三种）")
    func searchNotes() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // 默认存档就是「弹幕 API 没开」。
        let disabled = await model.searchDanmaku(name: "片名", episode: "第1集")
        #expect(disabled == "弹幕 API 没开：设置 → 播放 → 弹幕 API")

        model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["http://127.0.0.1:1/search"])
        let blank = await model.searchDanmaku(name: " ", episode: "")
        #expect(blank == "片名和集名不能都是空的")

        model.danmakuAPI = DanmakuAPIConfig(isEnabled: true)
        let noAddress = await model.searchDanmaku(name: "片名", episode: "第1集")
        #expect(noAddress == "还没填弹幕 API 地址（设置 → 播放 → 弹幕 API）")
    }

    @Test("选一条取不到内容的源：说「文件里没有弹幕」；回到自动时清干净、不谎报")
    func selectThenReset() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["http://127.0.0.1:1/search"])

        // 地址不是合法 URL（`URL(string:)` 给 nil）→ 一行都取不到。这一步不联网。
        let broken = DanmakuSource(name: "甲源", url: "not a url")
        await model.selectDanmaku(broken)
        #expect(model.danmakuPick == broken)
        #expect(model.danmakuStatus == .emptySource("甲源"))
        #expect(model.danmakuLines.isEmpty)

        // 回到自动：这次连候选都没有 → 状态回到「不显示」，别留着上一条的「文件里没有弹幕」。
        await model.selectDanmaku(nil)
        #expect(model.danmakuPick == nil)
        #expect(model.danmakuStatus == .idle)
    }
}
