import Foundation

/// 直播收藏频道（上游 `bean/Keep.java`，`type` 为直播的那一类）。
///
/// 上游只用 `Keep.key`（= **频道名**）匹配清单里的频道（`LiveConfig.applyKeepsToGroups`：
/// 拿收藏的 key 集合去过滤每个组的频道），所以本项目也只把**名字**当钥匙：
/// ``logo`` / ``group`` 是收藏当时的快照，仅用于「清单还没加载」时的显示，**不参与匹配**。
/// 上游另有 `vodName` / `vodPic` / `siteName` / `cid`，是同一张表服务点播的字段；
/// 本项目点播收藏另有 `FavoriteStore`（GRDB），所以这里只留直播需要的那几个。
public struct LiveFavorite: Codable, Sendable, Hashable, Identifiable {
    /// 频道名（上游 `Keep.key`）。
    public var name: String
    /// 收藏时的图标（上游 `Keep.vodPic`）。
    public var logo: String
    /// 收藏时所在的分组名（上游不给这个字段：收藏组里挂的是同一个 `Channel` 对象）。
    public var group: String
    /// 收藏时间（上游 `Keep.createTime`）。
    public var createdAt: Date

    public var id: String { name }

    public init(name: String, logo: String = "", group: String = "", createdAt: Date = Date()) {
        self.name = name
        self.logo = logo
        self.group = group
        self.createdAt = createdAt
    }
}
