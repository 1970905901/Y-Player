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

    /// 自动播放（设置 → 播放 → 播放页 → 自动播放）：**首次进入**时自动选中第一集开播。
    ///
    /// 三个条件同时成立才触发：
    /// 1. 偏好为开；
    /// 2. 没有观看记录 —— 有记录时留给「上次看到」标记，由用户点它续播；
    /// 3. 本次进入还没有触发过（`autoPlayEpisodeIndex == nil`），所以下拉刷新、从播放页返回都不会再弹。
    func scheduleAutoPlayIfNeeded() {
        guard model.autoPlayFirstEpisode, autoPlayEpisodeIndex == nil, !episodes.isEmpty else {
            return
        }
        let hasRecord = progress.map { !$0.isFinished && $0.position > 0 } ?? false
        guard !hasRecord else {
            return
        }
        let episodeIndex = progress?.episodeIndex ?? 0
        guard episodes.indices.contains(episodeIndex) else {
            return
        }
        autoPlayEpisodeIndex = episodeIndex
        // 等一小会儿再激活导航链：详情刚加载完时列表可能还没画出来，
        // 这时直接推入播放页、返回后看到一片空白，观感像「点了没反应」。
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isAutoPlaying = true
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
        return model.playbackResource(MediaResource(
            url: episode.url,
            headers: HTTPHeaderMerger.merge([site.header, detail.header]),
            startPosition: 0,
            format: detail.format,
            title: [vod?.vodName ?? "", episode.name].filter { !$0.isEmpty }.joined(separator: " "),
            artwork: detail.artwork.isEmpty ? (vod?.vodPic ?? "") : detail.artwork
        ))
    }

    /// 该站点能否走 CatSpider 的 `play` 接口（js2p 宿主站点）。
    ///
    /// 只说明「协议形态对」；宿主没起来时 `play` 会失败并给出可读原因。
    func isSpiderPlayable(_ site: Site) -> Bool {
        site.isCatSpiderHTTP
    }

    /// 该集是否要走站点的 play 接口换地址（`type=4`）。
    ///
    /// 与 ``canParse(_:)`` / ``makeResource(for:)`` 同一套判定：都拿 ``PlayRequestBuilder`` 的结果说话，
    /// 而不是自己按站点类型猜。返回 true 时由 ``SitePlayEpisodeView`` 负责异步换地址。
    func requiresSitePlay(_ site: Site, episode: PlaylistParser.Episode) -> Bool {
        guard !episode.url.isEmpty else {
            return false
        }
        let request = try? PlayRequestBuilder.makeRequest(
            site: site,
            flag: currentLine?.name ?? "",
            playID: episode.url
        )
        guard let request, case .http = request.source else {
            return false
        }
        return true
    }

    /// 向站点 / 宿主换一集的播放地址（与 ``SitePlayEpisodeView`` 同一条路）。
    ///
    /// 与那条路的**唯一区别**：这里不处理「站点说还要再解析一次」—— 那种集播放页不自己换，
    /// 返回 nil 让界面提示回详情页（解析链要换页面、要等 Web 嗅探，不适合在播放页里悄悄切）。
    func siteResource(site: Site, episode: PlaylistParser.Episode) async -> MediaResource? {
        guard let result = try? await model.makeSiteClient().play(
            site: site,
            flag: currentLine?.name ?? "",
            id: episode.url
        ) else {
            return nil
        }
        model.notePlaybackInfo(from: result)
        await model.loadSubtitles(SubtitleRequest(
            sources: result.subs,
            headers: HTTPHeaderMerger.merge([site.header, result.header])
        ))
        guard let playURL = result.primaryPlaybackURL,
              !playURL.isEmpty,
              !result.requiresParsing
        else {
            return nil
        }
        return model.playbackResource(MediaResource(
            url: playURL,
            headers: HTTPHeaderMerger.merge([site.header, result.header]),
            startPosition: 0,
            format: result.format,
            title: episode.displayName,
            artwork: result.artwork
        ))
    }

    /// 逐集换地址后入队（M10i 下半场）：**串行**换（一次一集），换到一集立刻入队并开跑；
    /// 换不到的记着，最后用 ``SiteDownloadSummary`` 如实报账。
    ///
    /// 为什么串行：宿主是单进程的（内嵌 node），站点 `/play` 也共享同一条连接 ——
    /// 换来的是「进度可读、失败能归因」，比省几秒重要。
    func enqueueSiteDownloads(site: Site) async {
        let targets = siteDownloadEpisodes
        guard !targets.isEmpty, !isResolvingDownloads else {
            return
        }
        isResolvingDownloads = true
        defer { isResolvingDownloads = false }

        var queued = 0
        var existing = 0
        var failed = 0
        for (offset, episode) in targets.enumerated() {
            resolvingDownloadsText = "正在换地址 \(offset + 1)/\(targets.count)：\(episode.displayName)"
            guard let resource = await siteResource(site: site, episode: episode) else {
                failed += 1
                continue
            }
            let outcome = await model.enqueueDownloadsAndStart(
                [DownloadRequest(episode: episode.displayName, line: currentLine?.name ?? "", url: resource.url)],
                siteKey: site.key,
                title: vod?.vodName ?? "",
                headers: resource.headers
            )
            switch outcome {
            case .added:
                queued += 1
            case .alreadyQueued:
                existing += 1
            case .unsupported:
                failed += 1
            }
        }
        resolvingDownloadsText = SiteDownloadSummary.text(queued: queued, alreadyQueued: existing, failed: failed)
    }

    /// 该集是否应该交给解析链（M5b/M5c）。
    ///
    /// 判定条件与 ``PlayRequestBuilder`` 一致：`type 0/1/2/4` 的站点、地址非空、且 `parse/jx = 1`
    /// 导致不能直链（`requiresParsing`）。至于「用哪个解析器、能不能执行」由
    /// ``ParsePlaybackView`` 内部的 ``ParseJobResolver`` 决定并给出可读原因。
    func canParse(_ episode: PlaylistParser.Episode) -> Bool {
        guard let site, !episode.url.isEmpty else {
            return false
        }
        guard let request = try? PlayRequestBuilder.makeRequest(
            site: site,
            flag: currentLine?.name ?? "",
            playID: episode.url
        ) else {
            return false
        }
        guard case .direct = request.source else {
            return false
        }
        return request.requiresParsing
    }

    /// 选集行是否要显示「不支持」的感叹号：能直链、能走 Spider、能走解析链的都不显示。
    func showsUnsupportedBadge(for episode: PlaylistParser.Episode) -> Bool {
        if makeResource(for: episode) != nil {
            return false
        }
        if let site, isSpiderPlayable(site) {
            return false
        }
        return !canParse(episode)
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
                return "该集需要解析（parse/jx = 1），但配置里给不出可用的解析器（`parses` 为空，或站点级/结果级 `playUrl` 都没有解析指令）。"
            }
            return "该集地址无效"
        case .http:
            // type=4 会走 `SitePlayEpisodeView` 的 play 接口（M06n），正常不会落在这里；
            // 真落到这里说明路由与站点类型判定不一致。
            return "该集需要由站点的 `play` 接口换取播放地址，当前没能取到。"
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
    /// 重试动作：给了就显示「重试」按钮（M16P8）。
    ///
    /// 只给**瞬态**失败挂它（宿主 / 网络 / 解析失败）；「站点类型不支持」这种再试也没用的不挂。
    let onRetry: (() -> Void)?
    /// 补充提示（例如宿主日志与重启入口在哪）。
    let hint: String?

    public init(reason: String, onRetry: (() -> Void)? = nil, hint: String? = nil) {
        self.reason = reason
        self.onRetry = onRetry
        self.hint = hint
    }

    public var body: some View {
        List {
            Section("暂不可播放") {
                Label("需要额外能力", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let onRetry {
                    Button("重试") {
                        onRetry()
                    }
                }
            }
            if let hint {
                Section("排查") {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("暂不可播放")
        .immersiveTabBarPage()
    }
}
