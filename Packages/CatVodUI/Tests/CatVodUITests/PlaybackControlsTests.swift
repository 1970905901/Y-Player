@testable import CatVodPlayer
@testable import CatVodUI
import Foundation
import Testing

/// 自绘内核的控制条显隐（M03P10）：只有「看得见 + 正在播」才自动收起；其余状态亮着。
@Suite("播放页：控制条自动收起")
struct PlaybackControlsTests {
    @Test("正在播、控制条可见：排自动收起")
    func playingHides() {
        #expect(PlaybackView.controlsShouldAutoHide(isVisible: true, state: .playing))
    }

    @Test("暂停 / 缓冲 / 结束 / 失败 / 未开始：不收起（那时人要看它）")
    func nonPlayingKeepsVisible() {
        let states: [PlayerState] = [.idle, .loading, .paused, .buffering, .ended, .failed("x")]
        for state in states {
            #expect(!PlaybackView.controlsShouldAutoHide(isVisible: true, state: state))
        }
    }

    @Test("已经收起来了：不必再排一次")
    func hiddenDoesNotSchedule() {
        #expect(!PlaybackView.controlsShouldAutoHide(isVisible: false, state: .playing))
    }

    @Test("等待时长：4 秒")
    func interval() {
        #expect(PlaybackView.controlsAutoHideSeconds == 4)
    }
}
