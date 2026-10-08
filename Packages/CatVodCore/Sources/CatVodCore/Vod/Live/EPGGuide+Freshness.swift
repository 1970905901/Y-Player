import Foundation

/// 节目单的「今天」判断（界面据此决定要不要再拉一次）。
///
/// 上游把节目单落盘，并按「不是今天 / 超过 6 小时」判刷新（`EpgParser.refreshReason`）；
/// 本项目不落盘，内存里那份 guide 只要同一口径的一半：**缺今天**就重拉
/// （应用跨天没重启、换源、首次进入）。「6 小时」那一半不需要 —— 进程重启内存缓存就没了。
extension EPGGuide {
    /// 某**频道**的今天有没有节目单（按这份节目单自己的时区算「今天」）。
    ///
    /// 用途：x-tvg 接口形态是逐频道拉的，按这个键判断「这个频道今天已经拿过了，别再请求」。
    public func coversToday(key: String, now: Date = Date()) -> Bool {
        contains(key: key, date: EPGTimeParser.dateString(dayOffset: 0, timeZone: timeZone, from: now))
    }

    /// **整份**节目单里有没有今天这一天（任意频道都算）。
    ///
    /// 用途：文件形态（`epg` 里的 `.xml` / `.gz`）一份就覆盖几百个频道，
    /// 粒度只能是「这一份还新不新」—— 文件里今天一个频道都没有，就说明该重下了。
    public func coversToday(now: Date = Date()) -> Bool {
        let today = EPGTimeParser.dateString(dayOffset: 0, timeZone: timeZone, from: now)
        return schedules.contains { $0.date == today }
    }
}
