import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("直播节目单预取判定（M07c-4）")
struct LiveEPGPrefetchTests {
    /// 固定的「现在」：2027-01-15T02:00Z（上海是 1 月 15 日、纽约还是 1 月 14 日）。
    private var now: Date {
        Date(timeIntervalSince1970: 1_799_978_400)
    }

    private var shanghai: TimeZone {
        TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    }

    private func makeChannel(name: String, epg: String) -> LiveChannel {
        var channel = LiveChannel(name: name)
        channel.epg = epg
        return channel
    }

    private func makeGuide(key: String, date: String) -> EPGGuide {
        EPGGuide(timeZone: shanghai, schedules: [EPGSchedule(key: key, date: date)])
    }

    private func makeState(
        guide: EPGGuide? = nil,
        pending: Set<String> = [],
        failed: Set<String> = [],
        prefetched: Int = 0,
        budget: Int = LiveEPGPrefetch.defaultBudget
    ) -> LiveEPGPrefetchState {
        LiveEPGPrefetchState(guide: guide, pending: pending, failed: failed, prefetched: prefetched, budget: budget)
    }

    @Test("没有 x-tvg 地址的频道不排队：仓库同条件会直接抛错，别白发请求")
    func skipsChannelWithoutTemplate() {
        let plain = makeChannel(name: "CCTV-1", epg: "")
        #expect(!LiveEPGPrefetch.shouldQueue(plain, state: makeState(), now: now))

        let templated = makeChannel(name: "CCTV-1", epg: "http://a/epg?ch={id}&date={date}")
        #expect(LiveEPGPrefetch.shouldQueue(templated, state: makeState(), now: now))
    }

    @Test("已经有今天的节目单就不排队（文件形态全覆盖时也一样）")
    func skipsWhenTodayIsCovered() {
        let channel = makeChannel(name: "CCTV-1", epg: "http://a/epg?ch={id}&date={date}")
        // 接口形态：这个频道自己那份覆盖今天。
        let covered = makeState(guide: makeGuide(key: "CCTV-1", date: "2027-01-15"))
        #expect(!LiveEPGPrefetch.shouldQueue(channel, state: covered, now: now))

        // 文件形态：一份覆盖多频道，判定粒度仍是「**这个频道**在文件里有没有今天」
        // （上一节已经验过「别的频道有今天不顶用」）。
        let fileGuide = EPGGuide(timeZone: shanghai, schedules: [
            EPGSchedule(key: "CCTV-1", date: "2027-01-15"),
            EPGSchedule(key: "CCTV-2", date: "2027-01-15"),
        ])
        #expect(!LiveEPGPrefetch.shouldQueue(channel, state: makeState(guide: fileGuide), now: now))
    }

    @Test("只有昨天的节目单要重新排队：这就是跨天重拉的入口")
    func queuesWhenOnlyYesterdayIsCovered() {
        let channel = makeChannel(name: "CCTV-1", epg: "http://a/epg?ch={id}&date={date}")
        let yesterday = makeState(guide: makeGuide(key: "CCTV-1", date: "2027-01-14"))
        #expect(LiveEPGPrefetch.shouldQueue(channel, state: yesterday, now: now))

        // 别的频道有今天、这个频道只有昨天 → 仍然要为它排队。
        let otherToday = EPGGuide(timeZone: shanghai, schedules: [EPGSchedule(key: "CCTV-2", date: "2027-01-15")])
        #expect(LiveEPGPrefetch.shouldQueue(channel, state: makeState(guide: otherToday), now: now))
    }

    @Test("在队列里 / 已经失败过的频道不重复排队")
    func skipsPendingAndFailed() {
        let channel = makeChannel(name: "CCTV-1", epg: "http://a/epg?ch={id}&date={date}")
        #expect(!LiveEPGPrefetch.shouldQueue(channel, state: makeState(pending: ["CCTV-1"]), now: now))
        #expect(!LiveEPGPrefetch.shouldQueue(channel, state: makeState(failed: ["CCTV-1"]), now: now))
    }

    @Test("到封顶就不再排队（其余频道点开时仍会即时拉）")
    func stopsAtBudget() {
        let channel = makeChannel(name: "CCTV-1", epg: "http://a/epg?ch={id}&date={date}")
        #expect(LiveEPGPrefetch.shouldQueue(channel, state: makeState(prefetched: 11, budget: 12), now: now))
        #expect(!LiveEPGPrefetch.shouldQueue(channel, state: makeState(prefetched: 12, budget: 12), now: now))
    }
}
