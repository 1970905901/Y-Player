import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import CatVodStore
import SwiftUI

/// 「地址要用站点 play 接口换取」的选集播放入口 —— 两种站点共用：
///
/// - `type=3`（CatSpider HTTP）：`POST /play {flag, id}`；
/// - `type=4`（WebHome 类）：站点自己的 `play` 接口（`play` + `flag`，
///   见 ``CMSClient/play(site:flag:playID:)``）。
///
/// 为什么要单开一层：别的 CMS 类型（0/1/2）的播放地址在详情里就有（同步可得），
/// 而这两种都要**异步**先换一次地址，塞不进 `@ViewBuilder` 的同步 `destination(for:at:)`。
/// 这里负责「请求地址 → 直链就播 / 站点说要解析就交给解析链 / 失败给出可读原因」，绝不静默失败。
@MainActor
struct SitePlayEpisodeView: View {
    let model: AppModel
    let site: Site
    let episode: PlaylistParser.Episode
    /// 影片名（用于播放页标题）。
    let title: String
    /// 当前线路名（协议里的 `flag`）。
    let lineName: String
    let episodeIndex: Int
    let progressKey: PlaybackKey?

    @State private var resource: MediaResource?
    /// 站点说「还要再解析一次」时存下 play 的结果，body 里转交给解析链（见 ``loadResource()``）。
    @State private var parseFallback: SpiderResult?
    @State private var errorText = ""

    /// 进度上下文：Spider 站点的播放地址是异步换来的，但片名/线路/集名在进页面前就已确定。
    ///
    /// 元数据交给 ``PlaybackView`` 随进度落库，「追剧 → 播放历史」就能直接显示
    /// 站源 / 线路 / 集名，不需要为了列表再打一次站点接口。
    private var progressContext: PlaybackProgressContext? {
        guard let progressKey else {
            return nil
        }
        return PlaybackProgressContext(
            key: progressKey,
            episodeIndex: episodeIndex,
            metadata: PlaybackEntryMetadata(
                vodName: title,
                picture: "",
                siteName: site.name.isEmpty ? site.key : site.name,
                lineName: lineName,
                episodeName: episode.displayName
            )
        )
    }

    var body: some View {
        Group {
            if let resource {
                PlaybackView(
                    resource: resource,
                    title: episode.displayName,
                    settings: model.playbackSettings,
                    progressContext: progressContext,
                    progressStore: model.progressStore,
                    danmaku: DanmakuRequest(name: title, episode: episode.displayName),
                    onDanmaku: { request in Task { await model.loadDanmaku(request) } },
                    onStart: { model.resetAdSkip() }
                )
            } else if let parseFallback {
                // 站点说要再解析一次：把 play 的结果原样交给解析链 ——
                // 解析链的待解析地址取的就是结果里的 url（见 `ParsePlaybackView.parseContext()`）。
                ParsePlaybackView(
                    model: model,
                    site: site,
                    vodName: title,
                    lineName: lineName,
                    episode: episode,
                    episodeIndex: episodeIndex,
                    detail: parseFallback,
                    progressKey: progressKey
                )
            } else if errorText.isEmpty {
                ProgressView("正在向站点请求播放地址…")
                    .navigationTitle(episode.displayName)
            } else {
                UnsupportedPlaybackView(reason: errorText)
            }
        }
        .task {
            await loadResource()
        }
    }

    /// 调站点的 play 接口并构造可播放资源。
    ///
    /// 两条出路：
    /// - `parse/jx = 0`（直链）→ 直接构造资源播放；
    /// - `parse/jx = 1` → **把 play 的结果当作「结果」交给解析链**。解析链的待解析地址正是
    ///   结果里的 url，所以这一步等价于上游「把 `result` 一路往下传」的做法，
    ///   不需要另造一条通道。
    ///
    /// 失败原因原样透出（`userFacingMessage` 会保留 `CatVodError` 里的状态码与原因），
    /// 因为「为什么播不了」正是用户最需要知道的信息。
    private func loadResource() async {
        guard resource == nil, parseFallback == nil, errorText.isEmpty else {
            return
        }
        do {
            let result = try await model.makeSiteClient().play(
                site: site,
                flag: lineName,
                id: episode.url
            )
            guard let playURL = result.primaryPlaybackURL, !playURL.isEmpty else {
                errorText = "站点 play 接口没有返回播放地址（flag=\"\(lineName)\"）。"
                return
            }
            guard !result.requiresParsing else {
                parseFallback = result
                return
            }
            resource = model.proxiedMediaResource(MediaResource(
                url: playURL,
                headers: HTTPHeaderMerger.merge([site.header, result.header]),
                startPosition: 0,
                format: result.format,
                title: [title, episode.displayName].filter { !$0.isEmpty }.joined(separator: " "),
                artwork: result.artwork
            ))
        } catch {
            errorText = userFacingMessage(error)
        }
    }
}
