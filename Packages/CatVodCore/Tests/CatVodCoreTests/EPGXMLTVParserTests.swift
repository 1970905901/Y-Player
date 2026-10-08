import CatVodCore
import Foundation
import Testing

@Suite("XMLTV 节目单解析（M07b）")
struct EPGXMLTVParserTests {
    /// 用固定偏移的时区而不是 `TimeZone(identifier:)`：测试不依赖 CI 机器的区域设置。
    private var shanghai: TimeZone {
        TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
    }

    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv generator-info-name="yplayer">
      <channel id="cctv1">
        <display-name>CCTV-1 综合</display-name>
      </channel>
      <channel id="cctv2">
        <display-name>CCTV-2 财经</display-name>
      </channel>
      <programme start="20261007190000 +0800" stop="20261007193000 +0800" channel="cctv1">
        <title lang="zh">新闻联播</title>
        <desc>每日新闻</desc>
      </programme>
      <programme start="20261007193000 +0800" stop="20261007200000 +0800" channel="cctv1">
        <title>焦点访谈</title>
      </programme>
      <programme start="20261007233000 +0800" stop="20261008010000 +0800" channel="cctv2">
        <title>午夜剧场</title>
      </programme>
    </tv>
    """

    private func parse(_ xml: String) -> EPGGuide? {
        EPGXMLTVParser.parse(data: Data(xml.utf8), timeZone: shanghai)
    }

    @Test("基本：频道名、按天切片、`HH:mm` 展示串与绝对时间一起算好")
    func basicGuide() throws {
        let guide = try #require(parse(sample))
        #expect(guide.channelNames["cctv1"] == "CCTV-1 综合")
        #expect(guide.displayName(for: "cctv2") == "CCTV-2 财经")
        // 取不到就用回落到清单里的频道名。
        #expect(guide.displayName(for: "cctv9", fallback: "CCTV-9") == "CCTV-9")
        #expect(guide.schedules.map(\.key) == ["cctv1", "cctv2"])
        #expect(guide.schedules.first?.date == "2026-10-07")

        let cctv1 = try #require(guide.schedule(key: "cctv1", date: "2026-10-07"))
        #expect(cctv1.programs.map(\.title) == ["新闻联播", "焦点访谈"])
        #expect(cctv1.programs.map(\.start) == ["19:00", "19:30"])
        let start = EPGTimeParser.parse(date: "2026-10-07", time: "19:00", timeZone: shanghai)
        #expect(cctv1.programs.first?.startTime == start)
        #expect(cctv1.programs.first?.endTime == EPGTimeParser.parse(date: "2026-10-07", time: "19:30", timeZone: shanghai))
    }

    @Test("正在播 / 下一档：跨切片找（XMLTV 一次给多天）")
    func liveAndNext() throws {
        let guide = try #require(parse(sample))
        let now = EPGTimeParser.parse(date: "2026-10-07", time: "19:10", timeZone: shanghai)
        #expect(guide.currentProgram(key: "cctv1", at: now)?.title == "新闻联播")
        #expect(guide.nextProgram(key: "cctv1", at: now)?.title == "焦点访谈")
        // 那个时间段没有节目 → nil（界面显示「暂无节目」）。
        let morning = EPGTimeParser.parse(date: "2026-10-07", time: "08:00", timeZone: shanghai)
        #expect(guide.currentProgram(key: "cctv1", at: morning) == nil)
    }

    @Test("跨天节目：XMLTV 给的是完整日期，切片落在开始那天")
    func midnightCrossing() throws {
        let guide = try #require(parse(sample))
        let cctv2 = try #require(guide.schedule(key: "cctv2", date: "2026-10-07"))
        let program = try #require(cctv2.programs.first)
        #expect(program.start == "23:30")
        #expect(program.end == "01:00")
        #expect(program.endTime == EPGTimeParser.parse(date: "2026-10-08", time: "01:00", timeZone: shanghai))
        // XMLTV 的 `stop` 是绝对时间，所以「结束早于开始」不成立；
        // JSON EPG 形态（只有 `HH:mm`）才靠 `EPGSchedule.normalized` 补一天。
        #expect(!program.crossesMidnight)
    }

    @Test("时间写法兼容：`T` 分隔、`Z`(UTC)、`+08:00`、无时区、缺 `stop`")
    func timeForms() throws {
        let xml = """
        <tv>
          <programme start="20261007T190000+0800" stop="20261007193000+08:00" channel="c1"><title>T 分隔</title></programme>
          <programme start="20261007120000Z" stop="20261007130000Z" channel="c2"><title>UTC</title></programme>
          <programme start="20261007200000" stop="20261007210000" channel="c3"><title>无时区</title></programme>
          <programme start="20261007210000 +0800" channel="c4"><title>缺 stop</title></programme>
        </tv>
        """
        let guide = try #require(parse(xml))
        #expect(guide.schedule(key: "c1", date: "2026-10-07")?.programs.first?.start == "19:00")
        #expect(guide.schedule(key: "c1", date: "2026-10-07")?.programs.first?.end == "19:30")
        // `Z` 是 UTC：北京时间 20:00（不能按源时区解释）。
        #expect(guide.schedule(key: "c2", date: "2026-10-07")?.programs.first?.start == "20:00")
        // 完全没有时区 → 按直播源时区（+08:00）解释。
        #expect(guide.schedule(key: "c3", date: "2026-10-07")?.programs.first?.start == "20:00")
        // 缺 `stop` → 结束时间取开始时间（零长度节目，而不是 1970 年）。
        let openEnded = try #require(guide.schedule(key: "c4", date: "2026-10-07")?.programs.first)
        #expect(openEnded.end == openEnded.start)
        #expect(openEnded.endTime == openEnded.startTime)
    }

    @Test("丢掉「没有标题」与「时间解析失败」的条目；不是 XMLTV 就返回 nil")
    func tolerance() throws {
        let xml = """
        <tv>
          <programme start="20261007190000 +0800" stop="20261007193000 +0800" channel="c1"><title>正常</title></programme>
          <programme start="20261007200000 +0800" stop="20261007210000 +0800" channel="c1"></programme>
          <programme start="not-a-time" stop="20261007220000 +0800" channel="c1"><title>坏时间</title></programme>
        </tv>
        """
        let guide = try #require(parse(xml))
        #expect(guide.schedule(key: "c1", date: "2026-10-07")?.programs.map(\.title) == ["正常"])

        // HTML（站点 404 页）能当 XML 解析成功，但没有 `<tv>` → 当「不是节目单」。
        #expect(parse("<html><body>404</body></html>") == nil)
        #expect(parse("") == nil)
        #expect(parse("<?xml version=\"1.0\"?><root><a>1</a></root>") == nil)
    }

    @Test("merging：同一天同一频道的节目拼在一起并去重，频道名只补空缺")
    func merging() throws {
        let first = try #require(parse(sample))
        let extra = try #require(parse("""
        <tv>
          <channel id="cctv1"><display-name>中央一台</display-name></channel>
          <programme start="20261007210000 +0800" stop="20261007220000 +0800" channel="cctv1"><title>晚间新闻</title></programme>
          <programme start="20261007190000 +0800" stop="20261007193000 +0800" channel="cctv1"><title>新闻联播</title></programme>
        </tv>
        """))
        let merged = first.merging(extra)
        let cctv1 = try #require(merged.schedule(key: "cctv1", date: "2026-10-07"))
        // 重复的那条只留一份，新的接在后面并整体重排。
        #expect(cctv1.programs.map(\.title) == ["新闻联播", "焦点访谈", "晚间新闻"])
        // 已有的频道名不被后来的覆盖。
        #expect(merged.channelNames["cctv1"] == "CCTV-1 综合")
        #expect(first.merging(first).schedules.count == first.schedules.count)
    }
}
