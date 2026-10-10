@testable import CatVodUI
import Foundation
import Testing

/// 单集循环（M03P20）：一集走到头（或到片尾标记）之后干什么 —— 循环优先于连播。
@Suite("播放页：单集循环的走向")
@MainActor
struct PlaybackRepeatTests {
    @Test("开了循环：不管有没有下一集，都回本集开头")
    func loopWins() {
        #expect(PlaybackView.endAction(isRepeatOne: true, hasNextEpisode: false) == .loop)
        #expect(PlaybackView.endAction(isRepeatOne: true, hasNextEpisode: true) == .loop)
    }

    @Test("没开循环：有下一集就下一集，没有就停在结束态")
    func defaultFlow() {
        #expect(PlaybackView.endAction(isRepeatOne: false, hasNextEpisode: true) == .nextEpisode)
        #expect(PlaybackView.endAction(isRepeatOne: false, hasNextEpisode: false) == .stop)
    }
}
