import CatVodCore
import Foundation
import Testing

@Suite("节目单的「今天」判断（M07c-4）")
struct EPGGuideFreshnessTests {
    /// 固定的「现在」：2027-01-15T02:00Z。挑这个时刻就是为了让时区**真的决定日期** ——
    /// UTC 与上海都是 1 月 15 日，纽约还是 1 月 14 日。
    private var now: Date {
        Date(timeIntervalSince1970: 1_799_978_400)
    }

    private var shanghai: TimeZone {
        TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    }

    private var newYork: TimeZone {
        TimeZone(identifier: "America/New_York") ?? .gmt
    }

    private func makeGuide(key: String, date: String, timeZone: TimeZone) -> EPGGuide {
        EPGGuide(timeZone: timeZone, schedules: [EPGSchedule(key: key, date: date)])
    }

    @Test("按频道的今天：由**这份节目单的时区**决定，不是本机时区")
    func keyedTodayFollowsGuideTimeZone() {
        let shanghaiGuide = makeGuide(key: "cctv1", date: "2027-01-15", timeZone: shanghai)
        #expect(shanghaiGuide.coversToday(key: "cctv1", now: now))

        // 同一份日期、换成纽约时区：那里的「今天」还是 1 月 14 日。
        let newYorkGuide = makeGuide(key: "cctv1", date: "2027-01-15", timeZone: newYork)
        #expect(!newYorkGuide.coversToday(key: "cctv1", now: now))
        #expect(makeGuide(key: "cctv1", date: "2027-01-14", timeZone: newYork).coversToday(key: "cctv1", now: now))
    }

    @Test("按频道的今天：键必须对得上（别的频道有今天不算）")
    func keyedTodayNeedsMatchingKey() {
        let guide = makeGuide(key: "cctv1", date: "2027-01-15", timeZone: shanghai)
        #expect(guide.coversToday(key: "cctv1", now: now))
        #expect(!guide.coversToday(key: "cctv2", now: now))
    }

    @Test("整份的今天：文件形态一份覆盖多频道，任意频道有今天就算这一份还新")
    func wholeGuideToday() {
        let fresh = EPGGuide(timeZone: shanghai, schedules: [
            EPGSchedule(key: "cctv1", date: "2027-01-14"),
            EPGSchedule(key: "cctv2", date: "2027-01-15"),
        ])
        #expect(fresh.coversToday(now: now))

        // 只有昨天：跨天之后这一份就旧了（该重下）。
        let stale = makeGuide(key: "cctv1", date: "2027-01-14", timeZone: shanghai)
        #expect(!stale.coversToday(now: now))

        // 空节目单同理。
        #expect(!EPGGuide(timeZone: shanghai).coversToday(now: now))
    }
}
