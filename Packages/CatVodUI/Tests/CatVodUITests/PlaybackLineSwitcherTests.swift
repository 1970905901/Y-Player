@testable import CatVodUI
import Foundation
import Testing

/// 播放页换线路（M03P17）：找「同一集」的规则 —— **先按集名**（线路之间集数 / 顺序常常不一样），
/// 名字对不上（或没有名字）再按下标兜底，越界给 nil（换线路会如实提示，不硬编地址）。
@Suite("播放页：换线路找同一集")
struct PlaybackLineSwitcherTests {
    @Test("集名对得上：按集名找（新线路顺序不一样也对得上）")
    func matchByName() {
        let names = ["第3集", "第1集", "第2集"]
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "第2集", index: 0, names: names) == 2)
    }

    @Test("集名对不上 / 没有名字：按下标兜底")
    func matchByIndex() {
        let names = ["A", "B", "C"]
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "X", index: 1, names: names) == 1)
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "", index: 2, names: names) == 2)
    }

    @Test("越界又没有集名：给 nil；有集名照样能找到")
    func outOfRange() {
        let names = ["A", "B"]
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "X", index: 5, names: names) == nil)
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "", index: 5, names: names) == nil)
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "A", index: 5, names: names) == 0)
        #expect(PlaybackLineSwitcher.matchIndex(episodeName: "A", index: 0, names: []) == nil)
    }
}
