@testable import CatVodPlayer
import Foundation
import Testing

/// 饥饿看门狗（M04P17）：时钟跑到数据前面没有 —— 纯逻辑，钉边沿。
@Suite("饥饿看门狗（M04P17）")
struct FeedStarvationWatchdogTests {
    @Test("跨过阈值才报一次「饿了」；喂一帧才恢复")
    func edges() {
        var watchdog = FeedStarvationWatchdog(threshold: 0.3)
        #expect(!watchdog.tick(clockSeconds: 10.0, lastFedSeconds: 10.0))
        #expect(!watchdog.tick(clockSeconds: 10.2, lastFedSeconds: 10.0))
        #expect(watchdog.tick(clockSeconds: 10.4, lastFedSeconds: 10.0))
        // 已经在饿：再心跳多少次都不重复报（否则界面会一直收到「缓冲中」）
        #expect(!watchdog.tick(clockSeconds: 12.0, lastFedSeconds: 10.0))
        #expect(watchdog.isStarving)

        #expect(watchdog.noteFeed())
        #expect(!watchdog.isStarving)
        // 没在饿：喂帧不报「恢复」
        #expect(!watchdog.noteFeed())
    }

    @Test("解码比实时慢但一直在出帧：落后在阈值内就不算饿")
    func slowButFed() {
        var watchdog = FeedStarvationWatchdog(threshold: 0.3)
        #expect(!watchdog.tick(clockSeconds: 5.2, lastFedSeconds: 5.0))
        #expect(!watchdog.tick(clockSeconds: 5.4, lastFedSeconds: 5.2))
        #expect(!watchdog.isStarving)
    }

    @Test("阈值可就地调（软件解码那条路以后可能要放宽）")
    func thresholdIsConfigurable() {
        var watchdog = FeedStarvationWatchdog(threshold: 1.5)
        #expect(!watchdog.tick(clockSeconds: 5.9, lastFedSeconds: 5.0))
        #expect(watchdog.tick(clockSeconds: 6.6, lastFedSeconds: 5.0))
    }
}
