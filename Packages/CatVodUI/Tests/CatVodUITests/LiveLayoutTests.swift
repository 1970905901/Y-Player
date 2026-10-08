import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("直播页的行模型（M07c-2）")
struct LiveLayoutTests {
    /// 固定的「现在」：单测不依赖运行时刻。
    private var now: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeSource(_ json: String) throws -> LiveSource {
        try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    private func makeChannel(
        name: String,
        urls: [String],
        tvgID: String = "",
        tvgName: String = "",
        logo: String = "",
        catchup: LiveCatchup? = nil
    ) -> LiveChannel {
        var channel = LiveChannel(name: name, urls: urls, catchup: catchup)
        channel.tvgID = tvgID
        channel.tvgName = tvgName
        channel.logo = logo
        channel.number = "001"
        return channel
    }

    /// 一条「正在播 + 下一档」的节目单：时间直接用绝对时间构造，绕开时区解析。
    private func makeGuide(key: String, name: String = "", icon: String = "") -> EPGGuide {
        let schedule = EPGSchedule(key: key, date: "2026-10-08", programs: [
            EPGProgram(
                title: "新闻联播",
                start: "19:00",
                end: "19:30",
                startTime: now.addingTimeInterval(-600),
                endTime: now.addingTimeInterval(600)
            ),
            EPGProgram(
                title: "焦点访谈",
                start: "19:30",
                end: "20:00",
                startTime: now.addingTimeInterval(1200),
                endTime: now.addingTimeInterval(2400)
            ),
        ])
        return EPGGuide(
            timeZone: TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt,
            channelNames: name.isEmpty ? [:] : [key: name],
            channelLogos: icon.isEmpty ? [:] : [key: icon],
            schedules: [schedule]
        )
    }

    @Test("分组行：保持清单顺序，带频道数；`组_密码` 标成加密分组")
    func groupRows() throws {
        let json = """
        {"name":"演示直播","groups":[
          {"name":"央视","channel":[{"name":"CCTV-1","urls":["http://a/1.m3u8"]}]},
          {"name":"加密组_1234","channel":[{"name":"A","urls":[]},{"name":"B","urls":[]}]}
        ]}
        """
        let source = try makeSource(json)
        let rows = LiveListLayout.groupRows(source)
        #expect(rows.map(\.name) == ["央视", "加密组_1234"])
        #expect(rows.map(\.count) == [1, 2])
        #expect(rows.map(\.isHidden) == [false, true])
    }

    @Test("频道行：EPG 覆盖显示名与图标，带「正在播 / 下一档」文案")
    func channelRowWithGuide() {
        let channel = makeChannel(name: "CCTV-1 综合", urls: ["http://a/1.m3u8"], tvgID: "cctv1", logo: "http://list/1.png")
        let guide = makeGuide(key: "cctv1", name: "CCTV-1 综合(EPG)", icon: "http://epg/1.png")

        let row = LiveListLayout.row(channel, guide: guide, at: now)
        #expect(row.title == "CCTV-1 综合(EPG)")
        #expect(row.logo == "http://epg/1.png")
        #expect(row.currentText == "19:00 ~ 19:30  新闻联播")
        #expect(row.nextText == "19:30 ~ 20:00  焦点访谈")
        #expect(row.number == "001")
        #expect(row.isPlayable)
    }

    @Test("没有节目单：名字与图标回落清单，节目文案留空（界面显示「暂无节目」）")
    func channelRowWithoutGuide() {
        let channel = makeChannel(name: "CCTV-1 综合", urls: ["http://a/1.m3u8"], tvgID: "cctv1", logo: "http://list/1.png")

        let row = LiveListLayout.row(channel, guide: nil, at: now)
        #expect(row.title == "CCTV-1 综合")
        #expect(row.logo == "http://list/1.png")
        #expect(row.currentText.isEmpty)
        #expect(row.nextText.isEmpty)
    }

    @Test("匹配键用 `epgID`：清单没写 `tvg-id` 时落到 `tvg-name`，再落到频道名")
    func epgIDFallback() {
        let byName = makeChannel(name: "湖南卫视", urls: ["http://a/2.m3u8"], tvgName: "hunan")
        let guide = makeGuide(key: "hunan", name: "湖南卫视(EPG)")
        #expect(LiveListLayout.row(byName, guide: guide, at: now).title == "湖南卫视(EPG)")

        let byChannelName = makeChannel(name: "湖南卫视", urls: ["http://a/2.m3u8"])
        let nameGuide = makeGuide(key: "湖南卫视", name: "湖南卫视(EPG)")
        #expect(LiveListLayout.row(byChannelName, guide: nameGuide, at: now).title == "湖南卫视(EPG)")
    }

    @Test("时移入口：配了 catchup 才有；地址含 `/PLTV/` 时自动套用内置规则")
    func catchupAvailability() {
        let plain = makeChannel(name: "A", urls: ["http://a/1.m3u8"])
        #expect(!LiveListLayout.row(plain, guide: nil, at: now).hasCatchup)

        let pltv = makeChannel(name: "B", urls: ["http://a/PLTV/1.m3u8"])
        #expect(LiveListLayout.row(pltv, guide: nil, at: now).hasCatchup)

        let configured = makeChannel(
            name: "C",
            urls: ["http://a/2.m3u8"],
            catchup: LiveCatchup(type: "append", source: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")
        )
        #expect(LiveListLayout.row(configured, guide: nil, at: now).hasCatchup)

        // `regex` 不命中当前地址 → 不出现时移入口（上游 `hasCatchup` 同此）。
        let mismatched = makeChannel(
            name: "D",
            urls: ["http://a/3.m3u8"],
            catchup: LiveCatchup(type: "append", regex: "/PLTV/", source: "?playseek=${(b)yyyyMMddHHmmss}")
        )
        #expect(!LiveListLayout.row(mismatched, guide: nil, at: now).hasCatchup)
    }

    @Test("频道行：按清单顺序，且没有地址的频道标成不可播放")
    func channelRows() {
        let group = LiveGroup(name: "央视", channels: [
            makeChannel(name: "CCTV-1", urls: ["http://a/1.m3u8"]),
            makeChannel(name: "CCTV-2", urls: []),
        ])
        let rows = LiveListLayout.channelRows(group, guide: nil, at: now)
        #expect(rows.map(\.title) == ["CCTV-1", "CCTV-2"])
        #expect(rows.map(\.isPlayable) == [true, false])
    }
}
