@testable import CatVodUI
import Foundation
import Testing

/// 直播页的「现在」（M07d8）：整分钟对齐，边界（正好在整分钟 / 差半秒）都要对。
@Suite("直播：时钟对齐")
struct LiveClockTests {
    /// 1_800_000_000 秒正好是整分钟（能被 60 整除），拿它当基准点。
    private let onTheMinute = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("正好在整分钟上：给满 60 秒（不空转）")
    func exactlyOnMinute() {
        #expect(LiveClock.secondsUntilNextMinute(from: onTheMinute) == 60)
    }

    @Test("半分钟处：还剩 30 秒")
    func halfway() {
        #expect(LiveClock.secondsUntilNextMinute(from: onTheMinute.addingTimeInterval(30)) == 30)
    }

    @Test("差半秒到整分钟：给半秒，不跨过边界")
    func justBefore() {
        let delay = LiveClock.secondsUntilNextMinute(from: onTheMinute.addingTimeInterval(59.5))
        #expect(abs(delay - 0.5) < 0.0001)
    }
}
