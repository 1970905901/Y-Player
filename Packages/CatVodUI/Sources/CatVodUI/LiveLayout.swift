import CatVodCore
import Foundation

// 直播页（`LiveView`）的纯逻辑：分组行、频道行、节目文案。
//
// 与视图分开的理由和发现页一致 —— 这几处「上游不一定给」的分支在真机上很难造出来：
// 清单里没写 `tvg-id` / `tvg-name`（匹配只能落到频道名）、源没配节目单（整页都要显示「暂无节目」）、
// 频道地址里有 `/PLTV/` 却没写 catchup（时移入口要自动出现）。纯函数才能把这些都单测掉。

/// 直播页左侧分组列表的一行。
struct LiveGroupRow: Identifiable, Equatable {
    /// 分组名（已去掉 `_密码` 后缀）。
    var name: String
    /// 分组里的频道数。
    var count: Int
    /// 是否是加密分组（上游 `Group.isHidden`：组名带 `_密码`）。
    var isHidden: Bool

    var id: String { name }
}

/// 直播页频道列表的一行。
///
/// 字段都在这里算好：视图不做「先找 EPG 再回落」这类判断，免得同一口径在列表与播放页各写一遍。
struct LiveChannelRow: Identifiable, Equatable {
    /// 原始频道（播放要用它的 `urls` / header / catchup）。
    var channel: LiveChannel
    /// 频道号（解析时补的 `001`…；上游也允许清单自带 `tvg-chno`）。
    var number: String
    /// 显示名：EPG 的 `<display-name>` 优先，否则清单里的名字。
    var title: String
    /// 图标：EPG 的 `<icon src>` 回填，否则清单里的 `logo`。
    var logo: String
    /// 「正在播」文案（`19:00 ~ 19:30  新闻联播`）；没有节目单时为空串。
    var currentText: String
    /// 「下一档」文案；没有则为空串。
    var nextText: String
    /// 当前线路能不能时移（含 `/PLTV/` 自动套用的内置规则）。
    var hasCatchup: Bool
    /// 有没有可用地址（没有就点不动，界面按上游给「无地址」提示）。
    var isPlayable: Bool

    var id: String { channel.id }
}

/// 直播页的行模型构造。
enum LiveListLayout {
    /// 分组列表：**保持清单里的分组顺序**（上游也是这个顺序），并带上频道数。
    static func groupRows(_ source: LiveSource) -> [LiveGroupRow] {
        source.groups.map { group in
            LiveGroupRow(name: group.name, count: group.channels.count, isHidden: group.isHidden)
        }
    }

    /// 某个分组的频道行（顺序即清单顺序）。
    static func channelRows(_ group: LiveGroup, guide: EPGGuide?, at now: Date = Date()) -> [LiveChannelRow] {
        group.channels.map { row($0, guide: guide, at: now) }
    }

    /// 单个频道行。
    ///
    /// - `guide` 为 `nil` 表示这个源没有节目单（或还没拉到）：节目文案给空串，界面显示「暂无节目」，
    ///   名字与图标回落清单里的值；
    /// - 匹配键用 ``LiveChannel/epgID``（`tvg-id` → `tvg-name` → 频道名三级回落，M07a）。
    static func row(_ channel: LiveChannel, guide: EPGGuide?, at now: Date) -> LiveChannelRow {
        let key = channel.epgID
        return LiveChannelRow(
            channel: channel,
            number: channel.number,
            title: guide?.displayName(for: key, fallback: channel.name) ?? channel.name,
            logo: guide?.logo(for: key, fallback: channel.logo) ?? channel.logo,
            currentText: guide?.currentProgram(key: key, at: now)?.formatted ?? "",
            nextText: guide?.nextProgram(key: key, at: now)?.formatted ?? "",
            hasCatchup: channel.catchupForCurrentURL() != nil,
            isPlayable: !channel.urls.isEmpty
        )
    }
}
