import CatVodCore
import Foundation
import Testing

@Suite("x-tvg 接口的 JSON 形态（M07c）")
struct EPGJSONParserTests {
    /// 用固定偏移的时区而不是 `TimeZone(identifier:)`：测试不依赖 CI 机器的区域设置。
    private var shanghai: TimeZone {
        TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
    }

    private func parse(_ json: String, key: String = "cctv1") -> EPGSchedule? {
        EPGJSONParser.parse(data: Data(json.utf8), key: key, timeZone: shanghai)
    }

    @Test("基本：`date` + `epg_data`（只有 `HH:mm`）→ 按源时区拼出绝对时间")
    func basicSchedule() throws {
        let json = #"{"key":"cctv1","date":"2026-10-07","epg_data":[{"title":"新闻联播","start":"19:00","end":"19:30"}]}"#
        let schedule = try #require(parse(json))
        #expect(schedule.key == "cctv1")
        #expect(schedule.date == "2026-10-07")
        #expect(schedule.programs.map(\.title) == ["新闻联播"])
        #expect(schedule.programs.first?.startTime == EPGTimeParser.parse(date: "2026-10-07", time: "19:00", timeZone: shanghai))
        #expect(schedule.programs.first?.endTime == EPGTimeParser.parse(date: "2026-10-07", time: "19:30", timeZone: shanghai))
    }

    @Test("跨天：结束早于开始 → 结束补一天（`EPGSchedule.normalized`）")
    func midnightCrossing() throws {
        let json = #"{"date":"2026-10-07","epg_data":[{"title":"午夜剧场","start":"23:30","end":"01:00"}]}"#
        let schedule = try #require(parse(json))
        let program = try #require(schedule.programs.first)
        #expect(program.start == "23:30")
        #expect(program.end == "01:00")
        // `normalized` 已经把结束时间补到第二天：所以这里**不再**是「结束早于开始」。
        #expect(!program.crossesMidnight)
        #expect(program.endTime == EPGTimeParser.parse(date: "2026-10-08", time: "01:00", timeZone: shanghai))
    }

    @Test("容错：缺 `date` 按源时区今天、缺标题的条目丢掉、带秒的时间也认")
    func tolerance() throws {
        let json = #"{"epg_data":[{"title":"","start":"08:00","end":"09:00"},{"title":"早间新闻","start":"08:00:30","end":"09:00:00"}]}"#
        let schedule = try #require(parse(json))
        #expect(schedule.date == EPGTimeParser.dateString(dayOffset: 0, timeZone: shanghai))
        #expect(schedule.programs.map(\.title) == ["早间新闻"])
        // 展示串保持接口原样（上游 `Epg.setTime` 也只改绝对时间），界面要的是 `startTime`。
        #expect(schedule.programs.first?.start == "08:00:30")
        #expect(schedule.programs.first?.startTime == EPGTimeParser.parse(date: schedule.date, time: "08:00:30", timeZone: shanghai))
    }

    @Test("空 `epg_data`：返回空切片（算「这一天拉过」，上游同样挂一个空 `Epg`）")
    func emptyList() throws {
        let schedule = try #require(parse(#"{"date":"2026-10-07","epg_data":[]}"#))
        #expect(schedule.date == "2026-10-07")
        #expect(schedule.programs.isEmpty)
    }

    @Test("形态判定：不是 JSON 对象 → nil（调用方改走 XMLTV）；`20261007…` 的 `date` 会规整")
    func detection() throws {
        #expect(parse("<tv><programme/></tv>") == nil)
        #expect(parse(#"[]"#) == nil)
        #expect(parse(#"{"date":"2026-10-07","epg_data":[]}"#, key: "") == nil)

        let compact = try #require(parse(#"{"date":"20261007200000","epg_data":[{"title":"晚点","start":"20:00","end":"21:00"}]}"#))
        #expect(compact.date == "2026-10-07")
    }
}
