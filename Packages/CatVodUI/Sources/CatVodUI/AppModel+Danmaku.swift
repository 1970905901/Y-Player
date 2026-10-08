import CatVodCore
import CatVodSource
import Foundation

// 弹幕的界面接线（M08c）：设置页里填的地址槽**真的被用起来**，播放页显示一行状态。
//
// 这一层只做「把服务接上」：搜索 → 候选 → 下载 → 解析都在 `CatVodSource.DanmakuService` 里、
// 且有单测（M08a/M08b）。这里负责挑地址、管状态、把错误变成一句人话。
//
// **上屏渲染还没有** —— 弹幕行（``AppModel/danmakuLines``）已经在手里，缺的是把它们画到视频上。

public extension AppModel {
    /// 载入一集的弹幕。
    ///
    /// 几条刻意的取舍：
    /// - **不抛错**：弹幕是锦上添花，失败只该影响播放页那一行提示，不该把播放流程带崩；
    /// - 开关关着、或四个槽位都空 → 什么都不做、也不提示（那是用户的设置，不是错误）；
    /// - 用 `search` + `lines(from:)` 而不是 `load`：这样能知道**是哪条源**给的弹幕，写进状态行；
    /// - 传输复用 ``AppModel/transportForConfiguration()``：接口 header、代理、广告拦截都与站点一致。
    func loadDanmaku(_ request: DanmakuRequest) async {
        guard danmakuAPI.isEnabled, !request.isEmpty else {
            clearDanmaku()
            return
        }
        guard let api = danmakuAPI.filledAddresses.first else {
            danmakuLines = []
            danmakuStatus = .idle
            return
        }
        danmakuStatus = .loading
        danmakuLines = []
        let service = DanmakuService(transport: transportForConfiguration())
        do {
            let sources = try await service.search(api: api, name: request.name, episode: request.episode)
            guard let source = sources.first else {
                danmakuStatus = .empty
                return
            }
            let lines = try await service.lines(from: source)
            danmakuLines = lines
            danmakuStatus = lines.isEmpty ? .empty : .loaded(source: source.displayName, count: lines.count)
        } catch {
            danmakuStatus = .failed(userFacingMessage(error))
        }
    }

    /// 清掉弹幕状态与已载入的行（换集 / 退出播放时用）。
    func clearDanmaku() {
        danmakuLines = []
        danmakuStatus = .idle
    }
}
