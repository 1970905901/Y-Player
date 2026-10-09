import AVFoundation
import CatVodCore
import Foundation

// 系统内核的轨道（M03P7）：多音轨 / 内封字幕走 `AVMediaSelectionGroup`。
//
// 单独一个文件：这两件事（上报列表、应用选择）只碰 AVFoundation 的「媒体选择」这一块，
// 与 `+Monitoring`（就绪 / 时间 / 结束）互不相干。

extension AVPlayerEngine {
    /// 上报可选的音轨 / 字幕轨（`PlayerEvent.tracksChanged`）。
    ///
    /// 时机：`readyToPlay` 之后（这时 `mediaSelectionGroup` 才拿得到），见 `handleReady()`。
    /// 画面轨恒为空数组：系统内核下没有「切画面轨」的需求，报了只会多出一排没人用的下拉框
    /// （MPV 那边同理只给音轨与字幕，见 M03P5）。
    func reportTracks() {
        let indices = trackIndices()
        emit(.tracksChanged(video: indices.video, audio: indices.audio, subtitle: indices.subtitle))
    }

    /// 当前可选项（内部可见：单测在没有媒体时断言为空；真机上由 ``reportTracks()`` 上报）。
    ///
    /// 下标就是 `group.options` 的下标 —— 界面拿到的数字原样送回来能选中同一轨
    /// （MPV 那边送的是轨道 id，两边各自自洽）。
    func trackIndices() -> (video: [Int], audio: [Int], subtitle: [Int]) {
        (
            video: optionIndices(for: .visual),
            audio: optionIndices(for: .audible),
            subtitle: optionIndices(for: .legible)
        )
    }

    /// 应用轨道选择。
    ///
    /// 三个分支都先挡住「没有条目 / 没有这个组」：AVPlayer 在没加载完时给的是 nil，
    /// 这时候**什么都不做**比乱选一条好。
    func applyTrackSelection(_ selection: TrackSelection, for kind: TrackKind) {
        guard let item = player.currentItem, let group = selectionGroup(for: kind) else {
            return
        }
        switch selection {
        case .auto:
            // 「自动」= 该组的默认轨（系统自己挑的那条）。
            item.select(group.defaultOption, in: group)
        case .disabled:
            // 只有「允许空选择」的组才能关：字幕组一般允许，音轨组通常不允许。
            guard group.allowsEmptySelection else { return }
            item.select(nil, in: group)
        case let .index(index):
            guard group.options.indices.contains(index) else { return }
            item.select(group.options[index], in: group)
        }
    }

    /// 某个轨道类别的媒体选择组（没有就 nil）。
    func selectionGroup(for kind: TrackKind) -> AVMediaSelectionGroup? {
        let characteristic: AVMediaCharacteristic = switch kind {
        case .video: .visual
        case .audio: .audible
        case .subtitle: .legible
        }
        return player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    }

    /// 某个特征下的可选轨下标。
    func optionIndices(for characteristic: AVMediaCharacteristic) -> [Int] {
        guard let group = player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else {
            return []
        }
        return Array(group.options.indices)
    }
}
