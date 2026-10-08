import CatVodCore
import Foundation

// 直播页「可见即预取」的判定：哪些频道值得为它排队拉节目单。
//
// 与视图分开的理由和别处一致：这几条（没配接口地址 / 今天已经有了 / 已在队列 / 拉过又失败 /
// 到封顶）在真机上都要凑条件才能碰到，而写错的表现是「首屏还是不显示节目」或「滚一遍把源打穿」，
// 两种都只能靠人肉发现。纯函数才能把它们单测掉。

/// 直播页「可见即预取」的判定与默认封顶。
enum LiveEPGPrefetch {
    /// 一次进入直播页（或换一个分组）最多主动拉多少个频道。
    ///
    /// 一个频道走接口形态最多 3 个请求（昨天 / 今天 / 明天），12 个频道 ≈ 36 个请求，
    /// 大约一屏多一点。上限必须有：列表可能有几百个频道，滚一遍不能变成几百次请求。
    static let defaultBudget = 12

    /// 这个频道值不值得排进预取队列。
    ///
    /// 逐条对应一次「不值得」：
    /// - `channel.epg` 为空：没有 x-tvg 地址（清单里没写、源级也没有可展开的模板）。
    ///   仓库侧同条件会直接抛错，所以这里先挡掉，别白发请求；
    /// - 今天的节目单已经有了（文件形态覆盖今天，或之前拉过）：跳过 —— 这也是**跨天**重拉的入口，
    ///   昨天拉的那份在今天不再 `coversToday`，于是会被重新排队；
    /// - 已经在队列里 / 在飞；
    /// - 本次进入已经拉失败过（不重试）；
    /// - 本次进入的预取已经到顶（其余频道点开时仍会即时拉）。
    static func shouldQueue(_ channel: LiveChannel, state: LiveEPGPrefetchState, now: Date = Date()) -> Bool {
        guard !channel.epg.isEmpty else {
            return false
        }
        let key = channel.epgID
        guard !key.isEmpty, !state.pending.contains(key), !state.failed.contains(key) else {
            return false
        }
        if state.guide?.coversToday(key: key, now: now) ?? false {
            return false
        }
        return state.prefetched < state.budget
    }
}
