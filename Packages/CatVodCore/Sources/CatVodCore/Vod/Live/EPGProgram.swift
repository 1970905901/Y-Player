import Foundation

/// 一条节目单（上游 `bean/EpgData.java`）。
///
/// 字段分两类：
/// - **展示串** `start`/`end`：按直播源时区格式化的 `HH:mm`（上游就用 `Formatters.TIME` 输出字符串，
///   界面与「时移时间模板」都吃它）；
/// - **绝对时间** `startTime`/`endTime`：EPG 解析时算好的 `Date`。
///
/// 取值语义逐条对齐上游：`isInRange`（正在播）/`isFuture`（未开始）/`format()`（`开始 ~ 结束  标题`）/
/// `getTime()`（`开始 ~ 结束`）/`getRange()`（`clock=yyyyMMdd'T'HHmmss'Z'-…`，UTC，用于向 x-tvg 类接口按时间窗拉取）。
public struct EPGProgram: Sendable, Hashable, Identifiable {
    /// 节目标题。
    public var title: String
    /// 开始时间（`HH:mm`，直播源时区）。
    public var start: String
    /// 结束时间（`HH:mm`，直播源时区）。
    public var end: String
    /// 开始时间（绝对时间）。
    public var startTime: Date
    /// 结束时间（绝对时间）。
    public var endTime: Date

    public var id: String {
        "\(start)-\(end)-\(title)"
    }

    public init(title: String, start: String, end: String, startTime: Date, endTime: Date) {
        self.title = title
        self.start = start
        self.end = end
        self.startTime = startTime
        self.endTime = endTime
    }

    /// 上游 `isInRange()`：`startTime ≤ now ≤ endTime`。
    public func isLive(at now: Date = Date()) -> Bool {
        startTime <= now && now <= endTime
    }

    /// 上游 `isFuture()`。
    public func isFuture(at now: Date = Date()) -> Bool {
        startTime > now
    }

    /// 上游 `format()`：没有标题就是空串；没有时间就只给标题。
    public var formatted: String {
        guard !title.isEmpty else {
            return ""
        }
        guard !start.isEmpty || !end.isEmpty else {
            return title
        }
        return timeRange + "  " + title
    }

    /// 上游 `getTime()`：`开始 ~ 结束`（两端都空则为空串）。
    public var timeRange: String {
        guard !start.isEmpty || !end.isEmpty else {
            return ""
        }
        return start + " ~ " + end
    }

    /// 上游 `getRange()`：`clock=开始-结束`（UTC 的 `yyyyMMdd'T'HHmmss'Z'`）。
    public var clockQuery: String {
        "clock=" + EPGTimeParser.formatClock(startTime) + "-" + EPGTimeParser.formatClock(endTime)
    }

    /// 是否跨天（结束时间早于开始时间 —— 上游在 `Epg.setTime` 里给结束时间补一天）。
    public var crossesMidnight: Bool {
        endTime < startTime
    }
}
