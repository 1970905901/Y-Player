import CatVodCore
import Foundation
import Testing

@Suite("直播时移：对齐上游 Catchup")
struct LiveCatchupTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let end = Date(timeIntervalSince1970: 1_700_003_600)

    @Test("decide：主（频道级）优先，其次次（源级），都空则没有")
    func decisions() {
        let pltv = LiveCatchup.pltv()
        #expect(LiveCatchup.decide(major: pltv, minor: nil)?.source == pltv.source)
        #expect(LiveCatchup.decide(major: LiveCatchup(), minor: pltv)?.source == pltv.source)
        #expect(LiveCatchup.decide(major: LiveCatchup(), minor: LiveCatchup()) == nil)
        #expect(LiveCatchup.decide(major: nil, minor: nil) == nil)
    }

    @Test("isEmpty 只看 source；match 走 contains + 正则")
    func emptinessAndMatch() {
        let pltv = LiveCatchup.pltv()
        #expect(!pltv.isEmpty)
        #expect(LiveCatchup(type: "append", source: "").isEmpty)
        #expect(pltv.matches(url: "http://x/PLTV/1/index.m3u8"))
        #expect(!pltv.matches(url: "http://x/live/index.m3u8"))
        #expect(!LiveCatchup(source: "?a=1").matches(url: "http://x/y"))
    }

    @Test("频道侧：没有配时移但地址含 `/PLTV/` 时自动套用内置规则（上游 hasCatchup）")
    func channelCatchup() {
        let pltv = LiveChannel(name: "CCTV-1", urls: ["http://x/PLTV/1/index.m3u8"])
        #expect(pltv.catchupForCurrentURL()?.source == LiveCatchup.pltv().source)
        let plain = LiveChannel(name: "CCTV-2", urls: ["http://x/live/index.m3u8"])
        #expect(plain.catchupForCurrentURL() == nil)
        // 配了 regex 但地址不命中 → 没有时移入口。
        let strict = LiveChannel(
            name: "CCTV-3",
            urls: ["http://x/live/index.m3u8"],
            catchup: LiveCatchup(type: "append", regex: "/PLTV/", source: "?playseek=1")
        )
        #expect(strict.catchupForCurrentURL() == nil)
    }

    @Test("时移地址：`utc:` / `utcend:` 令牌与追加规则（默认型直接返回时间串）")
    func playbackURL() {
        let utc = LiveCatchup(type: "append", source: "?begin={utc:}&end={utcend:}")
        #expect(utc.playbackURL("http://x/live.m3u8", start: start, end: end) == "http://x/live.m3u8?begin=1700000000&end=1700003600")

        let timestamp = LiveCatchup(type: "append", source: "?b=${(b)timestamp}")
        #expect(timestamp.playbackURL("http://x/live.m3u8", start: start, end: end) == "http://x/live.m3u8?b=1700000000")

        let direct = LiveCatchup(type: "default", source: "?b=${(b)timestamp}")
        #expect(direct.playbackURL("http://x/live.m3u8", start: start, end: end) == "?b=1700000000")
    }

    @Test("追加型：先按 replace 替换地址；原地址已有 query 时 `?` 变 `&`")
    func appending() {
        let pltv = LiveCatchup.pltv()
        let url = pltv.playbackURL("http://x/PLTV/1/index.m3u8?token=1", start: start, end: end)
        #expect(url.hasPrefix("http://x/TVOD/1/index.m3u8?token=1&playseek="))
    }

    @Test("频道线路：`地址$线路名` 取地址与线路名")
    func lineSuffix() {
        let channel = LiveChannel(name: "CCTV-1", urls: ["http://x/a.m3u8$备用", "http://x/b.m3u8"])
        #expect(channel.playbackURL(index: 0) == "http://x/a.m3u8")
        #expect(channel.lineName(index: 0) == "备用")
        #expect(channel.lineName(index: 1) == nil)
        #expect(channel.playbackURL(index: 9) == "")
    }
}
