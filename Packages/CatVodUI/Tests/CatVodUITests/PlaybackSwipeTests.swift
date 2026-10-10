@testable import CatVodUI
import CoreGraphics
import Testing

/// 一甩切集的采样器与判据（M03P23）。
///
/// 为什么值得单测：`DragGesture` 不给速度，速度是我们自己从样本里算的 ——
/// 门槛宽一点「调音量被误判成切集」、窄一点「甩了没反应」，这条线只能靠用例钉住。
@Suite("播放页一甩切集：采样与判据")
struct PlaybackSwipeRulesTests {
    @Test("采样窗口：快甩速度高、慢拖速度低")
    func trackerSpeed() {
        var fast = PlaybackSwipeTracker()
        // 每 16ms 走 30pt ≈ 1875 pt/s（一甩）。
        for step in 0 ..< 8 {
            fast.record(at: Double(step) * 0.016, y: Double(step) * 30)
        }
        #expect(fast.speed(at: 7 * 0.016) > PlaybackSwipeRules.minimumSpeed)

        var slow = PlaybackSwipeTracker()
        // 每 16ms 走 3pt ≈ 187 pt/s（慢慢拖）。
        for step in 0 ..< 8 {
            slow.record(at: Double(step) * 0.016, y: Double(step) * 3)
        }
        #expect(slow.speed(at: 7 * 0.016) < PlaybackSwipeRules.minimumSpeed)
    }

    @Test("手指停住再松手：速度算 0（慢慢拖完不是甩）")
    func trackerStopped() {
        var tracker = PlaybackSwipeTracker()
        for step in 0 ..< 5 {
            tracker.record(at: Double(step) * 0.016, y: Double(step) * 30)
        }
        // 停在原地不动 1 秒才松手：窗口里只剩停止那一个样本。
        tracker.record(at: 1.0, y: 120)
        #expect(tracker.speed(at: 1.05) == 0)

        // 清掉之后也没了（换一次拖动不带着上一轮的样本）。
        tracker.reset()
        #expect(tracker.speed(at: 1.05) == 0)
    }

    @Test("一甩的判据：位移 / 角度 / 速度 / 起手区，四条都过才算")
    func actionRules() {
        let width: CGFloat = 390
        let center: CGFloat = 195
        let fast = 2000.0

        // 正常一甩：中间起手、向上 120pt —— 下一集。
        let up = PlaybackSwipeRules.action(
            translation: CGSize(width: 10, height: -120),
            speed: fast,
            startX: center,
            width: width
        )
        #expect(up == .next)

        // 下滑：上一集。
        let down = PlaybackSwipeRules.action(
            translation: CGSize(width: -10, height: 120),
            speed: fast,
            startX: center,
            width: width
        )
        #expect(down == .previous)

        // 位移不够（比一甩的下限还短）。
        let short = PlaybackSwipeRules.action(
            translation: CGSize(width: 0, height: -40),
            speed: fast,
            startX: center,
            width: width
        )
        #expect(short == nil)

        // 速度不够（慢慢拖）。
        let slow = PlaybackSwipeRules.action(
            translation: CGSize(width: 0, height: -120),
            speed: 300,
            startX: center,
            width: width
        )
        #expect(slow == nil)

        // 不够竖（横着划过去，那是拖进度）。
        let flat = PlaybackSwipeRules.action(
            translation: CGSize(width: 120, height: -60),
            speed: fast,
            startX: center,
            width: width
        )
        #expect(flat == nil)

        // 侧边四分之一起手：那儿是音量 / 亮度，不切集。
        let side = PlaybackSwipeRules.action(
            translation: CGSize(width: 0, height: -120),
            speed: fast,
            startX: 40,
            width: width
        )
        #expect(side == nil)
    }

    @Test("起手区：中间一半算切集区，四分之一线上也算（与上游 isSide 同一刀）")
    func centerZone() {
        #expect(PlaybackSwipeRules.isCenterZone(startX: 97.5, width: 390))
        #expect(PlaybackSwipeRules.isCenterZone(startX: 292.5, width: 390))
        #expect(!PlaybackSwipeRules.isCenterZone(startX: 97.4, width: 390))
        #expect(!PlaybackSwipeRules.isCenterZone(startX: 292.6, width: 390))
        // 宽度还拿不到（首帧没布局）：不挡 —— 宁可让它切，也别把这一甩吞掉。
        #expect(PlaybackSwipeRules.isCenterZone(startX: 0, width: 0))
    }
}
