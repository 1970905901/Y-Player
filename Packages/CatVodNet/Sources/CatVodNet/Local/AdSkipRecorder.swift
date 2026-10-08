import CatVodCore
import Foundation

/// 广告跳过的**统计**（`/m3u8` 每次清理后记一笔；播放页据此提示「已跳过 N 段」，M06k）。
///
/// 为什么要有这个盒子：清理发生在**本机服务的线程池**里，而提示要显示在主线程的界面上 ——
/// 直接共享可变状态就是数据竞争。这里是「锁保护 + 回调」的小盒子，与 `StorageFailureRecorder` 同一套路。
///
/// `@unchecked Sendable` 的成立条件：**所有可变状态都在锁内访问**。
public final class AdSkipRecorder: @unchecked Sendable {
    /// 累计统计。
    public struct Stats: Sendable, Equatable {
        /// 处理过的清单数量（包括「走了清理器但没什么可删」的）。
        public var playlists: Int
        /// 其中**真删过东西**的清单数量。
        public var cleanedPlaylists: Int
        /// 累计删掉的片段数。
        public var removedSegments: Int
        /// 累计删掉的时长（秒）。
        public var removedDurationSec: Double

        public init(
            playlists: Int = 0,
            cleanedPlaylists: Int = 0,
            removedSegments: Int = 0,
            removedDurationSec: Double = 0
        ) {
            self.playlists = playlists
            self.cleanedPlaylists = cleanedPlaylists
            self.removedSegments = removedSegments
            self.removedDurationSec = removedDurationSec
        }
    }

    private let lock = NSLock()
    private var value = Stats()
    private var listener: (@Sendable (Stats) -> Void)?

    public init() { }

    /// 记一次清理结果。
    ///
    /// **只有真删过东西**才回调监听者：播放页关心的是「这次真跳过广告了」，
    /// 每个清单都弹一次提示会变成噪音（一个片子几十个清单）。
    public func record(_ result: HLSManifestCleaner.Result) {
        lock.lock()
        value.playlists += 1
        if result.removedSegments > 0 {
            value.cleanedPlaylists += 1
            value.removedSegments += result.removedSegments
            value.removedDurationSec += result.removedDurationSec
        }
        let snapshot = value
        let notify = result.removedSegments > 0 ? listener : nil
        lock.unlock()
        notify?(snapshot)
    }

    /// 当前统计。
    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// 清空（换片时用）。
    public func reset() {
        lock.lock()
        value = Stats()
        lock.unlock()
    }

    /// 监听「真跳过了」这件事。回调在**后台线程**发出，界面侧要自己跳回主线程。
    public func setListener(_ listener: (@Sendable (Stats) -> Void)?) {
        lock.lock()
        self.listener = listener
        lock.unlock()
    }
}
