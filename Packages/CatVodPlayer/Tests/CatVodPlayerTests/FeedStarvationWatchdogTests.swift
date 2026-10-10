@testable import CatVodPlayer
import Foundation
import Testing

/// 饥饿看门狗（M04P17）：时钟跑到数据前面没有 —— 纯逻辑，钉边沿。
///
/// ⚠️ `tick` / `noteFeed` 是 **mutating** 方法：**不能直接写在 `#expect` 里** ——
/// Swift Testing 的宏展开会把子表达式包进 `$0` 闭包，mutating 调用当场报
/// 「cannot use mutating member on immutable value: '$0' is immutable」（M04P17 第一版就是这么红的）。
/// 一律先落局部 `let` 再断言。
@Suite("饥饿看门狗（M04P17）")
struct FeedStarvationWatchdogTests {
    @Test("跨过阈值才报一次「饿了」；喂一帧才恢复")
    func edges() {
        var watchdog = FeedStarvationWatchdog(threshold: 0.3)
        let inThreshold = watchdog.tick(clockSeconds: 10.0, lastFedSeconds: 10.0)
        #expect(!inThreshold)
        let stillInThreshold = watchdog.tick(clockSeconds: 10.2, lastFedSeconds: 10.0)
        #expect(!stillInThreshold)
        let crossed = watchdog.tick(clockSeconds: 10.4, lastFedSeconds: 10.0)
        #expect(crossed)
        // 已经在饿：再心跳多少次都不重复报（否则界面会一直收到「缓冲中」）
        let repeated = watchdog.tick(clockSeconds: 12.0, lastFedSeconds: 10.0)
        #expect(!repeated)
        #expect(watchdog.isStarving)

        let recovered = watchdog.noteFeed()
        #expect(recovered)
        #expect(!watchdog.isStarving)
        // 没在饿：喂帧不报「恢复」
        let recoveredAgain = watchdog.noteFeed()
        #expect(!recoveredAgain)
    }

    @Test("解码比实时慢但一直在出帧：落后在阈值内就不算饿")
    func slowButFed() {
        var watchdog = FeedStarvationWatchdog(threshold: 0.3)
        let first = watchdog.tick(clockSeconds: 5.2, lastFedSeconds: 5.0)
        let second = watchdog.tick(clockSeconds: 5.4, lastFedSeconds: 5.2)
        #expect(!first)
        #expect(!second)
        #expect(!watchdog.isStarving)
    }

    @Test("阈值可就地调（软件解码那条路以后可能要放宽）")
    func thresholdIsConfigurable() {
        var watchdog = FeedStarvationWatchdog(threshold: 1.5)
        let inThreshold = watchdog.tick(clockSeconds: 5.9, lastFedSeconds: 5.0)
        #expect(!inThreshold)
        let crossed = watchdog.tick(clockSeconds: 6.6, lastFedSeconds: 5.0)
        #expect(crossed)
    }
}
