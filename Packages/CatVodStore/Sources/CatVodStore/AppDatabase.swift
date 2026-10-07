import CatVodCore
import Foundation

/// 数据存储抽象。
///
/// M2 引入 GRDB 后由 `GRDBAppDatabase` 实现；此处先定义接口，让上层（UI/播放进度）
/// 不依赖具体存储实现，也便于在 M1/M2 用内存实现做测试。
public protocol AppDatabase: Sendable {
    func sites() async throws -> [Site]
    func upsert(sites: [Site]) async throws
    func playbackPosition(vodKey: String) async throws -> Double?
    func save(playbackPosition: Double, vodKey: String) async throws
    func searchHistory() async throws -> [String]
    func append(searchKeyword: String) async throws
}

/// 站点唯一键：站点 key + 视频 ID。
public struct PlaybackKey: Sendable, Hashable {
    public var siteKey: String
    public var vodID: String

    public init(siteKey: String, vodID: String) {
        self.siteKey = siteKey
        self.vodID = vodID
    }

    /// 持久化用字符串键。
    public var storageKey: String {
        "\(siteKey)#\(vodID)"
    }
}
