import CatVodCore
import Foundation

/// 收藏条目。
///
/// 唯一键与播放进度一致（``PlaybackKey``：站点 key + 视频 ID），因此「收藏」与
/// 「看到哪」天然一一对应 —— 详情页的两个入口共用同一个键，不需要额外的映射表。
public struct Favorite: Sendable, Hashable, Identifiable {
    public var key: PlaybackKey
    /// 影片名；空串表示未知（界面回退到 `vodID`）。
    public var vodName: String
    /// 封面图地址。
    public var picture: String
    /// 站点展示名。
    public var siteName: String
    /// 收藏时所处线路名（协议里的 `flag`）。
    public var lineName: String
    /// 收藏时的集名（可为空：整片收藏）。
    public var episodeName: String
    public var addedAt: Date

    /// 列表用的稳定标识（`站点 key#视频 ID`）。
    public var id: String { key.storageKey }

    public init(
        key: PlaybackKey,
        vodName: String = "",
        picture: String = "",
        siteName: String = "",
        lineName: String = "",
        episodeName: String = "",
        addedAt: Date = Date()
    ) {
        self.key = key
        self.vodName = vodName
        self.picture = picture
        self.siteName = siteName
        self.lineName = lineName
        self.episodeName = episodeName
        self.addedAt = addedAt
    }

    /// 用播放记录 / 详情页的展示元数据构造收藏。
    public init(key: PlaybackKey, metadata: PlaybackEntryMetadata, addedAt: Date = Date()) {
        self.init(
            key: key,
            vodName: metadata.vodName,
            picture: metadata.picture,
            siteName: metadata.siteName,
            lineName: metadata.lineName,
            episodeName: metadata.episodeName,
            addedAt: addedAt
        )
    }
}

/// 收藏存储协议。
///
/// 与 ``PlaybackProgressStore`` 同一形态（`Sendable` + `async`）：M8 用 GRDB 落库时
/// 实现同一协议即可，`AppModel` 与界面一行都不用改。
public protocol FavoriteStore: Sendable {
    /// 全部收藏，按收藏时间倒序。
    func favorites() async -> [Favorite]
    func favorite(for key: PlaybackKey) async -> Favorite?
    func add(_ favorite: Favorite) async
    func remove(for key: PlaybackKey) async
    /// 批量删除（「追剧」页多选删除）。
    func removeAll(for keys: [PlaybackKey]) async
    /// 收藏条数（测试与诊断用）。
    func count() async -> Int
}

/// 内存实现：M2 可直接使用（进程内有效），也是单测的默认实现。
///
/// 落库（GRDB）在 M8：届时只需替换 `AppModel.favoriteStore` 的构造，
/// 「追剧」页与详情页按协议编写、不感知底层实现。
public actor InMemoryFavoriteStore: FavoriteStore {
    private var storage: [String: Favorite] = [:]

    public init() { }

    public func favorites() -> [Favorite] {
        storage.values.sorted { $0.addedAt > $1.addedAt }
    }

    public func favorite(for key: PlaybackKey) -> Favorite? {
        storage[key.storageKey]
    }

    public func add(_ favorite: Favorite) {
        storage[favorite.key.storageKey] = favorite
    }

    public func remove(for key: PlaybackKey) {
        storage[key.storageKey] = nil
    }

    public func removeAll(for keys: [PlaybackKey]) {
        for key in keys {
            storage[key.storageKey] = nil
        }
    }

    public func count() -> Int {
        storage.count
    }
}
