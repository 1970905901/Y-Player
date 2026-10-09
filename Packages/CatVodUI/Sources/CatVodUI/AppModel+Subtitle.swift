import CatVodCore
import CatVodSource
import Foundation

// 字幕的界面接线（M09c）：把播放结果里的 `subs` 接进播放流程。
//
// 与 `AppModel+Danmaku.swift` 同一套取舍：
// - **不抛错**：字幕是锦上添花，失败只该影响播放页那一行状态，不该把播放流程带崩；
// - **空结果不提示**：站点没给字幕是常态，不是错误（`SubtitleStatus.empty` 也只是如实说明）；
// - 传输复用 `transportForConfiguration()`，与站点请求同一套 header / 代理 / 广告拦截。
//
// 上屏见 `SubtitleOverlay`（M09f）：cue 排成时间轴（`SubtitleTimeline`），
// 再按播放时间逐帧画到视频底部 —— 与弹幕同一套骨架，共用同一个 `PlaybackClock`。

public extension AppModel {
    /// 载入一集的字幕。
    func loadSubtitles(_ request: SubtitleRequest) async {
        guard !request.isEmpty else {
            clearSubtitles()
            return
        }
        subtitleStatus = .loading
        subtitleCues = []
        let service = SubtitleService(transport: transportForConfiguration())
        do {
            guard let loaded = try await service.load(from: request.sources, headers: request.headers) else {
                subtitleStatus = .empty
                return
            }
            subtitleCues = loaded.cues
            subtitleStatus = loaded.cues.isEmpty
                ? .empty
                : .loaded(source: loaded.source.displayName, count: loaded.cues.count)
        } catch {
            subtitleStatus = .failed(reason: userFacingMessage(error))
        }
    }

    /// 清掉字幕状态与已载入的 cue（换集 / 退出播放时用）。
    func clearSubtitles() {
        subtitleCues = []
        subtitleStatus = .idle
    }
}
