@testable import CatVodCore
@testable import CatVodUI
import Testing

/// 播放信息接线（M09d）：`SpiderResult` 里那两个「解析进来了、界面没用」的字段。
///
/// 这类字段的可怕之处是**不报错** —— 数据在 `AppModel` 里躺着，播放页少一行字，
/// 谁也不会发现。所以用审计找出来之后，用测试钉住「有值就显示、空的不占位」。
@Suite("播放信息接线")
@MainActor
struct PlaybackInfoTests {
    @Test("解析来源与描述：有值就进信息行")
    func infoRows() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        var result = SpiderResult()
        result.jxFrom = "演示解析"
        result.desc = "换源提示：本站已换新域名"
        fixture.model.notePlaybackInfo(from: result)

        #expect(fixture.model.playbackInfoRows == ["解析：演示解析", "换源提示：本站已换新域名"])
        #expect(fixture.model.parsedBy == "演示解析")
    }

    @Test("清掉之后不占位（换集 / 退出播放）")
    func clearsInfo() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        var result = SpiderResult()
        result.jxFrom = "某个解析"
        fixture.model.notePlaybackInfo(from: result)
        fixture.model.clearPlaybackInfo()

        #expect(fixture.model.playbackInfoRows.isEmpty)
    }

    @Test("只有一个字段有值：不补空行")
    func partialInfo() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        var result = SpiderResult()
        result.jxFrom = "某个解析"
        fixture.model.notePlaybackInfo(from: result)

        #expect(fixture.model.playbackInfoRows == ["解析：某个解析"])
    }

    @Test("字幕状态行：`idle` 不显示，其余都显示")
    func subtitleVisibility() {
        #expect(!SubtitleStatus.idle.isVisible)
        #expect(SubtitleStatus.loading.isVisible)
        #expect(SubtitleStatus.empty.isVisible)
        #expect(SubtitleStatus.loaded(source: "简中", count: 3).isVisible)
        #expect(SubtitleStatus.failed(reason: "连不上").isVisible)
    }
}
