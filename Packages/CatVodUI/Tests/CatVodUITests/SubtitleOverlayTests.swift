import CatVodCore
@testable import CatVodUI
import SwiftUI
import Testing

/// 字幕上屏的纯逻辑（M09f）：某一刻该画什么、显示参数怎么随画面缩放。
///
/// 「画」那一层只能靠眼睛验，但这两件错了都是**看不出对错**的：重叠字幕互相盖住、
/// 大窗口上字号小得读不了 —— 所以抽出来钉住。
@Suite("字幕上屏：取哪条与显示参数")
struct SubtitleOverlayTests {
    private func cue(_ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: text)
    }

    private func timeline(_ cues: [SubtitleCue]) -> SubtitleTimeline {
        SubtitleTimeline(cues: cues)
    }

    @Test("该显示时给文本，窗口外给 nil")
    func textLookup() {
        let line = timeline([cue(10, 12, "甲")])
        #expect(SubtitleOverlayGeometry.text(timeline: line, at: 9) == nil)
        #expect(SubtitleOverlayGeometry.text(timeline: line, at: 11) == "甲")
        #expect(SubtitleOverlayGeometry.text(timeline: line, at: 13) == nil)
    }

    @Test("空时间轴给 nil（父视图据此不挂这一层）")
    func emptyTimeline() {
        #expect(SubtitleOverlayGeometry.text(timeline: timeline([]), at: 0) == nil)
    }

    @Test("重叠拼成多行，不叠着画：真实字幕里的重叠就是原文 + 译文")
    func overlappingJoin() {
        let bilingual = timeline([cue(10, 14, "原文"), cue(11, 15, "译文")])
        #expect(SubtitleOverlayGeometry.text(timeline: bilingual, at: 10) == "原文")
        #expect(SubtitleOverlayGeometry.text(timeline: bilingual, at: 12) == "原文\n译文")
        #expect(SubtitleOverlayGeometry.text(timeline: bilingual, at: 14.5) == "译文")
    }

    @Test("空白 cue 当没有：SRT 里空行就是「这条没内容」，不该画一个空背景框")
    func blankCueIsIgnored() {
        #expect(SubtitleOverlayGeometry.text(timeline: timeline([cue(10, 12, "   ")]), at: 11) == nil)
        #expect(SubtitleOverlayGeometry.text(timeline: timeline([cue(10, 12, "\n\n")]), at: 11) == nil)
        // 一条空、一条有内容：只画有内容的那条
        let mixed = timeline([cue(10, 12, " "), cue(10, 12, "有内容")])
        #expect(SubtitleOverlayGeometry.text(timeline: mixed, at: 11) == "有内容")
    }

    @Test("行内换行保留：SRT 的多行 cue 本来就该多行显示")
    func keepsInnerNewlines() {
        let line = timeline([cue(10, 12, "上句\n下句")])
        #expect(SubtitleOverlayGeometry.text(timeline: line, at: 11) == "上句\n下句")
    }

    @Test("字号随画面高度缩放，并夹在上下限内")
    func fontScale() {
        let style = SubtitleDisplayStyle()

        let phone = style.resolved(height: 220)
        #expect(abs(phone.fontSize - 20) < 0.0001) // 参考高度 ⇒ 基准字号

        #expect(style.resolved(height: 700).fontSize == style.maxFontScale * style.baseFontSize)
        #expect(style.resolved(height: 60).fontSize == style.minFontScale * style.baseFontSize)

        // 底边距与行距跟着同一比例走：不然大窗口上字变大了、字却贴得更紧了。
        let tall = style.resolved(height: 700)
        #expect(tall.bottomInset > phone.bottomInset)
        #expect(tall.lineSpacing > phone.lineSpacing)
    }

    @Test("覆盖层能构造（不渲染，只钉住接口）")
    @MainActor
    func overlayConstructs() {
        let line = timeline([cue(10, 12, "甲")])
        let style = SubtitleDisplayStyle().resolved(height: 220)
        _ = SubtitleOverlay(timeline: line, style: style, clock: PlaybackClock())
    }
}
