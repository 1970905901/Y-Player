import CatVodCore

/// 播放页**自己换线路**所需的东西（M03P17）。
///
/// 对齐上游：播放页有一列线路条（`mBinding.flag` + `FlagAdapter`），点一条就 `mVod.selectFlag(item)` ——
/// 换到那条线路上的**同一集**接着看（`seamless()` 按集名找）。
///
/// 为什么要它：线路不稳是这类站点的常态；没有它就得「退回详情页 → 换线路 → 重新点那一集 → 再拖回原处」。
/// 与 ``PlaybackPlaylist`` 同一套做法：**播放页不认识站点**，「另一条线路上的那一集怎么取」由详情页包成闭包。
///
/// `public` 的理由同 ``PlaybackPlaylist``：`PlaybackView` 是 public，init 收这个类型。
public struct PlaybackLineSwitcher {
    /// 线路名（按详情页那一列的顺序）。
    public let lines: [String]
    /// 当前线路名。
    public let current: String
    /// 取「另一条线路上的同一集」：`episodeName` = 当前集名（可能为空），`index` = 当前线路内下标（兜底）。
    /// `nil` = 目标线路上找不到那一集（或拿不到地址）—— 播放页如实提示，不硬编一个地址。
    public let load: (String, String, Int) async -> PlaybackEpisodeResource?
    /// 换成了哪条线路（可选回传）：详情页据此把线路选择跟着换过来，回去时就停在刚看的这条线上。
    public let onLineChanged: ((String) -> Void)?

    public init(
        lines: [String],
        current: String,
        load: @escaping (String, String, Int) async -> PlaybackEpisodeResource?,
        onLineChanged: ((String) -> Void)? = nil
    ) {
        self.lines = lines
        self.current = current
        self.load = load
        self.onLineChanged = onLineChanged
    }

    /// 找「同一集」在目标线路上的下标（**纯函数**，有单测）：
    /// **先按集名**（线路之间的集数 / 顺序常常不一样），名字对不上（或没有名字）再按下标兜底，越界给 `nil`。
    public static func matchIndex(episodeName: String, index: Int, names: [String]) -> Int? {
        if !episodeName.isEmpty, let hit = names.firstIndex(of: episodeName) {
            return hit
        }
        return names.indices.contains(index) ? index : nil
    }
}
