@testable import CatVodUI
import Foundation
import Testing

/// 播放时间的外推（M08h 引入，M09f 改名并单独成文件 —— 弹幕与字幕共用）。
///
/// 这几条钉的是「弹幕/字幕比画面慢半拍」与「暂停后往回跳」这类**肉眼能看出、但说不清哪里错**的问题。
@Suite("播放时钟：位置外推")
struct PlaybackClockTests {
    /// 采样时刻的基准（固定值，别用 `Date()` —— 测试要能重复跑出同一结果）。
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("还没采样时不走：位置就是 0，也不驱动逐帧刷新")
    func beforeFirstSample() {
        let clock = PlaybackClock()
        #expect(clock.time(at: t0) == 0)
        #expect(!clock.isRunning)
    }

    @Test("采样之后按速率外推：1 倍速过 1 秒，位置 +1")
    func extrapolates() {
        var clock = PlaybackClock()
        clock.sample(position: 10, rate: 1, at: t0)
        #expect(clock.time(at: t0) == 10)
        #expect(abs(clock.time(at: t0.addingTimeInterval(1)) - 11) < 0.0001)
        #expect(clock.isRunning)
    }

    @Test("倍速外推：1.5 倍速过 2 秒，位置 +3")
    func extrapolatesAtFasterRate() {
        var clock = PlaybackClock()
        clock.sample(position: 0, rate: 1.5, at: t0)
        #expect(abs(clock.time(at: t0.addingTimeInterval(2)) - 3) < 0.0001)
    }

    @Test("暂停 / 缓冲（速率 0）时时间不动，也不驱动刷新")
    func stopsWhenPaused() {
        var clock = PlaybackClock()
        clock.sample(position: 20, rate: 0, at: t0)
        #expect(clock.time(at: t0.addingTimeInterval(5)) == 20)
        #expect(!clock.isRunning)
    }

    @Test("改速率前先把旧速率外推到此刻：暂停不丢掉两次上报之间走过的距离")
    func carriesPositionWhenRateChanges() {
        var clock = PlaybackClock()
        clock.sample(position: 10, rate: 1, at: t0)
        clock.setRate(0, at: t0.addingTimeInterval(0.5))
        #expect(abs(clock.time(at: t0.addingTimeInterval(0.5)) - 10.5) < 0.0001)
        #expect(abs(clock.time(at: t0.addingTimeInterval(3)) - 10.5) < 0.0001)
    }

    @Test("时刻倒退（系统时间被改）时位置不退：宁可停住也不往回跳")
    func neverGoesBackwards() {
        var clock = PlaybackClock()
        clock.sample(position: 30, rate: 1, at: t0)
        #expect(clock.time(at: t0.addingTimeInterval(-5)) == 30)
    }

    @Test("负速率当 0：不支持的倒放不会把弹幕与字幕往回拖")
    func clampsNegativeRate() {
        var clock = PlaybackClock()
        clock.sample(position: 5, rate: -1, at: t0)
        #expect(clock.rate == 0)
        #expect(clock.time(at: t0.addingTimeInterval(2)) == 5)
    }
}
