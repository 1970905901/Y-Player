@testable import CatVodUI
import Foundation
import Testing

/// 锁屏 / 防误触（M03P21）：锁上之后画面手势留哪几条 —— 只留单击。
///
/// `@MainActor`：`PlaybackView` 是 `@MainActor` 的，它的静态成员也在主 actor 上。
@Suite("播放页：锁屏 / 防误触")
@MainActor
struct PlaybackLockTests {
    @Test("没锁：手势全开")
    func unlocked() {
        #expect(PlaybackView.lockedGesturePolicy(isLocked: false) == .all)
    }

    @Test("锁上：只留单击 —— 双击 / 拖动 / 长按加速 / 捏合全停")
    func locked() {
        #expect(PlaybackView.lockedGesturePolicy(isLocked: true) == .singleTapOnly)
    }
}
