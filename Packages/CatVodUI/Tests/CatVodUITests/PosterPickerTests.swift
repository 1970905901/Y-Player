@testable import CatVodUI
import Testing

/// 海报取图策略（M11）：固定 / 随机 / 轮播。
struct PosterPickerTests {
    private let images = ["a", "b", "c"]

    @Test("固定：永远第一张，步进无关")
    func fixedStaysFirst() {
        let picker = PosterPicker(images: images, mode: .fixed)
        #expect(picker.image(step: 0) == "a")
        #expect(picker.image(step: 7) == "a")
        #expect(picker.image(step: 7, seed: 99) == "a")
    }

    @Test("随机：同一个 seed 不随步进变（进页面定一次），不同 seed 能取到不同的图")
    func randomHoldsPerEntry() {
        let picker = PosterPicker(images: images, mode: .random)
        let first = picker.image(step: 0, seed: 5)
        #expect(first == picker.image(step: 1, seed: 5))
        #expect(first == picker.image(step: 999, seed: 5))
        #expect(first != nil)
        // seed 决定落点：1/4/7 取到同一张，说明取模关系成立
        #expect(picker.image(seed: 1) == picker.image(seed: 4))
        #expect(picker.image(seed: 1) == picker.image(seed: 7))
    }

    @Test("轮播：按步进前进，到末尾回开头，负数也落回合法区间")
    func rotateWraps() {
        let picker = PosterPicker(images: images, mode: .rotate)
        #expect(picker.image(step: 0) == "a")
        #expect(picker.image(step: 1) == "b")
        #expect(picker.image(step: 2) == "c")
        #expect(picker.image(step: 3) == "a")
        #expect(picker.image(step: 100) == "b")
        #expect(picker.image(step: -1) == "c")
    }

    @Test("没有图时给 nil —— 界面据此显示占位，不是空白")
    func emptyGivesNil() {
        for mode in PosterMode.allCases {
            #expect(PosterPicker(images: [], mode: mode).image(step: 3, seed: 3) == nil)
        }
    }
}
