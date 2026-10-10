@testable import CatVodCore
import Foundation
import Testing

/// 文件形态节目单缓存的刷新判定（M07d7）：三条规则与边界，逐条对齐上游 `EpgParser.refreshReason`。
@Suite("EPG 文件缓存：刷新判定")
struct EPGFileCachePolicyTests {
    /// 固定时区（上海）：跨天判定必须可复现，不能跟着跑测试的机器时区飘。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text) ?? .distantPast
    }

    @Test("文件不在 / 时间读不出来：都算没有缓存，重下")
    func missing() {
        let now = date("2026-10-10 12:00:00")
        #expect(EPGFileCachePolicy.refreshReason(exists: false, modifiedAt: nil, now: now, calendar: calendar) == .fileMissing)
        #expect(EPGFileCachePolicy.refreshReason(exists: true, modifiedAt: nil, now: now, calendar: calendar) == .fileMissing)
    }

    @Test("今天下的、不满 6 小时：直接用，不发请求")
    func fresh() {
        let reason = EPGFileCachePolicy.refreshReason(
            exists: true,
            modifiedAt: date("2026-10-10 09:00:00"),
            now: date("2026-10-10 12:00:00"),
            calendar: calendar
        )
        #expect(reason == nil)
    }

    @Test("今天下的、刚好 6 小时：不算过（上游是 > 不是 >=）")
    func exactlySixHours() {
        let reason = EPGFileCachePolicy.refreshReason(
            exists: true,
            modifiedAt: date("2026-10-10 06:00:00"),
            now: date("2026-10-10 12:00:00"),
            calendar: calendar
        )
        #expect(reason == nil)
    }

    @Test("今天下的、超过 6 小时：重下")
    func olderThanSixHours() {
        let reason = EPGFileCachePolicy.refreshReason(
            exists: true,
            modifiedAt: date("2026-10-10 05:59:59"),
            now: date("2026-10-10 12:00:00"),
            calendar: calendar
        )
        #expect(reason == .olderThanSixHours)
    }

    @Test("昨天下的：差得再少也算「不是今天的」（上游先判跨天，再判 6 小时）")
    func yesterday() {
        let reason = EPGFileCachePolicy.refreshReason(
            exists: true,
            modifiedAt: date("2026-10-09 23:30:00"),
            now: date("2026-10-10 00:10:00"),
            calendar: calendar
        )
        #expect(reason == .notToday)
    }
}
