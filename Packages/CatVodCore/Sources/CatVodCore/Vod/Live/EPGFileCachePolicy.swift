import Foundation

/// 文件形态节目单的落盘缓存：**要不要重下**的判定（M07d7）。
///
/// 逐条对齐上游 `EpgParser.refreshReason(file)` 的三条，顺序也一样：
/// 1. 文件不在 → `file-missing`；
/// 2. 文件的修改时间**不是今天** → `not-today`；
/// 3. 修改时间距今**超过 6 小时** → `older-than-6h`；
/// 三条都不命中 → `nil`，直接用缓存，不发请求。
///
/// 为什么「不是今天」按**本机时区**：它说的是「这份文件是什么时候下的」，不是节目内容的时间 ——
/// 内容的时间口径在 ``EPGGuide/coversToday(now:)``，那个跟着节目单自己的时区走。
/// 上游 `isToday` 用的也是系统时区，这里保持一致。
public enum EPGFileCachePolicy {
    /// 六小时的保鲜期（上游写死 `TimeUnit.HOURS.toMillis(6)`；给个名字，别在判定里散着 21600）。
    public static let maxAge: TimeInterval = 6 * 60 * 60

    /// 为什么得重下；`nil` = 还新，直接用缓存。
    ///
    /// 原始字符串与上游一致（`file-missing` / `not-today` / `older-than-6h`）：排查时能对着日志搜到同一套词。
    public enum RefreshReason: String, Sendable, Equatable {
        case fileMissing = "file-missing"
        case notToday = "not-today"
        case olderThanSixHours = "older-than-6h"
    }

    /// 判定；`calendar` 可注入（单测固定时区，生产是本机）。
    public static func refreshReason(
        exists: Bool,
        modifiedAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RefreshReason? {
        guard exists else {
            return .fileMissing
        }
        guard let modifiedAt else {
            // 文件在、时间读不出来：当「没有可用缓存」最稳 —— 宁可重下一次，
            // 也不拿一份说不清新旧的东西当「今天拉过的」。
            return .fileMissing
        }
        guard calendar.isDate(modifiedAt, inSameDayAs: now) else {
            return .notToday
        }
        return now.timeIntervalSince(modifiedAt) > maxAge ? .olderThanSixHours : nil
    }
}
