import Foundation

/// 播放记录的**展示元数据**。
///
/// 为什么与 ``PlaybackProgress`` 分开：进度只关心「看到哪」，而「追剧（播放历史）」
/// 列表还要显示片名 / 封面 / 站源 / 线路 / 集名。这些都只在**播放时刻**最可靠
/// （详情页刚拿到 `vod` 与线路），随进度一起记下来，列表就不必再向站点请求一次详情，
/// 断网时也能显示。
public struct PlaybackEntryMetadata: Sendable, Hashable {
    /// 影片名；空串表示未知（界面回退到 `vodID`）。
    public var vodName: String
    /// 封面图地址（`VodItem.vodPic` 或详情返回的 `artwork`）。
    public var picture: String
    /// 站点展示名（`Site.name` 为空时由调用方回退到 `Site.key`）。
    public var siteName: String
    /// 线路名（协议里的 `flag`）。
    public var lineName: String
    /// 集名（例如 `完美.S01E266 [853MB]`）。
    public var episodeName: String

    public init(
        vodName: String = "",
        picture: String = "",
        siteName: String = "",
        lineName: String = "",
        episodeName: String = ""
    ) {
        self.vodName = vodName
        self.picture = picture
        self.siteName = siteName
        self.lineName = lineName
        self.episodeName = episodeName
    }
}

/// 一次播放的进度上下文：进度键 + 集下标 + 展示元数据。
///
/// ``PlaybackView`` 只接收这一个参数（而不是拆成四个），由调用方
/// （详情页 / Spider 播放入口）把「哪部片、哪一集、哪条线路」组装好。
public struct PlaybackProgressContext: Sendable, Hashable {
    public var key: PlaybackKey
    /// 当前集在**线路内**的下标（`-1` 表示未知；跨线路对齐留 M8）。
    public var episodeIndex: Int
    public var metadata: PlaybackEntryMetadata

    public init(
        key: PlaybackKey,
        episodeIndex: Int = -1,
        metadata: PlaybackEntryMetadata = PlaybackEntryMetadata()
    ) {
        self.key = key
        self.episodeIndex = episodeIndex
        self.metadata = metadata
    }
}
