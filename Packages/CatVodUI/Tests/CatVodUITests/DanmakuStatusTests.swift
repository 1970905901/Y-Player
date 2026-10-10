@testable import CatVodUI
import Testing

/// 播放页那行弹幕状态的文案（M08c）。
///
/// 四种状态必须分得清：「加载中」与「没搜到」混起来，用户只会以为一直卡着；
/// 「没搜到」还要指路（设置页的地址槽是唯一能改的地方），否则用户不知道下一步该动哪儿。
@Suite("弹幕状态文案")
struct DanmakuStatusTests {
    @Test("不显示：开关关着 / 用户没填地址 —— 那是他的设置，不该提示")
    func idleIsInvisible() {
        #expect(DanmakuStatus.idle.text.isEmpty)
        #expect(!DanmakuStatus.idle.isVisible)
    }

    @Test("加载中 / 失败：一个是「等」，一个是「有原因可查」")
    func loadingAndFailure() {
        #expect(DanmakuStatus.loading.text == "弹幕：加载中…")
        #expect(DanmakuStatus.failed("连不上").text == "弹幕：加载失败 — 连不上")
        #expect(DanmakuStatus.failed("连不上").isVisible)
    }

    @Test("搜到了：写清来自哪个源、多少条；没有源名就只写条数")
    func loadedShowsSourceAndCount() {
        #expect(DanmakuStatus.loaded(source: "甲源", count: 312).text == "弹幕：甲源 · 312 条")
        #expect(DanmakuStatus.loaded(source: "   ", count: 8).text == "弹幕：8 条")
    }

    @Test("没搜到：要指路（不然用户不知道下一步动哪儿）")
    func emptyPointsToSettings() {
        #expect(DanmakuStatus.empty.text.contains("弹幕 API"))
        #expect(DanmakuStatus.empty.isVisible)
    }

    @Test("选中的文件里没有行（M03P25）：下一步是「换一条」，不是去改 API 地址")
    func emptySourcePointsToAnotherSource() {
        #expect(DanmakuStatus.emptySource("甲源").text == "弹幕：甲源 里没有弹幕（换一条试试）")
        #expect(DanmakuStatus.emptySource("   ").text == "弹幕：这份文件里没有弹幕（换一条试试）")
        #expect(DanmakuStatus.emptySource("甲源").isVisible)
        #expect(!DanmakuStatus.emptySource("甲源").text.contains("弹幕 API"))
    }
}
