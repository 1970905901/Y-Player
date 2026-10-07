import CatVodCore
import Foundation

/// 播放进度（跨端记忆：退出后能续播）。
///
/// 范围说明（M2）：本类型与 ``PlaybackProgressStore`` 是**接口预留 + 可用实现**：
/// - M2 先给内存实现（进程内有效），UI 按协议编写，**不感知**底层存储；
/// - M8 用 GRDB 落库时实现同一协议即可，UI 与 PlaybackView 不需要改。
/// - `AppDatabase.playbackPosition(vodKey:)` 那对方法将在 M8 收敛到本协议（保留现状以免破坏已有接口）。
public struct PlaybackProgress: Sendable, Hashable {
    public var key: PlaybackKey
    /// 已播放位置（秒）。
    public var position: Double
    /// 总时长（秒）；未知为 0。
    public var duration: Double
    /// 是否已看完（看完后再进应从头上播）。
    public var isFinished: Bool
    /// 最近观看的集下标（**当前线路内**，从 0 开始）；`-1` 表示未知。
    ///
    /// 说明：M2 只记录「线路内下标」——跨线路/跨站的集身份对齐（用集名或 url 匹配）留给 M8 一起做。
    public var episodeIndex: Int
    public var updatedAt: Date
    /// 展示元数据（片名 / 封面 / 站源 / 线路 / 集名）：供「追剧（播放历史）」列表直接渲染，
    /// 不必再请求详情。老记录（未带元数据）各字段为空串，界面按空值降级显示。
    public var metadata: PlaybackEntryMetadata

    /// 影片名（`metadata` 的透传，列表与详情页用）。
    public var vodName: String { metadata.vodName }
    /// 站点展示名。
    public var siteName: String { metadata.siteName }
    /// 线路名（协议里的 `flag`）。
    public var lineName: String { metadata.lineName }
    /// 集名。
    public var episodeName: String { metadata.episodeName }
    /// 封面图地址。
    public var picture: String { metadata.picture }
    /// 列表展示用的片名：片名为空时回退到 `vodID`。
    public var displayName: String { metadata.vodName.isEmpty ? key.vodID : metadata.vodName }

    public init(
        key: PlaybackKey,
        position: Double = 0,
        duration: Double = 0,
        isFinished: Bool = false,
        episodeIndex: Int = -1,
        updatedAt: Date = Date(),
        metadata: PlaybackEntryMetadata = PlaybackEntryMetadata()
    ) {
        self.key = key
        self.position = max(position, 0)
        self.duration = max(duration, 0)
        self.isFinished = isFinished
        self.episodeIndex = episodeIndex
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    /// 续播位置。
    ///
    /// 两个防空档：**已看完**、或进度**过短**（默认 5 秒，多半是误触）→ 一律从头播，
    /// 否则用户会「点进去就停在片头几秒」而莫名其妙。
    public func resumePosition(minimumSeconds: Double = 5) -> Double {
        guard !isFinished, position >= minimumSeconds else {
            return 0
        }
        return position
    }

    /// 播放进度比例（0...1）；时长未知时为 0。
    public var fraction: Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(position / duration, 0), 1)
    }

    /// 是否为「看完」或「接近看完（≥95%）」。
    public var isEffectivelyFinished: Bool {
        isFinished || fraction >= 0.95
    }
}

/// 播放进度存储协议。
///
/// M8 的 GRDB 实现必须满足同一契约（`Sendable` + 四个 `async` 方法），
/// 这样 `AppModel` 里换实现时 UI 一行都不用改。
public protocol PlaybackProgressStore: Sendable {
    func progress(for key: PlaybackKey) async -> PlaybackProgress?
    func save(_ progress: PlaybackProgress) async
    func clear(for key: PlaybackKey) async
    /// 全部记录，按更新时间倒序（用于「继续观看」列表，M8 接 GRDB 后同样语义）。
    func all() async -> [PlaybackProgress]
}

/// 内存实现：M2 可直接使用（进程内有效），也是单测的默认实现。
public actor InMemoryPlaybackProgressStore: PlaybackProgressStore {
    private var storage: [String: PlaybackProgress] = [:]

    public init() { }

    public func progress(for key: PlaybackKey) -> PlaybackProgress? {
        storage[key.storageKey]
    }

    public func save(_ progress: PlaybackProgress) {
        storage[progress.key.storageKey] = progress
    }

    public func clear(for key: PlaybackKey) {
        storage[key.storageKey] = nil
    }

    public func all() -> [PlaybackProgress] {
        storage.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 记录条数（测试与诊断用）。
    public func count() -> Int {
        storage.count
    }
}
