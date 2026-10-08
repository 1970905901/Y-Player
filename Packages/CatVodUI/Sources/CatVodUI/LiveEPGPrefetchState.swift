import CatVodCore
import Foundation

/// 直播页「可见即预取」要用的状态（判定规则收成一个值，才能纯函数单测）。
///
/// 为什么要预取：x-tvg 接口形态是**逐频道**拉的（上游 `LiveApi.getEpg` 只对当前选中的频道拉），
/// 所以列表首屏如果什么都不拉，每一行都显示「暂无节目」。预取就是「行露面时顺手排队拉它」，
/// 代价是请求量会随滚动增长，因此状态里必须有 `pending` / `failed` / `prefetched` 三个刹车。
struct LiveEPGPrefetchState: Sendable {
    /// 这个频道当前可用的节目单（接口形态按频道存，文件形态一份覆盖多频道）。
    var guide: EPGGuide?
    /// 已经排队 / 在飞的 `epgID`。
    var pending: Set<String>
    /// 本次进入已经拉过但**失败**的 `epgID`（失败不重试：滚动来回会把它变成重试风暴）。
    var failed: Set<String>
    /// 本次进入已经真正发起过的请求数（按频道计，一个频道最多 3 个请求）。
    var prefetched: Int
    /// 封顶。
    var budget: Int
}
