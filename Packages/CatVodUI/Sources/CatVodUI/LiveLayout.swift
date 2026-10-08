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
    /// 是否是「收藏」分组（运行时分组，不在清单里）。
    var isKeep: Bool
    /// 是否是「解锁加密分组」那一行（也不是真实分组）。
    var isLockEntry: Bool

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
    /// 是不是「上次观看」的那个频道（界面加个小标记）。
    var isLastWatched: Bool
    /// 打开这个频道时先用第几条线路（上次看的那一条；不是上次那个频道就是 0）。
    var initialLineIndex: Int

    var id: String { channel.id }
}

/// 直播页的行模型构造。
enum LiveListLayout {
    /// 分组条的行：**「收藏」在最前**（上游 `LiveApi.parse` 把 `Group.create(R.string.keep)` 插到第 0 组），
    /// 中间按清单顺序，最后是「解锁加密分组」那一行（有锁着的加密分组时才给）。
    ///
    /// 传进来的 `groups` 应该是 ``LiveGroupAccess/visible(_:unlocked:)`` 过滤后的那份 ——
    /// **锁着的加密分组不该出现在这里**（上游把它们收在 `mHides` 里），所以这个函数不负责判断。
    ///
    /// 上游只在「清单的第 0 组不是收藏组」时才插收藏组（`groups.get(0).isKeep()`），这里防的是同一种情况；
    /// 源自己就有一个叫「收藏」的组、又不在首位时会出现两个同名行 —— 上游有同样的毛病，不额外发明规则。
    static func groupRows(_ groups: [LiveGroup], favoriteCount: Int = 0, lockedCount: Int = 0) -> [LiveGroupRow] {
        var rows = groups.map { group in
            LiveGroupRow(name: group.name, count: group.channels.count, isHidden: group.isHidden, isKeep: group.isKeep, isLockEntry: false)
        }
        if favoriteCount > 0, rows.first?.isKeep != true {
            rows.insert(
                LiveGroupRow(name: LiveGroup.keepName, count: favoriteCount, isHidden: false, isKeep: true, isLockEntry: false),
                at: 0
            )
        }
        if lockedCount > 0 {
            rows.append(
                LiveGroupRow(name: "解锁加密分组", count: lockedCount, isHidden: true, isKeep: false, isLockEntry: true)
            )
        }
        return rows
    }

    /// 某个分组的频道行（顺序即清单顺序）。
    static func channelRows(
        _ group: LiveGroup,
        guide: EPGGuide?,
        resume: LiveKeepTarget? = nil,
        at now: Date = Date()
    ) -> [LiveChannelRow] {
        group.channels.map { row($0, guide: guide, resume: resume, at: now) }
    }

    /// 单个频道行。
    ///
    /// - `guide` 为 `nil` 表示这个源没有节目单（或还没拉到）：节目文案给空串，界面显示「暂无节目」，
    ///   名字与图标回落清单里的值；
    /// - 匹配键用 ``LiveChannel/epgID``（`tvg-id` → `tvg-name` → 频道名三级回落，M07a）；
    /// - `resume` 是「上次观看」（M07c-3）：命中这个频道就带上「上次」标记与上次的线路下标。
    ///   线路下标在 ``LiveKeep/resolve(in:)`` 里已收敛；**没有地址的频道不算命中** ——
    ///   点了也播不了，标「上次」只会误导。
    static func row(
        _ channel: LiveChannel,
        guide: EPGGuide?,
        resume: LiveKeepTarget? = nil,
        at now: Date
    ) -> LiveChannelRow {
        let key = channel.epgID
        let resumedLine = lastWatchedLine(of: channel, resume: resume)
        return LiveChannelRow(
            channel: channel,
            number: channel.number,
            title: guide?.displayName(for: key, fallback: channel.name) ?? channel.name,
            logo: guide?.logo(for: key, fallback: channel.logo) ?? channel.logo,
            currentText: guide?.currentProgram(key: key, at: now)?.formatted ?? "",
            nextText: guide?.nextProgram(key: key, at: now)?.formatted ?? "",
            hasCatchup: channel.catchupForCurrentURL() != nil,
            isPlayable: !channel.urls.isEmpty,
            isLastWatched: resumedLine != nil,
            initialLineIndex: resumedLine ?? 0
        )
    }

    /// 「上次观看」命中这个频道时该用第几条线路；不命中 / 没地址时为 `nil`。
    private static func lastWatchedLine(of channel: LiveChannel, resume: LiveKeepTarget?) -> Int? {
        guard let resume, resume.channel == channel, resume.isPlayable else {
            return nil
        }
        return resume.lineIndex
    }

    /// 线路的显示名：清单写了 `地址$线路名` 就用它，否则按「线路 N」（上游用资源字符串，属界面职责）。
    static func lineTitle(channel: LiveChannel, lineIndex: Int) -> String {
        channel.lineName(index: lineIndex) ?? "线路 \(lineIndex + 1)"
    }
}

/// 当天节目单里的一行（时移回看用）。
struct LiveProgramRow: Identifiable, Equatable {
    /// 节目标题。
    var title: String
    /// `19:00 ~ 19:30`（``EPGProgram/timeRange``）。
    var timeRange: String
    /// 这一档处在什么状态（界面用它高亮 / 置灰）。
    var state: LiveProgramState
    /// 时移地址；`nil` 表示这一档点不动（没配时移、或节目还没开始）。
    var catchupURL: String?

    var id: String { timeRange + "|" + title }
}

/// 节目状态：决定界面高亮与能不能点。
enum LiveProgramState: String, Equatable {
    /// 正在播。
    case live
    /// 已结束（有时移就能回看）。
    case past
    /// 还没开始（不给地址：上游 `LiveApi.getUrl(item, data)` 只对已播的档给时移）。
    case future
}

extension LiveListLayout {
    /// 一个频道的当天节目行（保持节目单顺序）。
    ///
    /// 三件事在这里定死，界面不再判断：
    /// - **状态**：`isLive` / `isFuture` / 其余算已播（``EPGProgram`` 的既有语义）；
    /// - **时移地址**：只有「已播 + 这条线路配了时移」才拼 ``LiveCatchup/playbackURL(_:start:end:)``
    ///   （``LiveChannel/catchupForCurrentURL(index:)`` 已经处理了 `regex` 命中与 `/PLTV/` 自动套用）——
    ///   `lineIndex` 就是「按哪条线路拼」，与直播页打开频道时用的是同一条（M07c-3）；
    /// - **没有节目单**：返回空数组，界面显示「暂无节目单」。
    static func programRows(
        channel: LiveChannel,
        schedule: EPGSchedule?,
        lineIndex: Int = 0,
        at now: Date = Date()
    ) -> [LiveProgramRow] {
        guard let schedule else {
            return []
        }
        let catchup = channel.catchupForCurrentURL(index: lineIndex)
        let liveURL = channel.playbackURL(index: lineIndex)
        return schedule.programs.map { program in
            let state = state(of: program, at: now)
            let catchupURL = state == .past ? catchup?.playbackURL(liveURL, start: program.startTime, end: program.endTime) : nil
            return LiveProgramRow(
                title: program.title,
                timeRange: program.timeRange,
                state: state,
                catchupURL: catchupURL
            )
        }
    }

    /// 单档状态：`isLive` 优先（上游也是先看「正在播」）。
    static func state(of program: EPGProgram, at now: Date) -> LiveProgramState {
        if program.isLive(at: now) {
            return .live
        }
        return program.isFuture(at: now) ? .future : .past
    }
}
