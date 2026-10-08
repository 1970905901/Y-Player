import Foundation

/// 播放页（详情页）的显示视图（设置 → 播放 → 播放页 → 显示视图）。
///
/// 对应参考图上的「精简视图 / Emby 视图」二选一菜单：**两种视图共用同一份数据**
/// （影片信息、线路、选集、收藏与进度都不变），只换排布，因此它只是个界面偏好。
///
/// 持久化在 `UserDefaults`（键 `yplayer.playbackPageLayout`），与展示方式/播放内核同一套做法。
public enum PlaybackPageLayout: String, Sendable, CaseIterable, Hashable {
    /// 精简视图：一行行文字信息 + 线路分段控件 + 选集列表（默认，等同 M2 的详情页观感）。
    case compact
    /// Emby 视图：大封面 + 片名/评分行 + 横向滚动的线路与选集卡片（Emby 客户端的排布方式）。
    case emby

    /// 界面展示名（设置页与详情页共用）。
    public var displayName: String {
        switch self {
        case .compact: "精简视图"
        case .emby: "Emby 视图"
        }
    }

    /// 设置页的说明（写清两种视图的区别，避免用户靠猜）。
    public var summary: String {
        switch self {
        case .compact:
            "信息行 + 线路分段控件 + 选集列表，一屏能看全文字信息。"
        case .emby:
            "大封面 + 横向滚动的线路/选集卡片，接近 Emby 客户端的排布；信息更少，点选更快。"
        }
    }
}
