@testable import CatVodUI
import Foundation
import Testing

/// 片头 / 片尾的规则（M03P16）：可标范围、起播位置、跳片尾 —— 逐条对齐上游。
@Suite("播放页：片头 / 片尾规则")
@MainActor
struct PlaybackOpeningEndingRulesTests {
    @Test("可标范围：<15 分钟 3 分钟、<30 分钟 6 分钟、更长 10 分钟（上游 getOpEdLimit）")
    func limits() {
        #expect(PlaybackOpeningEndingRules.limit(duration: 10 * 60) == 3 * 60)
        #expect(PlaybackOpeningEndingRules.limit(duration: 15 * 60 - 1) == 3 * 60)
        #expect(PlaybackOpeningEndingRules.limit(duration: 15 * 60) == 6 * 60)
        #expect(PlaybackOpeningEndingRules.limit(duration: 30 * 60 - 1) == 6 * 60)
        #expect(PlaybackOpeningEndingRules.limit(duration: 30 * 60) == 10 * 60)
        #expect(PlaybackOpeningEndingRules.limit(duration: 120 * 60) == 10 * 60)
    }

    @Test("片头只能在开头附近标；片尾只能在结尾附近标（位置为 0 / 时长未知一律不给标）")
    func marking() {
        // 45 分钟片：可标范围 10 分钟
        #expect(PlaybackOpeningEndingRules.canSetOpening(position: 60, duration: 2700))
        #expect(!PlaybackOpeningEndingRules.canSetOpening(position: 700, duration: 2700))
        #expect(!PlaybackOpeningEndingRules.canSetOpening(position: 0, duration: 2700))
        #expect(!PlaybackOpeningEndingRules.canSetOpening(position: 60, duration: 0))

        #expect(PlaybackOpeningEndingRules.canSetEnding(position: 2650, duration: 2700))
        #expect(!PlaybackOpeningEndingRules.canSetEnding(position: 2000, duration: 2700))
        #expect(!PlaybackOpeningEndingRules.canSetEnding(position: 2700, duration: 2700))
    }

    @Test("起播位置：片头与上次位置取靠后的那个（上游 startPositionMs）")
    func startPosition() {
        #expect(PlaybackOpeningEndingRules.startPosition(opening: 90, resume: 0) == 90)
        #expect(PlaybackOpeningEndingRules.startPosition(opening: 90, resume: 300) == 300)
        #expect(PlaybackOpeningEndingRules.startPosition(opening: 600, resume: 300) == 600)
        #expect(PlaybackOpeningEndingRules.startPosition(opening: 0, resume: 0) == 0)
    }

    @Test("跳片尾：位置 + 片尾 >= 总时长；没标片尾 / 时长未知都不跳")
    func skipEnding() {
        #expect(PlaybackOpeningEndingRules.shouldSkipEnding(position: 2590, duration: 2700, ending: 120))
        #expect(!PlaybackOpeningEndingRules.shouldSkipEnding(position: 2400, duration: 2700, ending: 120))
        #expect(!PlaybackOpeningEndingRules.shouldSkipEnding(position: 2700, duration: 2700, ending: 0))
        #expect(!PlaybackOpeningEndingRules.shouldSkipEnding(position: 100, duration: 0, ending: 120))
    }
}
