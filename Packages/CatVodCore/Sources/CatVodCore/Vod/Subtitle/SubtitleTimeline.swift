import Foundation

/// 字幕的时间轴：按时间查「这一刻该显示哪几条」（M09f）。
///
/// 为什么要有它、而不是在渲染层直接扫 `[SubtitleCue]`：
/// 一集字幕常有 800–2000 条，而这是播放页**最热**的路径（每秒 60 次查询）。
/// 每帧线性扫一遍就是每秒十几万次比较，纯属白烧 —— 与 ``DanmakuPlan`` 同一套做法：
/// 按 `start` 排好序 + 二分定位 + 在一定窗口内回扫。
///
/// 与 ``DanmakuPlan`` 的差别只有一处：弹幕要算位置（几何），字幕只回答「哪几条」——
/// 位置是渲染层的事（居中、贴底、留多少边距都随用户设置变）。
public struct SubtitleTimeline: Sendable {
    /// 按 `start` 升序排好的 cue。
    private let cues: [SubtitleCue]
    /// 最长一条的时长：回扫窗口用它收窄（不设它就只能一路扫到 0）。
    private let maxDuration: Double

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        // 时长为负 / 为 0 的坏行不影响窗口上限；下限给 1 秒，避免「全是零长 cue」时窗口塌成 0。
        maxDuration = max(1, self.cues.map { $0.end - $0.start }.max() ?? 0)
    }

    public var isEmpty: Bool {
        cues.isEmpty
    }

    public var count: Int {
        cues.count
    }

    /// 某一时刻该显示的全部 cue，按出现时间排序。
    ///
    /// 正常情况下是 0 或 1 条；**重叠时几条都给** —— 要不要叠着显示、怎么叠，是渲染层的决定
    /// （上游那套遇到重叠也是各画各的）。
    public func cues(at time: Double) -> [SubtitleCue] {
        guard !cues.isEmpty, time.isFinite else {
            return []
        }
        var visible: [SubtitleCue] = []
        var index = upperBound(of: time)
        while index >= 0 {
            let cue = cues[index]
            if cue.start < time - maxDuration {
                break
            }
            if cue.isVisible(at: time) {
                visible.append(cue)
            }
            index -= 1
        }
        return visible.reversed()
    }

    /// 最后一个 `start <= time` 的下标（没有则 -1）。
    private func upperBound(of time: Double) -> Int {
        var low = 0
        var high = cues.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}
