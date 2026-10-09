@testable import CatVodUI
import Testing

@Suite("发现页：底部 Tab 栏收放")
struct DiscoverTabBarVisibilityTests {
    /// 造一个「已经收起」的状态。
    ///
    /// 收起只能由「触屏 + 上滑」产生，所以这里就走一遍真实路径 —— 顺手也就是一次冒烟。
    private func hiddenState() -> DiscoverTabBarVisibility {
        var state = DiscoverTabBarVisibility()
        state.touchDown()
        state.dragChanged(translationX: 0, translationY: -60)
        return state
    }

    @Test("初始：展开、没有触摸")
    func initialState() {
        let state = DiscoverTabBarVisibility()
        #expect(!state.isHidden)
        #expect(!state.isTouching)
    }

    @Test("触屏 + 向上滑 → 收起")
    func hideOnUpwardScroll() {
        #expect(hiddenState().isHidden)
    }

    @Test("滑的距离不够不收：手指一碰就收，想点顶部工具栏会闪一下")
    func smallDragKeepsVisible() {
        var state = DiscoverTabBarVisibility()
        state.touchDown()
        state.dragChanged(translationX: 0, translationY: -3)
        #expect(!state.isHidden)
        // 阈值边界本身不算（判定是严格小于）。
        state.dragChanged(translationX: 0, translationY: -DiscoverTabBarVisibility.hideThreshold)
        #expect(!state.isHidden)
        state.dragChanged(translationX: 0, translationY: -DiscoverTabBarVisibility.hideThreshold - 1)
        #expect(state.isHidden)
    }

    @Test("没触屏就不收：上滑判定必须发生在一次真实触摸里")
    func dragWithoutTouchDoesNothing() {
        var state = DiscoverTabBarVisibility()
        state.dragChanged(translationX: 0, translationY: -60)
        #expect(!state.isHidden)
        #expect(!state.isTouching)
    }

    @Test("向下滑不展开：只有触碰能展开")
    func downwardDragDoesNotReveal() {
        var state = hiddenState()
        state.dragChanged(translationX: 0, translationY: 60)
        #expect(state.isHidden)
    }

    @Test("同一次触摸里反向滑回来也不展开：手指没离开屏幕就一直收起")
    func reversedDragWithinSameTouchKeepsHidden() {
        var state = DiscoverTabBarVisibility()
        state.touchDown()
        state.dragChanged(translationX: 0, translationY: -60)
        #expect(state.isHidden)
        // 手指没抬起来，又往回滑（先滑过头一点、想看上面的内容）。
        state.dragChanged(translationX: 0, translationY: -2)
        state.dragChanged(translationX: 0, translationY: 40)
        #expect(state.isHidden)
    }

    @Test("松手保持收起（离开后也隐藏）")
    func staysHiddenAfterRelease() {
        var state = hiddenState()
        state.touchEnded()
        #expect(state.isHidden)
        #expect(!state.isTouching)
    }

    @Test("再次触碰屏幕就展开（收起之后要能导航出去）")
    func nextTouchReveals() {
        var state = hiddenState()
        state.touchEnded()
        state.touchDown()
        #expect(!state.isHidden)
        #expect(state.isTouching)
    }

    @Test("横滑轮播不收：竖直为主的才算「向上滑列表」")
    func horizontalDragDoesNotHide() {
        var state = DiscoverTabBarVisibility()
        state.touchDown()
        state.dragChanged(translationX: -40, translationY: -6)
        #expect(!state.isHidden)
        // 竖直漂移有 20pt 但横向更多，同样不算。
        state.dragChanged(translationX: -30, translationY: -20)
        #expect(!state.isHidden)
        state.dragChanged(translationX: -10, translationY: -30)
        #expect(state.isHidden)
    }

    @Test("零位移的那次事件当作触屏：另一路旁听手势漏了也能撑住")
    func zeroTranslationActsAsTouchDown() {
        var state = DiscoverTabBarVisibility()
        state.dragChanged(translationX: 0, translationY: 0)
        #expect(state.isTouching)
        #expect(!state.isHidden)
        // 已经收起之后再收到一次零位移（手指恰好移回原点）不会把栏弹出来。
        var hidden = hiddenState()
        hidden.dragChanged(translationX: 0, translationY: 0)
        #expect(hidden.isHidden)
    }

    @Test("离开发现页强制展开：Tab 栏是导航出去的路")
    func revealOnLeave() {
        var state = hiddenState()
        state.reveal()
        #expect(!state.isHidden)
        #expect(!state.isTouching)
    }
}
