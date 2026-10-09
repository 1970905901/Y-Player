@testable import CatVodUI
import Testing

@Suite("沉浸页：底部 Tab 栏登记")
struct ImmersiveTabBarStateTests {
    @Test("初始：没有沉浸页，不收栏")
    func initialState() {
        let state = ImmersiveTabBarState()
        #expect(!state.isActive)
        #expect(state.activePageCount == 0)
    }

    @Test("详情 → 播放叠两层：上一层退场时不闪回，两层都走了才恢复")
    func stackedPagesKeepHidden() {
        let state = ImmersiveTabBarState()
        state.notePageAppeared()
        #expect(state.isActive)
        state.notePageAppeared()
        state.notePageDisappeared()
        #expect(state.isActive)
        state.notePageDisappeared()
        #expect(!state.isActive)
    }

    @Test("多注销一次也不会把计数压成负数")
    func releaseIsClamped() {
        let state = ImmersiveTabBarState()
        state.notePageDisappeared()
        #expect(state.activePageCount == 0)
        #expect(!state.isActive)
    }
}
