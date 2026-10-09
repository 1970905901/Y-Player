import CatVodCore
import CatVodSource
import CatVodStore
import SwiftUI

/// 详情页：影片信息 → 线路 → 选集 → 播放。
///
/// 播放能力边界：
/// - 直链且无需解析的集（`parse = 0`）可直接用系统播放器播放；
/// - js2p / CatSpider HTTP 站点（`type=3` 且 `api` 含 `/spider/`）与 `type=4` 站点走 ``SitePlayEpisodeView``：
///   先用 `POST /play` 换取地址（需要宿主就绪，见 `docs/任务记录/M16P3-macOS宿主接通.md`）；
/// - 需要解析的集（`parse/jx = 1`）依赖 M5 的解析链；JAR / Python Spider 在 Apple 平台不支持。
/// 以上不可播放的情况都会进入 ``UnsupportedPlaybackView`` 并说明原因，不静默失败。
@MainActor
public struct VodDetailView: View {
    @ObservedObject var model: AppModel
    /// 当前站点/条目：**换源会就地替换**，因此是 `@State` 而不是 `let`。
    @State var site: Site?
    @State var vodID: String

    @State var detail = SpiderResult()
    @State var lines: [PlaylistParser.Line] = []
    @State var selectedLineIndex = 0
    @State var isLoading = false
    @State var errorText = ""
    @State private var isShowingChangeSource = false
    /// 本片进度：`+Data.swift` 里的 `loadProgress()` / `switchSource(to:)` 也要读写，因此**不能是 private**。
    @State var progress: PlaybackProgress?
    /// 是否已收藏：`+Data.swift` 里的 `loadFavorite()` / `toggleFavorite()` 读写，因此不能是 private。
    @State var isFavorite = false
    /// 自动播放待进入的集下标（`nil` = 不触发）；由 `+Data.swift` 在详情加载完成后写入。
    @State var autoPlayEpisodeIndex: Int?
    /// 隐藏导航链的激活开关（`NavigationLink(isActive:)`，iOS 15 / macOS 13 都支持）。
    ///
    /// 由 `+Data.swift` 的 `scheduleAutoPlayIfNeeded()` 打开，因此**不能是 private**
    /// （`private` 只对声明所在文件开放）。
    @State var isAutoPlaying = false

    /// 选集卡片取图的随机种子：进页面定一次（`.random` 模式下卡片用它 + 下标打散，见 ``PosterPicker``）。
    @State var episodePosterSeed = UInt64.random(in: 0 ..< UInt64.max)
    /// 选集卡片共用的取图集（与顶部同一次刮削，经 `AppModel.tmdbBundle(for:mode:)` 缓存与合流）。
    @State var episodePosterSet: TMDBPosterSet?
    /// 同一次刮削的元信息（简介那一行要用；没刮到时为 nil）。
    @State var episodeMetadata: TMDBMetadata?
    /// 剧集列表抽屉是否展开（M11：选集区头的「更多」；回传的跳转走 `openEpisode(at:)`）。
    @State var isEpisodeDrawerPresented = false
    /// 「⋯」→ 手动匹配元信息（M11 片 5）的面板是否打开。
    @State var isShowingMetadataMatch = false

    public init(model: AppModel, site: Site?, vodID: String) {
        self.model = model
        _site = State(initialValue: site)
        _vodID = State(initialValue: vodID)
    }

    var vod: VodItem? {
        detail.list.first
    }

    /// 进度记录键（站点 + vodID）；缺站点时为 nil（不记录）。
    var progressKey: PlaybackKey? {
        guard let site else {
            return nil
        }
        return PlaybackKey(siteKey: site.key, vodID: vodID)
    }

    var currentLine: PlaylistParser.Line? {
        guard lines.indices.contains(selectedLineIndex) else {
            return lines.first
        }
        return lines[selectedLineIndex]
    }

    var episodes: [PlaylistParser.Episode] {
        currentLine?.episodes ?? []
    }

    /// 「整部下载」能排的集：**现在就能直接播**的那些。
    ///
    /// 判定用详情页自己那套 ``makeResource(for:)``（也就是 `PlayRequestBuilder` 说「直链且无需解析」）
    /// —— 不另立一套规则，免得「按钮说能下、点进去播不了」。
    var directDownloadEpisodes: [PlaylistParser.Episode] {
        episodes.filter { makeResource(for: $0) != nil }
    }

    /// 「整部下载」入口（M10i）。两种视图形态（精简 / Emby）共用这一行，免得只有一种形态有入口。
    ///
    /// 只排上面那批，原因不藏：`type=3/4` 站点的播放地址要**逐集**去站点异步换
    /// （``SitePlayEpisodeView`` 那条路），整条线路的批量换地址还没接 —— 所以被跳过的集数
    /// 直接写在下面，不假装整部都排上了。
    @ViewBuilder
    // （internal：拆分出的 `VodDetailView+Emby.swift` 也要用，不能是 private。）
    var wholeLineDownloadsRow: some View {
        if let site, !directDownloadEpisodes.isEmpty {
            Button {
                let requests = directDownloadEpisodes.map {
                    DownloadRequest(episode: $0.displayName, line: currentLine?.name ?? "", url: $0.url)
                }
                Task {
                    await model.enqueueDownloads(requests, siteKey: site.key, title: vod?.vodName ?? "")
                    await model.runDownloadQueue()
                }
            } label: {
                Label("整部下载（\(directDownloadEpisodes.count) 集）", systemImage: "arrow.down.circle")
            }
            if episodes.count > directDownloadEpisodes.count {
                Text("另有 \(episodes.count - directDownloadEpisodes.count) 集要逐集向站点换地址，暂不支持整部下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Emby 视图的成员已拆到 VodDetailView+Emby.swift（类型体超过 SwiftLint 上限，见该文件说明）。

    public var body: some View {
        content
            .navigationTitle(vod?.vodName.isEmpty == false ? (vod?.vodName ?? "详情") : "详情")
            // 详情页是沉浸页：登记给本 Tab 的根页面，由它把底部 Tab 栏收起来（见 Platform/AdaptiveTabBar.swift）。
            .immersiveTabBarPage()
            .refreshable {
                await loadDetail(force: true)
                await loadProgress()
            }
            .adaptiveToolbar {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "heart.fill" : "heart")
                }
                .disabled(progressKey == nil)
            } trailing: {
                Button {
                    isShowingChangeSource = true
                } label: {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.sites.count < 2)
            }
            .sheet(isPresented: $isShowingChangeSource) {
                ChangeSourceView(
                    model: model,
                    title: vod?.vodName ?? "",
                    currentSiteKey: site?.key,
                    onPick: { candidate in
                        switchSource(to: candidate)
                    }
                )
            }
            .task {
                await loadDetail()
                await loadProgress()
                await loadFavorite()
                // 自动播放（设置 → 播放 → 播放页）放在进度之后：有观看记录时以「上次看到」为准，
                // 不把用户从上次的位置拽回第一集。
                scheduleAutoPlayIfNeeded()
            }
            .onAppear {
                // 从播放页返回时刷新「上次看到这里」标记与收藏状态。
                Task {
                    await loadProgress()
                    await loadFavorite()
                }
            }
    }

    /// 按「显示视图」（设置 → 播放 → 播放页 → 显示视图）选排布。
    ///
    /// 两种视图**共用同一份数据与同一套工具**（收藏 / 换源 / 续播 / 自动播放），只换排布，
    /// 所以切换视图不会丢任何状态。
    @ViewBuilder
    private var content: some View {
        switch model.playbackPageLayout {
        case .compact:
            compactLayout
        case .emby:
            embyLayout
        }
    }

    /// 精简视图：影片信息 + 线路分段控件 + 选集列表（M2 以来的形态）。
    private var compactLayout: some View {
        List {
            headerSection
            if lines.count > 1 {
                lineSection
            }
            episodesSection
            if !errorText.isEmpty {
                Section("错误") {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .adaptiveListStyle()
        .background(autoPlayLink)
    }

    /// 自动播放用的隐藏导航链（设置 → 播放 → 播放页 → 自动播放）。
    ///
    /// 用 `NavigationLink(isActive:)` 而不是 `navigationDestination`：后者要 iOS 16+，
    /// 而本项目下限是 iOS 15（`docs/UI 规范.md`：不为统一观感抬高下限）。
    /// 挂在 `background` 上而不是当作列表行：列表行会占掉一行高度，留一片空白。
    @ViewBuilder
    // （internal：拆分出的 `VodDetailView+Emby.swift` 也要用，不能是 private。）
    var autoPlayLink: some View {
        if let index = autoPlayEpisodeIndex, episodes.indices.contains(index) {
            NavigationLink(isActive: $isAutoPlaying) {
                destination(for: episodes[index], at: index)
            } label: {
                EmptyView()
            }
        }
    }

    // MARK: - 区块

    private var headerSection: some View {
        Section("影片") {
            if isLoading, detail.list.isEmpty {
                Text("加载中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let vod {
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: URL(string: vod.vodPic)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                    .frame(width: 80, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(vod.vodName.isEmpty ? vod.vodID : vod.vodName)
                            .font(.headline)
                        if !vod.vodRemarks.isEmpty {
                            Text(vod.vodRemarks)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !vod.typeName.isEmpty {
                            Text(vod.typeName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !vod.vodYear.isEmpty || !vod.vodArea.isEmpty {
                            Text([vod.vodYear, vod.vodArea].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !vod.vodActor.isEmpty {
                    Text("演员：\(vod.vodActor)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !vod.vodDirector.isEmpty {
                    Text("导演：\(vod.vodDirector)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !vod.vodContent.isEmpty {
                    Text(vod.vodContent)
                        .font(.footnote)
                }
                if let summary = progressSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var lineSection: some View {
        Section("线路") {
            Picker("线路", selection: $selectedLineIndex) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line.name).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var episodesSection: some View {
        Section("选集") {
            wholeLineDownloadsRow
            if episodes.isEmpty {
                Text(isLoading ? "加载中…" : "没有可用线路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                NavigationLink {
                    destination(for: episode, at: index)
                } label: {
                    HStack {
                        Text(episode.name.isEmpty ? "播放" : episode.name)
                        if isLastWatched(index) {
                            Text("上次看到")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if showsUnsupportedBadge(for: episode) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    /// 「上次看到 · 第 N 集 · 12:34」；没有进度时为 nil。
    // （internal：拆分出的 `VodDetailView+Emby.swift` 也要用，不能是 private。）
    var progressSummary: String? {
        guard let progress, !progress.isFinished, progress.position > 0 else {
            return nil
        }
        let episodeName = episodes.indices.contains(progress.episodeIndex)
            ? episodes[progress.episodeIndex].displayName
            : ""
        return ["上次看到", episodeName, PlaybackView.timeText(progress.position)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 是否为「上次看到」的那一集（**当前线路内**下标；跨线路/跨站对齐留 M8）。
    // （internal：拆分出的 `VodDetailView+Emby.swift` 也要用，不能是 private。）
    func isLastWatched(_ index: Int) -> Bool {
        guard let progress, !progress.isFinished else {
            return false
        }
        return progress.episodeIndex == index && progress.position > 0
    }

    /// 播放页自己的换集能力（M12P1）：把「第 i 集怎么变成资源」包成闭包交给播放页
    /// —— 播放页不认识站点，换集的路子由详情页决定。
    ///
    /// 三种集走三条路（与 ``destination(for:at:)`` 的分派一一对应）：
    /// - 直链（type 0/1/2）：同步造资源；
    /// - 要向站点 / 宿主换地址（type 3/4）：异步换（与 `SitePlayEpisodeView` 同一条路）；
    /// - 需要解析链的集：返回 nil —— 那条路播放页不自己走，界面会提示回详情页点。
    func episodePlaylist(currentIndex: Int) -> PlaybackPlaylist {
        PlaybackPlaylist(
            episodes: episodes,
            currentIndex: currentIndex,
            loadResource: { index in
                guard episodes.indices.contains(index) else {
                    return nil
                }
                let target = episodes[index]
                let context = progressContext(for: target, at: index)
                if let resource = makeResource(for: target) {
                    return PlaybackEpisodeResource(
                        resource: resource,
                        progressContext: context,
                        title: target.displayName
                    )
                }
                guard let site, isSpiderPlayable(site) || requiresSitePlay(site, episode: target) else {
                    return nil
                }
                guard let resource = await siteResource(site: site, episode: target) else {
                    return nil
                }
                return PlaybackEpisodeResource(
                    resource: resource,
                    progressContext: context,
                    title: target.displayName
                )
            }
        )
    }

    @ViewBuilder
    // （internal：拆分出的 `VodDetailView+Emby.swift` 也要用，不能是 private。）
    func destination(for episode: PlaylistParser.Episode, at index: Int) -> some View {
        // 播放页自己的换集能力（M12P1）：详情页知道「集列表 + 线路 + 站点」，包成闭包交给它。
        let playlist = episodePlaylist(currentIndex: index)
        if let resource = makeResource(for: episode) {
            PlaybackView(
                resource: resource,
                title: episode.displayName,
                settings: model.playbackSettings,
                progressContext: progressContext(for: episode, at: index),
                progressStore: model.progressStore,
                playlist: playlist
            )
        } else if let site, isSpiderPlayable(site) {
            // js2p / CatSpider 站点：播放地址要用 `POST /play` 换，因此走异步入口。
            SitePlayEpisodeView(
                model: model,
                site: site,
                episode: episode,
                title: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episodeIndex: index,
                progressKey: progressKey,
                playlist: playlist
            )
        } else if let site, requiresSitePlay(site, episode: episode) {
            // type=4：播放地址要用站点的 `play` 接口换（`play` + `flag`），同样是异步入口（M06n）。
            SitePlayEpisodeView(
                model: model,
                site: site,
                episode: episode,
                title: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episodeIndex: index,
                progressKey: progressKey,
                playlist: playlist
            )
        } else if let site, canParse(episode) {
            // 需要解析（`parse/jx = 1`）的集：走解析链（M5b 已支持 type=1 JSON；type=0/4 会给出 M5c 的原因）。
            ParsePlaybackView(
                model: model,
                site: site,
                vodName: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episode: episode,
                episodeIndex: index,
                detail: detail,
                progressKey: progressKey
            )
        } else {
            UnsupportedPlaybackView(reason: unsupportedReason(for: episode))
        }
    }
}
