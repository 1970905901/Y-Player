import CatVodCore

/// 播放页**自己选弹幕**所需的东西（M03P25，对齐上游 `DanmakuDialog` / `DanmakuSearchDialog`）。
///
/// 上游那条：播放页的弹幕按钮开一张 bottom sheet，列出**这一集的候选来源**（`PlaySpec.danmakus`），
/// 点一条就 `player.setDanmaku(item)` 换过去；右上还有「搜索」（换关键词重搜）与「设置」（显示参数）。
/// 与 ``PlaybackLineSwitcher`` 同一套做法：**播放页不认识站点 / 接口**，候选与动作都由宿主包好传进来。
///
/// `public` 的理由同 ``PlaybackPlaylist`` / ``PlaybackLineSwitcher``：`PlaybackView` 是 public，
/// init 收这个类型。
public struct PlaybackDanmakuSwitcher {
    /// 这一集的候选（站点自带的在前、搜索到的在后，按 `id` 去重）。
    public let candidates: [DanmakuSource]
    /// 手动选中的那条；`nil` = 自动（站点自带 → 搜索到的第一条）。
    public let selected: DanmakuSource?
    /// 一行状态（加载中 / 已加载 N 条 / 没搜到 / 失败原因）；空串 = 不显示。
    public let status: String
    /// 换一条（`nil` = 回到自动）。
    public let select: (DanmakuSource?) async -> Void
    /// 换关键词重搜（片名 / 集名）；`nil` = 搜到了，有值 = 失败原因。
    public let search: (String, String) async -> String?

    public init(
        candidates: [DanmakuSource],
        selected: DanmakuSource?,
        status: String,
        select: @escaping (DanmakuSource?) async -> Void,
        search: @escaping (String, String) async -> String?
    ) {
        self.candidates = candidates
        self.selected = selected
        self.status = status
        self.select = select
        self.search = search
    }

    /// 候选列表的拼法（**纯函数**，有单测）：站点自带的在前（它跟片源对得上），搜索到的在后；
    /// 同一个 `id`（名字 + 地址）只留最先出现的那条。
    public static func candidates(embedded: [DanmakuSource], searched: [DanmakuSource]) -> [DanmakuSource] {
        var seen = Set<String>()
        return (embedded + searched).filter { seen.insert($0.id).inserted }
    }
}
