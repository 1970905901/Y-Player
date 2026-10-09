import Foundation

/// 播放时间的外推。
///
/// 为什么需要它：系统内核的 `addPeriodicTimeObserver` 是**每秒**一次
/// （`SystemPlayerEngine+Monitoring.swift` 里 `interval = 1s`）。直接把最后一次位置喂给覆盖层，
/// 弹幕会「一秒跳一格」、字幕会「一秒闪一下」—— 25 号字一格能跳十几个字宽。
///
/// 规则：记下「引擎报的位置」与「它是什么时候报的」，两点之间按速率线性外推。
/// 暂停 / 缓冲时速率为 0，时间就不动（弹幕与字幕自然停住），不需要额外分支。
///
/// 名字与位置：M08h 时它叫 `DanmakuClock`、写在 `DanmakuOverlay.swift` 里；M09f 做字幕上屏时
/// 两个覆盖层都要用它，于是改成中性名并单独成文件 —— 被第二处依赖之后，就该按**真正管的事**
/// 命名，而不是按第一个用它的功能命名。
struct PlaybackClock: Equatable {
    /// 引擎最后报的位置（秒）。
    private(set) var position: Double = 0
    /// 那个位置的采样时刻；`.distantPast` 表示还没采过样。
    private(set) var sampledAt: Date = .distantPast
    /// 每秒前进多少秒（倍速；暂停 / 缓冲 = 0）。
    private(set) var rate: Double = 0

    /// 引擎报位置时调一次。
    mutating func sample(position: Double, rate: Double, at date: Date) {
        self.position = position
        self.rate = max(0, rate)
        sampledAt = date
    }

    /// 只改速率（暂停 / 继续 / 变速）。
    ///
    /// 关键在**先外推再改**：暂停发生在两次位置上报之间，如果直接换速率，
    /// 这一段「已经走过的距离」就丢了，弹幕与字幕都会往回跳一下。
    mutating func setRate(_ rate: Double, at date: Date) {
        position = time(at: date)
        self.rate = max(0, rate)
        sampledAt = date
    }

    /// 某一时刻的播放位置。
    ///
    /// 还没采过样时返回 `position`（初始 0）。外推量夹到 0 以上：系统时间被改、
    /// 或采样时刻落在未来时，宁可停在原地也不要倒退。
    func time(at date: Date) -> Double {
        guard sampledAt != .distantPast else {
            return position
        }
        let elapsed = max(0, date.timeIntervalSince(sampledAt))
        return position + elapsed * rate
    }

    /// 是否在走。暂停时让 `TimelineView` 停下来 —— 画面没变还每秒刷 60 次纯属浪费电。
    var isRunning: Bool {
        sampledAt != .distantPast && rate > 0
    }
}
