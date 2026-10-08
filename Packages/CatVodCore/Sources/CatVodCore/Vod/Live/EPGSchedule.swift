import Foundation

/// 某一天、某个频道的节目单（上游 `bean/Epg.java`）。
///
/// 上游把「频道 + 日期」收在 `Epg` 上：`key` 是频道标识（本项目用直播频道的 ``LiveChannel/epgID``），
/// `date` 是 `yyyy-MM-dd`（按直播源时区），`epg_data` 是当天的节目列表。
///
/// 两个必须照搬的行为：
/// 1. ``normalized(timeZone:)`` 对应上游 `Epg.setTime(zoneId)`：先整条去重（`LinkedHashSet`），
///    再把 `date + HH:mm[:ss]` 解析成绝对时间，**结束早于开始时给结束补一天**（跨天节目）；
/// 2. ``currentIndex(at:)`` 对应上游 `getInRange()`：返回「正在播」的下标（没有则 `nil`），界面用它滚动到当前节目。
public struct EPGSchedule: Sendable, Hashable, Identifiable {
    /// 频道标识（直播频道的 ``LiveChannel/epgID``）。
    public var key: String
    /// `yyyy-MM-dd`（直播源时区）。
    public var date: String
    /// 当天节目（按时间顺序）。
    public var programs: [EPGProgram]

    public var id: String {
        key + "@" + date
    }

    public init(key: String, date: String, programs: [EPGProgram] = []) {
        self.key = key
        self.date = date
        self.programs = programs
    }

    /// 上游 `Epg.setTime(zoneId)`：去重 + 时间解析 + 跨天补一天。
    ///
    /// 说明：上游这里还会做繁简转换（`Trans.s2t`），本项目不做（见 `docs/协议兼容矩阵.md`）。
    public func normalized(timeZone: TimeZone) -> EPGSchedule {
        var seen = Set<EPGProgram>()
        var result: [EPGProgram] = []
        for program in programs where seen.insert(program).inserted {
            var normalized = program
            normalized.startTime = EPGTimeParser.parse(date: date, time: program.start, timeZone: timeZone)
            normalized.endTime = EPGTimeParser.parse(date: date, time: program.end, timeZone: timeZone)
            if normalized.crossesMidnight {
                // 结束早于开始 = 跨天（上游 `EpgData.checkDay`：给结束时间加一天）。
                normalized.endTime = normalized.endTime.addingTimeInterval(24 * 60 * 60)
            }
            result.append(normalized)
        }
        var schedule = self
        schedule.programs = result
        return schedule
    }

    /// 上游 `getInRange()`：正在播的节目下标。
    public func currentIndex(at now: Date = Date()) -> Int? {
        programs.firstIndex { $0.isLive(at: now) }
    }

    /// 正在播的节目（没有则 `nil`）。
    public func currentProgram(at now: Date = Date()) -> EPGProgram? {
        guard let index = currentIndex(at: now) else {
            return nil
        }
        return programs[index]
    }

    /// 接下来要播的节目（没有则 `nil`）—— 界面「下一档」用。
    public func nextProgram(at now: Date = Date()) -> EPGProgram? {
        programs.first { $0.isFuture(at: now) }
    }
}
