import CatVodCore
import Foundation
import Testing

@Suite("EPG 时间解析：对齐上游 Formatters / parseFull")
struct EPGTimeParserTests {
    /// 用固定偏移的时区而不是 `TimeZone(identifier:)`：测试不依赖 CI 机器的区域设置。
    private var shanghai: TimeZone {
        TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
    }

    private var utc: TimeZone {
        TimeZone(secondsFromGMT: 0) ?? .gmt
    }

    @Test("XMLTV 带时区：`+0800` 与 `+08:00` 两种写法")
    func parseFullWithZone() {
        let plain = EPGTimeParser.parseFull("20261007120000 +0800", timeZone: shanghai)
        let colon = EPGTimeParser.parseFull("20261007120000 +08:00", timeZone: shanghai)
        #expect(EPGTimeParser.formatClock(plain) == "20261007T040000Z")
        #expect(EPGTimeParser.formatClock(colon) == "20261007T040000Z")
        #expect(EPGTimeParser.formatDate(plain, timeZone: shanghai) == "2026-10-07")
        #expect(EPGTimeParser.formatTime(plain, timeZone: shanghai) == "12:00")
    }

    @Test("XMLTV 不带时区：按直播源时区解释（14 位截断）")
    func parseFullWithoutZone() {
        let date = EPGTimeParser.parseFull("20261007120000", timeZone: shanghai)
        #expect(EPGTimeParser.formatClock(date) == "20261007T040000Z")
        // 超过 14 位时上游只取前 14 位（多余的秒/毫秒被丢掉）。
        let truncated = EPGTimeParser.parseFull("20261007120000.123", timeZone: shanghai)
        #expect(EPGTimeParser.formatClock(truncated) == "20261007T040000Z")
    }

    @Test("按源时区算「昨天 / 今天 / 明天」——x-tvg 接口的 `{date}`（M07c）")
    func dayOffsets() {
        // 源时区 07:00 时 UTC 还停在前一天 23:00：所以必须用**传入的时区**算，不能用本机时区。
        let morning = EPGTimeParser.parse(date: "2026-10-07", time: "07:00", timeZone: shanghai)
        #expect(EPGTimeParser.dateString(dayOffset: -1, timeZone: shanghai, from: morning) == "2026-10-06")
        #expect(EPGTimeParser.dateString(dayOffset: 0, timeZone: shanghai, from: morning) == "2026-10-07")
        #expect(EPGTimeParser.dateString(dayOffset: 1, timeZone: shanghai, from: morning) == "2026-10-08")
        #expect(EPGTimeParser.dateString(dayOffset: 0, timeZone: utc, from: morning) == "2026-10-06")
        // 跨月 / 跨年就是日历加减，不是「加减 86400 秒」。
        let newYear = EPGTimeParser.parse(date: "2026-01-01", time: "12:00", timeZone: shanghai)
        #expect(EPGTimeParser.dateString(dayOffset: -1, timeZone: shanghai, from: newYear) == "2025-12-31")
        #expect(EPGTimeParser.dateString(dayOffset: 1, timeZone: shanghai, from: newYear) == "2026-01-02")
    }

    @Test("解析失败一律退化为 epoch（不抛错、不静默 nil）")
    func parseFailures() {
        #expect(EPGTimeParser.formatClock(EPGTimeParser.parseFull("", timeZone: shanghai)) == "19700101T000000Z")
        #expect(EPGTimeParser.formatClock(EPGTimeParser.parseFull("not a time", timeZone: shanghai)) == "19700101T000000Z")
        #expect(EPGTimeParser.formatClock(EPGTimeParser.parse(date: "", time: "12:00", timeZone: shanghai)) == "19700101T000000Z")
    }

    @Test("JSON EPG 的 `date + HH:mm[:ss]`：按总长度选 SHORT / LONG")
    func parseDateAndTime() {
        let short = EPGTimeParser.parse(date: "2026-10-07", time: "12:00", timeZone: shanghai)
        let long = EPGTimeParser.parse(date: "2026-10-07", time: "12:00:30", timeZone: shanghai)
        #expect(EPGTimeParser.formatClock(short) == "20261007T040000Z")
        #expect(EPGTimeParser.formatClock(long) == "20261007T040030Z")
        #expect(EPGTimeParser.formatTime(long, timeZone: utc) == "04:00")
    }

    @Test("时区名非法时退回本机时区（上游 `zoneIdOf`）")
    func timeZoneFallback() {
        #expect(EPGTimeParser.timeZone(named: "").identifier == TimeZone.current.identifier)
        #expect(EPGTimeParser.timeZone(named: "Asia/Shanghai").identifier == "Asia/Shanghai")
    }
}
