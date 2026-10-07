import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import CatVodStore
import SwiftUI

/// Spider（`type=3`）站点的选集播放入口。
///
/// 为什么要单开一层：CMS 站点的播放地址在详情里就有（同步可得），
/// 而 CatSpider 协议要求先 `POST /play {flag, id}` 换取地址 —— 这一步是**异步**的，
/// 塞不进 `@ViewBuilder` 的同步 `destination(for:at:)`。
/// 这里负责「请求地址 → 成功进播放页 / 失败给出可读原因」，绝不静默失败。
@MainActor
struct SpiderEpisodePlaybackView: View {
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
    @State private var errorText = ""

    var body: some View {
        Group {
            if let resource {
                PlaybackView(
                    resource: resource,
                    title: episode.displayName,
                    settings: model.playbackSettings,
                    progressKey: progressKey,
                    progressEpisodeIndex: episodeIndex,
                    progressStore: model.progressStore
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

    /// 调 `POST /play` 并构造可播放资源。
    ///
    /// 失败原因原样透出（`userFacingMessage` 会保留 `CatVodError` 里的状态码与原因），
    /// 因为「为什么播不了」正是用户最需要知道的信息。
    private func loadResource() async {
        guard resource == nil, errorText.isEmpty else {
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
            resource = MediaResource(
                url: playURL,
                headers: HTTPHeaderMerger.merge([site.header, result.header]),
                startPosition: 0,
                format: result.format,
                title: [title, episode.displayName].filter { !$0.isEmpty }.joined(separator: " "),
                artwork: result.artwork
            )
        } catch {
            errorText = userFacingMessage(error)
        }
    }
}
