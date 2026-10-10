import CatVodStore
import SwiftUI

/// 播放页的「片头 / 片尾」（M03P16）。
///
/// 对齐上游的做法：**只在两端附近才给标**（免得把片头标成一小时），标完跟进度写进同一条记录
/// （`opening` / `ending` 两列）；之后开播自动跳过片头、播到片尾自动进下一集。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数离 SwiftLint 的 `file_length` error（800）只剩几十行 ——
/// 与 `PlaybackView+Overlays` / `+Stats` / `+Gestures` 同一套做法；跨文件用到的成员去掉了 `private`。
extension PlaybackView {
    /// 「片头 / 片尾」区：标记 / 清除。
    ///
    /// 直播（没有进度记录）或时长还未知时不出现 —— 没有时长就无从「标在结尾附近」。
    @ViewBuilder
    var openingEndingSection: some View {
        if activeProgressContext != nil, latestDuration > 0 {
            Section {
                markRow(
                    title: "片头",
                    mark: openingMark,
                    canMark: PlaybackOpeningEndingRules.canSetOpening(position: latestPosition, duration: latestDuration),
                    onMark: markOpening,
                    onClear: clearOpening
                )
                markRow(
                    title: "片尾",
                    mark: endingMark,
                    canMark: PlaybackOpeningEndingRules.canSetEnding(position: latestPosition, duration: latestDuration),
                    onMark: markEnding,
                    onClear: clearEnding
                )
            } header: {
                Text("片头 / 片尾")
            } footer: {
                Text("片头 / 片尾只在开头 / 结尾附近能标（<15 分钟片 3 分钟、<30 分钟 6 分钟、更长 10 分钟）。标好后：开播跳过片头、播到片尾自动下一集。")
            }
        }
    }

    /// 一行：没标 →「标记当前」（不在可标范围里就置灰）；标了 → 时间 +「清除」。
    func markRow(
        title: String,
        mark: Double,
        canMark: Bool,
        onMark: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if mark > 0 {
                Text(Self.timeText(mark))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("清除", action: onClear)
            } else {
                Button("标记当前", action: onMark)
                    .disabled(!canMark)
            }
        }
    }

    /// 标片头：记**当前位置**（上游 `onOpening` 存的就是标记时播到哪儿）。
    func markOpening() {
        openingMark = latestPosition
        Task { await persist(force: true) }
    }

    /// 清片头（上游：长按那个按钮 = 置 0）。
    func clearOpening() {
        openingMark = 0
        Task { await persist(force: true) }
    }

    /// 标片尾：记**还剩多久**（上游 `onEnding` 存的是 `duration - position`）。
    func markEnding() {
        endingMark = max(latestDuration - latestPosition, 0)
        Task { await persist(force: true) }
    }

    /// 清片尾。
    func clearEnding() {
        endingMark = 0
        Task { await persist(force: true) }
    }

    /// 播到片尾就进下一集（上游 `VodPlaybackController.onTimeChanged` 里那一行）。
    ///
    /// 只在**有下一集**时跳：最后一集停在结束态等人（与 M12P1 的片尾策略一致）；
    /// `didSkipEnding` 保证这一集只跳一次（换集会把它清掉）。
    func skipEndingIfNeeded(current: Double, duration: Double) async {
        guard !didSkipEnding,
              PlaybackOpeningEndingRules.shouldSkipEnding(position: current, duration: duration, ending: endingMark)
        else {
            return
        }
        didSkipEnding = true
        // 与「播到结束」共用同一条规则（M03P20）：开了单集循环就回开头，不再切下一集。
        switch Self.endAction(isRepeatOne: isRepeatOne, hasNextEpisode: nextEpisodeIndex != nil) {
        case .loop:
            await loopCurrentEpisode()
        case .nextEpisode:
            if let next = nextEpisodeIndex {
                await switchEpisode(to: next)
            }
        case .stop:
            break
        }
    }
}
