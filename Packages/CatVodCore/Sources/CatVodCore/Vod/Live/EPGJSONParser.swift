import Foundation

/// x-tvg 接口的 **JSON 形态**：`{"key":"…","date":"yyyy-MM-dd","epg_data":[{"title","start","end"}]}`。
///
/// 上游 `Epg.objectFrom` 先看响应是不是 JSON 对象（`Json.isObj`）：
/// - 是对象 → 按 `Epg` 反序列化（`epg_data` 里是**只有 `HH:mm[:ss]`** 的时间），
///   再交给 `Epg.setTime(zoneId)` 用 `date + 时间` 拼绝对时间；
/// - 不是对象 → 交给 ``EPGXMLTVParser``（绝大多数接口返回的是 XMLTV）。
///
/// 所以这里是上游的 JSON 分支，只产出**一条切片**（接口本身就是一个频道一天）。
/// 时间字段的拼法与跨天补一天都在 ``EPGSchedule/normalized(timeZone:)`` 里（M07a 已落地）。
///
/// 与上游的差异（记录在 `docs/任务记录/M07c-EPG接口与直播频道节目单.md`）：
/// 响应里没有 `date` 时按**源时区的今天**（上游会拼出空日期 → 时间退化成 1970）。
public enum EPGJSONParser {
    /// 解析 JSON 形态；不是 JSON 对象 → `nil`（调用方改用 XMLTV 分支）。
    public static func parse(data: Data, key: String, timeZone: TimeZone) -> EPGSchedule? {
        guard !key.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawDate = string(object["date"])
        let date = rawDate.isEmpty ? EPGTimeParser.dateString(dayOffset: 0, timeZone: timeZone) : normalize(date: rawDate, timeZone: timeZone)
        var programs: [EPGProgram] = []
        for case let item as [String: Any] in (object["epg_data"] as? [Any]) ?? [] {
            let title = string(item["title"])
            guard !title.isEmpty else {
                continue
            }
            programs.append(
                EPGProgram(
                    title: title,
                    start: string(item["start"]),
                    end: string(item["end"]),
                    startTime: Date(timeIntervalSince1970: 0),
                    endTime: Date(timeIntervalSince1970: 0)
                )
            )
        }
        guard !programs.isEmpty else {
            // 接口明确回了「这一天没有节目」也算拉过（上游同样把空 `Epg` 挂上去，下次不再请求）。
            return EPGSchedule(key: key, date: date, programs: [])
        }
        // `normalized` 负责 `date + HH:mm[:ss]` 与「结束早于开始补一天」——与上游 `Epg.setTime` 同一条。
        return EPGSchedule(key: key, date: date, programs: programs).normalized(timeZone: timeZone)
    }

    /// 上游 `Epg` 的 `date` 字段可能是 `yyyy-MM-dd`，也可能是 `20261007…` 形态（走 `parseFull` 规整）。
    private static func normalize(date raw: String, timeZone: TimeZone) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-") || text.count < 8 {
            return text
        }
        let parsed = EPGTimeParser.parseFull(EPGXMLTVParser.normalizedTime(text), timeZone: timeZone)
        return parsed.timeIntervalSince1970 > 0 ? EPGTimeParser.formatDate(parsed, timeZone: timeZone) : text
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
