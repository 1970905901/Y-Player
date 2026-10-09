@testable import CatVodCore
@testable import CatVodNet
import Foundation
import Testing

/// 广告跳过统计（M06k）—— 一个锁保护的小盒子。
///
/// 盯两件事：**只有真删过东西才回调**（每个清单都弹提示会变噪音，一个片子几十个清单），
/// 以及「处理过几个清单」与「其中几个真清了」是两个不同的数 —— 混起来会让提示虚报。
@Suite("广告跳过统计")
struct AdSkipRecorderTests {
    private func result(removed: Int, duration: Double, changed: Bool = true) -> HLSManifestCleaner.Result {
        HLSManifestCleaner.Result(
            manifest: "#EXTM3U",
            changed: changed,
            fallback: false,
            removedSegments: removed,
            removedDurationSec: duration,
            // 逐条规则的命中次数（M06k 起的统计字段，无默认值，且在 removedSegmentDetails **之前**）。
            // 这个测试不关心命中明细，给空。
            ruleCounts: [:],
            removedSegmentDetails: []
        )
    }

    @Test("真删过：计数累加，并且回调一次")
    func recordsRemoval() {
        let recorder = AdSkipRecorder()
        let calls = LockedCounter()
        recorder.setListener { stats in
            calls.mark(stats.removedSegments)
        }

        recorder.record(result(removed: 2, duration: 12))

        #expect(recorder.stats.playlists == 1)
        #expect(recorder.stats.cleanedPlaylists == 1)
        #expect(recorder.stats.removedSegments == 2)
        #expect(recorder.stats.removedDurationSec == 12)
        #expect(calls.values == [2])

        recorder.record(result(removed: 1, duration: 7))

        #expect(recorder.stats.removedSegments == 3)
        #expect(calls.values == [2, 3])
    }

    @Test("没删东西（或者走了安全阀回落）：只记「处理过」，不回调")
    func noCallbackWithoutRemoval() {
        let recorder = AdSkipRecorder()
        let calls = LockedCounter()
        recorder.setListener { _ in calls.mark(0) }

        recorder.record(result(removed: 0, duration: 0, changed: false))

        #expect(recorder.stats.playlists == 1)
        #expect(recorder.stats.cleanedPlaylists == 0)
        #expect(recorder.stats.removedSegments == 0)
        #expect(calls.values.isEmpty)
    }

    @Test("清空后回到初始；监听器设成 nil 就不再收到通知")
    func resetAndClearListener() {
        let recorder = AdSkipRecorder()
        let calls = LockedCounter()
        recorder.setListener { _ in calls.mark(0) }

        recorder.record(result(removed: 1, duration: 5))
        recorder.reset()
        #expect(recorder.stats == AdSkipRecorder.Stats())

        recorder.setListener(nil)
        recorder.record(result(removed: 1, duration: 5))
        #expect(calls.values.count == 1)
    }
}

/// 线程安全的计数标记（测试里断言「回调了几次、带了什么值」）。
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func mark(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
