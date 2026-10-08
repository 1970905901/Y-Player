import Foundation

/// EPG 时间解析与格式化：逐条对齐上游 `Formatters` + `EpgParser.parseFull` + `Epg.setTime`。
///
/// 上游用了三种时间形态，各有各的写法（都来自真实 XMLTV / x-tvg 接口）：
/// | 用途 | 格式 | 上游常量 |
/// | --- | --- | --- |
/// | XMLTV `<programme start="…">`（带时区） | `yyyyMMddHHmmss Z` / `yyyyMMddHHmmss ZZZ` | `EPG_FULL` / `EPG_FULL_COLON` |
/// | XMLTV `<programme start="…">`（不带时区） | `yyyyMMddHHmmss`（按源时区解释） | `EPG_FULL_NO_TZ` |
/// | JSON EPG 的 `date + HH:mm[:ss]` | `yyyy-MM-ddHH:mm` / `yyyy-MM-ddHH:mm:ss` | `EPG_DT_SHORT` / `EPG_DT_LONG` |
/// | 回给 x-tvg 的时间窗 | `yyyyMMdd'T'HHmmss'Z'`（UTC） | `EPG_RANGE` |
///
/// 失败一律退化为 `Date(timeIntervalSince1970: 0)`（上游 `parseFull` 退化为 `Instant.EPOCH`），
/// 不抛错、不静默返回 nil —— 调用方拿到的是「epoch」，一眼能看出解析失败。
public enum EPGTimeParser {
    /// 上游 `EpgParser.zoneIdOf`：空或非法时退回本机时区。
    public static func timeZone(named name: String) -> TimeZone {
        guard !name.isEmpty, let zone = TimeZone(identifier: name) else {
            return .current
        }
        return zone
    }

    /// 上游 `EpgParser.parseFull`。
    public static func parseFull(_ value: String, timeZone: TimeZone) -> Date {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Date(timeIntervalSince1970: 0)
        }
        if text.count >= 20 {
            // 末尾第 3 个字符是 `:` 说明是 `+08:00` 形态（上游用 `s.charAt(len - 3) == ':'` 判断）。
            let index = text.index(text.endIndex, offsetBy: -3)
            let format = text[index] == ":" ? "yyyyMMddHHmmss ZZZ" : "yyyyMMddHHmmss Z"
            return parse(text, format: format, timeZone: timeZone)
        }
        let trimmed = text.count > 14 ? String(text.prefix(14)) : text
        return parse(trimmed, format: "yyyyMMddHHmmss", timeZone: timeZone)
    }

    /// 上游 `Epg.setTime`：`date`（`yyyy-MM-dd`）拼上 `HH:mm` 或 `HH:mm:ss`。
    public static func parse(date: String, time: String, timeZone: TimeZone) -> Date {
        let trimmedDate = date.trimmingCharacters(in: .whitespaces)
        let trimmedTime = time.trimmingCharacters(in: .whitespaces)
        guard !trimmedDate.isEmpty, !trimmedTime.isEmpty else {
            return Date(timeIntervalSince1970: 0)
        }
        // 上游按拼接后的总长度 > 16 判断有没有秒（`yyyy-MM-ddHH:mm` 正好 16 个字符）。
        let format = trimmedDate.count + trimmedTime.count > 16 ? "yyyy-MM-ddHH:mm:ss" : "yyyy-MM-ddHH:mm"
        return parse(trimmedDate + trimmedTime, format: format, timeZone: timeZone)
    }

    /// 上游 `Formatters.DATE`（`yyyy-MM-dd`）。
    public static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        string(from: date, format: "yyyy-MM-dd", timeZone: timeZone)
    }

    /// 上游 `LocalDate.now(zoneId).plusDays(offset)`（再用 `Formatters.DATE` 输出）。
    ///
    /// x-tvg 接口按「昨天 / 今天 / 明天」各拉一次（上游 `LiveApi.getEpg` 的 `new int[]{-1, 0, 1}`），
    /// 日期一律按**直播源时区**算 —— 用本机时区会在跨零点的源上取错天。
    public static func dateString(dayOffset: Int, timeZone: TimeZone, from reference: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shifted = calendar.date(byAdding: .day, value: dayOffset, to: reference) ?? reference
        return formatDate(shifted, timeZone: timeZone)
    }

    /// 上游 `Formatters.TIME`（`HH:mm`）。
    public static func formatTime(_ date: Date, timeZone: TimeZone) -> String {
        string(from: date, format: "HH:mm", timeZone: timeZone)
    }

    /// 上游 `Formatters.EPG_RANGE`（`yyyyMMdd'T'HHmmss'Z'`，**UTC**）。
    public static func formatClock(_ date: Date) -> String {
        string(from: date, format: "yyyyMMdd'T'HHmmss'Z'", timeZone: TimeZone(identifier: "UTC") ?? .current)
    }

    /// 统一用 `en_US_POSIX`：这些格式是**协议格式**，不能被用户区域设置改写。
    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func parse(_ text: String, format: String, timeZone: TimeZone) -> Date {
        guard let date = formatter(format, timeZone: timeZone).date(from: text) else {
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    private static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        formatter(format, timeZone: timeZone).string(from: date)
    }
}
