import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("直播「上次观看」与线路（M07c-3）")
struct LiveKeepWiringTests {
    /// 固定的「现在」：单测不依赖运行时刻。
    private var now: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// 一份够用的清单：央视组两条线路（都写了几路名）+ 一条没有地址的频道；另有一个卫视频道。
    private func makeSource() throws -> LiveSource {
        let json = """
        {"name":"演示直播","groups":[
          {"name":"央视","channel":[
            {"name":"CCTV-1","urls":["http://a/1.m3u8$线路一","http://a/2.m3u8$线路二"],
             "catchup":{"type":"append","source":"?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"}},
            {"name":"CCTV-2","urls":[]}
          ]},
          {"name":"卫视","channel":[{"name":"湖南卫视","urls":["http://b/1.m3u8"]}]}
        ]}
        """
        return try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    private func pastProgram() -> EPGSchedule {
        EPGSchedule(key: "CCTV-1", date: "2026-10-08", programs: [
            EPGProgram(
                title: "已播",
                start: "18:00",
                end: "19:00",
                startTime: now.addingTimeInterval(-3600),
                endTime: now.addingTimeInterval(-600)
            ),
        ])
    }

    @Test("存档：按源名分桶、JSON 往返；坏存档 / 空源名都不写坏数据")
    func bookRoundTrip() {
        let keep = LiveKeep(group: "央视", channel: "CCTV-1", line: 1)
        let book = LiveKeepBook.recording(keep, for: "演示直播", in: [:])
        #expect(book == ["演示直播": "央视@@@CCTV-1@@@1"])
        #expect(LiveKeepBook.decode(LiveKeepBook.encode(book)) == book)

        // 另一个源各记各的，互不覆盖。
        let two = LiveKeepBook.recording(LiveKeep(group: "卫视", channel: "湖南卫视", line: 0), for: "备用源", in: book)
        #expect(two.count == 2)
        #expect(two["演示直播"] == "央视@@@CCTV-1@@@1")

        // 同一个源再记一次：覆盖。
        let replaced = LiveKeepBook.recording(LiveKeep(group: "央视", channel: "CCTV-2", line: 0), for: "演示直播", in: book)
        #expect(replaced["演示直播"] == "央视@@@CCTV-2@@@0")
        #expect(replaced.count == 1)

        // 坏存档 / 空存档 / 空键值：一律当「没有记录」，不让直播页打不开。
        #expect(LiveKeepBook.decode("").isEmpty)
        #expect(LiveKeepBook.decode("{不是 JSON").isEmpty)
        #expect(LiveKeepBook.decode("{\"\":\"央视@@@CCTV-1@@@0\"}").isEmpty)
        #expect(LiveKeepBook.decode("[\"数组不是表\"]").isEmpty)
        #expect(LiveKeepBook.recording(keep, for: "", in: [:]).isEmpty)
    }

    @Test("频道行：命中「上次观看」时带「上次」标记与上次的线路下标，同一分组其它频道不受影响")
    func rowMarksLastWatched() throws {
        let source = try makeSource()
        let resume = try #require(LiveKeep(raw: "央视@@@CCTV-1@@@1")?.resolve(in: source))

        let rows = LiveListLayout.channelRows(source.groups[0], guide: nil, resume: resume, at: now)
        #expect(rows[0].isLastWatched)
        #expect(rows[0].initialLineIndex == 1)
        #expect(!rows[1].isLastWatched)
        #expect(rows[1].initialLineIndex == 0)

        // 没有记录时列表照旧：不带标记、线路都从第 0 条起。
        let plain = LiveListLayout.channelRows(source.groups[0], guide: nil, at: now)
        #expect(plain.allSatisfy { !$0.isLastWatched })
        #expect(plain.allSatisfy { $0.initialLineIndex == 0 })
    }

    @Test("没有地址的频道不算命中「上次观看」——标了也播不了")
    func rowIgnoresUnplayableChannel() throws {
        let source = try makeSource()
        let target = try #require(LiveKeep(raw: "央视@@@CCTV-2@@@0")?.resolve(in: source))
        #expect(!target.isPlayable)

        let row = LiveListLayout.row(target.channel, guide: nil, resume: target, at: now)
        #expect(!row.isLastWatched)
        #expect(row.initialLineIndex == 0)
    }

    @Test("线路名：清单写了 `地址$线路名` 就用它，没写按「线路 N」")
    func lineTitles() throws {
        let source = try makeSource()
        let channel = source.groups[0].channels[0]
        #expect(LiveListLayout.lineTitle(channel: channel, lineIndex: 0) == "线路一")
        #expect(LiveListLayout.lineTitle(channel: channel, lineIndex: 1) == "线路二")

        let plain = source.groups[0].channels[1]
        #expect(LiveListLayout.lineTitle(channel: plain, lineIndex: 0) == "线路 1")
    }

    @Test("时移地址按指定线路拼：换到第 1 条线路后回看指向第 1 条地址")
    func programRowsUseLine() throws {
        let source = try makeSource()
        let channel = source.groups[0].channels[0]
        let schedule = pastProgram()

        let first = LiveListLayout.programRows(channel: channel, schedule: schedule, at: now)
        #expect(first[0].catchupURL?.hasPrefix("http://a/1.m3u8?playseek=") == true)

        let second = LiveListLayout.programRows(channel: channel, schedule: schedule, lineIndex: 1, at: now)
        #expect(second[0].catchupURL?.hasPrefix("http://a/2.m3u8?playseek=") == true)
    }
}
