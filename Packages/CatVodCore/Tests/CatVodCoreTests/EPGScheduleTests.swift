import CatVodCore
import Foundation
import Testing

@Suite("EPG 节目单：去重、跨天与「正在播」")
struct EPGScheduleTests {
    private var shanghai: TimeZone {
        TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
    }

    /// 造一条「原始」节目（时间串只有 `HH:mm`，绝对时间待 `normalized` 填）。
    private func program(_ title: String, _ start: String, _ end: String) -> EPGProgram {
        EPGProgram(
            title: title,
            start: start,
            end: end,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("normalized：重复条目去掉，时间按 `date + HH:mm` 解析")
    func normalize() {
        let schedule = EPGSchedule(key: "cctv1", date: "2026-10-07", programs: [
            program("新闻", "12:00", "13:00"),
            program("新闻", "12:00", "13:00"),
            program("剧场", "13:00", "14:30"),
        ]).normalized(timeZone: shanghai)

        #expect(schedule.programs.count == 2)
        #expect(EPGTimeParser.formatClock(schedule.programs[0].startTime) == "20261007T040000Z")
        #expect(EPGTimeParser.formatClock(schedule.programs[0].endTime) == "20261007T050000Z")
    }

    @Test("跨天节目：结束早于开始时给结束补一天（上游 `checkDay`）")
    func midnightCrossing() throws {
        let schedule = EPGSchedule(key: "cctv1", date: "2026-10-07", programs: [
            program("午夜剧场", "23:30", "01:00"),
        ]).normalized(timeZone: shanghai)
        let only = try #require(schedule.programs.first)
        #expect(only.endTime.timeIntervalSince(only.startTime) == 5400)
        #expect(!only.crossesMidnight)
    }

    @Test("正在播 / 下一档：按绝对时间判断")
    func currentAndNext() {
        let schedule = EPGSchedule(key: "cctv1", date: "2026-10-07", programs: [
            program("新闻", "12:00", "13:00"),
            program("剧场", "13:00", "14:30"),
        ]).normalized(timeZone: shanghai)

        let during = EPGTimeParser.parse(date: "2026-10-07", time: "12:30", timeZone: shanghai)
        #expect(schedule.currentIndex(at: during) == 0)
        #expect(schedule.currentProgram(at: during)?.title == "新闻")
        #expect(schedule.nextProgram(at: during)?.title == "剧场")

        let after = EPGTimeParser.parse(date: "2026-10-07", time: "15:00", timeZone: shanghai)
        #expect(schedule.currentIndex(at: after) == nil)
        #expect(schedule.nextProgram(at: after) == nil)
    }

    @Test("节目展示与 `clock` 时间窗（UTC）")
    func programFormatting() {
        let start = EPGTimeParser.parse(date: "2026-10-07", time: "19:00", timeZone: shanghai)
        let end = EPGTimeParser.parse(date: "2026-10-07", time: "19:30", timeZone: shanghai)
        let program = EPGProgram(title: "新闻联播", start: "19:00", end: "19:30", startTime: start, endTime: end)

        #expect(program.formatted == "19:00 ~ 19:30  新闻联播")
        #expect(program.timeRange == "19:00 ~ 19:30")
        #expect(program.clockQuery == "clock=20261007T110000Z-20261007T113000Z")
        #expect(program.isLive(at: EPGTimeParser.parse(date: "2026-10-07", time: "19:15", timeZone: shanghai)))
        #expect(!program.isLive(at: EPGTimeParser.parse(date: "2026-10-07", time: "20:00", timeZone: shanghai)))

        let empty = EPGProgram(
            title: "",
            start: "",
            end: "",
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 0)
        )
        #expect(empty.formatted.isEmpty)
        #expect(empty.timeRange.isEmpty)
    }
}
