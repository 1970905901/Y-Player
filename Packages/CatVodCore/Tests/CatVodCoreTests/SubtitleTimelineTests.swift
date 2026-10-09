@testable import CatVodCore
import Testing

@Suite("字幕时间轴：按时间查该显示哪几条")
struct SubtitleTimelineTests {
    private func cue(_ start: Double, _ end: Double, _ text: String = "字幕") -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: text)
    }

    @Test("空时间轴：任何时候都查不到东西")
    func empty() {
        let timeline = SubtitleTimeline(cues: [])
        #expect(timeline.isEmpty)
        #expect(timeline.count == 0)
        #expect(timeline.cues(at: 0).isEmpty)
        #expect(timeline.cues(at: 100).isEmpty)
    }

    @Test("基本命中：起止之间显示，边界含两端")
    func basicLookup() {
        let timeline = SubtitleTimeline(cues: [cue(10, 12, "甲"), cue(20, 22, "乙")])

        #expect(timeline.cues(at: 9.99).isEmpty)
        #expect(timeline.cues(at: 10).map(\.text) == ["甲"])
        #expect(timeline.cues(at: 11).map(\.text) == ["甲"])
        #expect(timeline.cues(at: 12).map(\.text) == ["甲"]) // 结束那一刻仍显示（与 SubtitleCue.isVisible 同口径）
        #expect(timeline.cues(at: 13).isEmpty)
        #expect(timeline.cues(at: 20).map(\.text) == ["乙"])
        #expect(timeline.cues(at: 100).isEmpty)
    }

    @Test("乱序输入：内部排好，查询结果按出现时间排")
    func sortsInput() {
        let timeline = SubtitleTimeline(cues: [cue(20, 21, "乙"), cue(10, 11, "甲"), cue(15, 16, "丙")])
        #expect(timeline.count == 3)
        #expect(timeline.cues(at: 10).map(\.text) == ["甲"])
        #expect(timeline.cues(at: 20).map(\.text) == ["乙"])
    }

    @Test("重叠：几条都给（怎么叠是渲染层的决定）")
    func overlappingCues() {
        let timeline = SubtitleTimeline(cues: [cue(10, 14, "甲"), cue(12, 16, "乙")])
        #expect(timeline.cues(at: 9).isEmpty)
        #expect(timeline.cues(at: 10).map(\.text) == ["甲"])
        #expect(timeline.cues(at: 13).map(\.text) == ["甲", "乙"])
        #expect(timeline.cues(at: 15).map(\.text) == ["乙"])
        #expect(timeline.cues(at: 17).isEmpty)
    }

    @Test("很长的 cue 不会漏：回扫窗口按「最长一条」算，不是固定值")
    func longCueIsFound() {
        // 一条 30 秒的字幕，后面还跟着一条短的：查它自己的中段必须命中。
        let timeline = SubtitleTimeline(cues: [cue(0, 30, "长"), cue(5, 6, "短")])
        #expect(timeline.cues(at: 4).map(\.text) == ["长"])
        #expect(timeline.cues(at: 5).map(\.text) == ["长", "短"])
        #expect(timeline.cues(at: 25).map(\.text) == ["长"])
    }

    @Test("零长 cue 与坏时间不崩：还是那句话时按同一套口径判定")
    func degenerateInputs() {
        let timeline = SubtitleTimeline(cues: [cue(10, 10, "零长"), cue(20, 25, "正常")])
        #expect(timeline.cues(at: 10).map(\.text) == ["零长"]) // start == end，那一刻仍算显示
        #expect(timeline.cues(at: 11).isEmpty)
        // NaN / 无穷：查不出东西，但也不崩（`time.isFinite` 挡掉）
        #expect(timeline.cues(at: .nan).isEmpty)
        #expect(timeline.cues(at: .infinity).isEmpty)
    }

    @Test("一万条里也能查对：二分 + 窗口回扫不是为了好看")
    func largeInput() {
        // 0…9999 秒，每秒一条、持续 0.9 秒。
        let cues = (0 ..< 10000).map { cue(Double($0), Double($0) + 0.9, "\($0)") }
        let timeline = SubtitleTimeline(cues: cues.shuffled())
        #expect(timeline.count == 10000)
        #expect(timeline.cues(at: 5000.5).map(\.text) == ["5000"])
        #expect(timeline.cues(at: 9999.5).map(\.text) == ["9999"])
        #expect(timeline.cues(at: 9999.95).isEmpty) // 最后一条只持续 0.9 秒，此刻已经过了
        #expect(timeline.cues(at: 10000.5).isEmpty)
    }
}
