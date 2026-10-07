import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import CatVodStore
import SwiftUI

// 详情页数据逻辑与播放能力判定。

extension VodDetailView {
    /// 读取本片进度（用于「上次看到这里」标记）。
    func loadProgress() async {
        guard let progressKey else {
            progress = nil
            return
        }
        progress = await model.progressStore.progress(for: progressKey)
    }

    /// 读取收藏状态（工具栏的「收藏 / 已收藏」）。
    func loadFavorite() async {
        guard let progressKey else {
            isFavorite = false
            return
        }
        isFavorite = await model.favoriteStore.favorite(for: progressKey) != nil
    }

    /// 收藏 / 取消收藏。
    ///
    /// 收藏条目带上片名、封面、站源、线路与集名（``favoriteMetadata()``），
    /// 「追剧 → 收藏记录」因此能直接渲染，不需要再请求详情。
    func toggleFavorite() async {
        guard let progressKey else {
            return
        }
        if isFavorite {
            await model.favoriteStore.remove(for: progressKey)
        } else {
            await model.favoriteStore.add(Favorite(key: progressKey, metadata: favoriteMetadata()))
        }
        await loadFavorite()
    }

    /// 收藏用的展示元数据：集名取「上次看到的那一集」，没有进度时取第一集。
    func favoriteMetadata() -> PlaybackEntryMetadata {
        let watchedEpisodeName: String
        if let progress, episodes.indices.contains(progress.episodeIndex) {
            watchedEpisodeName = episodes[progress.episodeIndex].displayName
        } else {
            watchedEpisodeName = episodes.first?.displayName ?? ""
        }
        return PlaybackEntryMetadata(
            vodName: vod?.vodName ?? vodID,
            picture: vod?.vodPic ?? "",
            siteName: site.map { $0.name.isEmpty ? $0.key : $0.name } ?? "",
            lineName: currentLine?.name ?? "",
            episodeName: watchedEpisodeName
        )
    }

    /// 播放页的进度上下文：键 + 集下标 + 展示元数据（供「追剧」列表直接渲染）。
    func progressContext(for episode: PlaylistParser.Episode, at index: Int) -> PlaybackProgressContext? {
        guard let site else {
            return nil
        }
        return PlaybackProgressContext(
            key: PlaybackKey(siteKey: site.key, vodID: vodID),
            episodeIndex: index,
            metadata: PlaybackEntryMetadata(
                vodName: vod?.vodName ?? vodID,
                picture: vod?.vodPic ?? "",
                siteName: site.name.isEmpty ? site.key : site.name,
                lineName: currentLine?.name ?? "",
                episodeName: episode.displayName
            )
        )
    }

    /// 换源：切到候选站点/条目并重新拉详情。
    ///
    /// 必须清空当前 `detail`/`lines`/线路选择，否则会出现「站点已换但选集还是旧的」的串数据。
    func switchSource(to candidate: ChangeSourceCandidate) {
        site = candidate.site
        vodID = candidate.item.vodID
        detail = SpiderResult()
        lines = []
        selectedLineIndex = 0
        errorText = ""
        progress = nil
        isFavorite = false
        Task {
            await loadDetail(force: true)
            await loadProgress()
            await loadFavorite()
        }
    }

    /// 拉取详情并解析线路/选集。
    ///
    /// - Parameter force: 为 true 时绕过本地缓存重新请求（下拉刷新、换源）。
    func loadDetail(force: Bool = false) async {
        guard !isLoading else {
            return
        }
        guard let site else {
            errorText = "缺少站点信息，无法加载详情"
            return
        }
        if !force, !detail.list.isEmpty {
            return
        }
        isLoading = true
        errorText = ""
        defer { isLoading = false }

        do {
            let result = try await model.makeDetailProvider().detail(
                site: site,
                vodID: vodID,
                forceRefresh: force
            )
            detail = result
            if let item = result.list.first {
                lines = PlaylistParser.parse(playFrom: item.vodPlayFrom, playURL: item.vodPlayURL)
                let issues = PlaylistParser.consistencyIssues(playFrom: item.vodPlayFrom, playURL: item.vodPlayURL)
                if lines.isEmpty, !issues.isEmpty {
                    errorText = issues.joined(separator: "；")
                }
            } else {
                errorText = "详情为空"
            }
        } catch {
            errorText = userFacingMessage(error)
        }
    }

    /// 构造可直接播放的资源；不可直接播放时返回 nil（由 UI 展示原因）。
    func makeResource(for episode: PlaylistParser.Episode) -> MediaResource? {
        guard let site, !episode.url.isEmpty else {
            return nil
        }
        let request = try? PlayRequestBuilder.makeRequest(
            site: site,
            flag: currentLine?.name ?? "",
            playID: episode.url
        )
        guard let request, case .direct = request.source else {
            return nil
        }
        // M2：只有“直链且无需解析”的集能直接播；需要解析的走 M5 的解析链。
        guard !request.requiresParsing else {
            return nil
        }
        return MediaResource(
            url: episode.url,
            headers: HTTPHeaderMerger.merge([site.header, detail.header]),
            startPosition: 0,
            format: detail.format,
            title: [vod?.vodName ?? "", episode.name].filter { !$0.isEmpty }.joined(separator: " "),
            artwork: detail.artwork.isEmpty ? (vod?.vodPic ?? "") : detail.artwork
        )
    }

    /// 该站点能否走 CatSpider 的 `play` 接口（js2p 宿主站点）。
    ///
    /// 只说明「协议形态对」；宿主没起来时 `play` 会失败并给出可读原因。
    func isSpiderPlayable(_ site: Site) -> Bool {
        site.isCatSpiderHTTP
    }

    /// 不可直接播放的原因（必须能说明，不能静默失败）。
    func unsupportedReason(for episode: PlaylistParser.Episode) -> String {
        guard let site else {
            return "缺少站点信息"
        }
        let request = try? PlayRequestBuilder.makeRequest(
            site: site,
            flag: currentLine?.name ?? "",
            playID: episode.url
        )
        guard let request else {
            return "无法构造播放请求"
        }
        switch request.source {
        case .direct:
            if request.requiresParsing {
                return "该集需要解析（parse/jx = 1）：解析链在 M5 实现，当前不可直接播放。"
            }
            return "该集地址无效"
        case .http:
            return "该集需要经 `type=4` 的 `play` 接口中转（尚未实现）。"
        case .spider:
            // 走到这里说明不是可用的 CatSpider HTTP 站点（JAR / Python / api 形态不对）。
            let reason = site.availability.reason ?? "当前平台不支持该 Spider 运行方式"
            return "该集来自 Spider 站点（\(site.spiderRuntimeKind.rawValue)）：\(reason)"
        }
    }
}

/// 明确告知“为什么现在不能播”，避免用户误判为播放器故障。
@MainActor
public struct UnsupportedPlaybackView: View {
    let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var body: some View {
        List {
            Section("暂不可播放") {
                Label("需要额外能力", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("相关计划") {
                Text("M5：解析链（parse/jx、Web 嗅探、聚合解析）")
            }
        }
        .adaptiveListStyle()
        .navigationTitle("暂不可播放")
    }
}
