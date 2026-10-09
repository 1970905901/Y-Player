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
    private var wholeLineDownloadsRow: some View {
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

    public var body: some View {
        content
            .navigationTitle(vod?.vodName.isEmpty == false ? (vod?.vodName ?? "详情") : "详情")
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
    private var autoPlayLink: some View {
        if let index = autoPlayEpisodeIndex, episodes.indices.contains(index) {
            NavigationLink(isActive: $isAutoPlaying) {
                destination(for: episodes[index], at: index)
            } label: {
                EmptyView()
            }
        }
    }

    // MARK: - Emby 视图

    /// Emby 视图（设置 → 播放 → 播放页 → 显示视图）：大封面 + 横向滚动的线路与选集卡片。
    ///
    /// 数据与精简视图完全相同（`detail` / `lines` / `episodes` / `progress`），
    /// 只是把「一行行文字」换成「卡片 + 横向滚动」—— 收藏、换源、续播的行为一致。
    private var embyLayout: some View {
        List {
            // 元信息那一层（M11）：顶部背景图 / 标题 / 简介按 TMDB 来。
            //
            // 注意仍是**列表里的一行**、不是全幅 —— 参考视频里它是铺满顶部的。
            // 做全幅要把它挪到 List 外面（整块布局要动），那是这一片之后单独一步，
            // 不在这里顺手改（改布局和接元信息混一笔，出问题分不清是谁）。
            TMDBDetailHeader(
                model: model,
                title: vod?.vodName ?? "",
                fallbackPoster: detail.artwork,
                mode: model.tmdbPosterMode
            )
            embyHeader
            if lines.count > 1 {
                embyLineSection
            }
            embyEpisodeSection
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

    /// 头部：大封面 + 片名与信息列 + 简介。
    private var embyHeader: some View {
        Section("影片") {
            if isLoading, detail.list.isEmpty {
                Text("加载中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let vod {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: URL(string: vod.vodPic)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.15)
                        }
                        .frame(width: 104, height: 146)
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
                            if let summary = progressSummary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !vod.vodContent.isEmpty {
                        Text(vod.vodContent)
                            .font(.footnote)
                            .lineLimit(6)
                    }
                }
            }
        }
    }

    /// 线路：横向滚动的胶囊按钮（选中项加重底色）。
    private var embyLineSection: some View {
        Section("线路") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            selectedLineIndex = index
                        } label: {
                            Text(line.name)
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        index == selectedLineIndex
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.12)
                                    )
                                )
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 选集：横向滚动的卡片（集名 + 不支持角标 + 上次看到标记）。
    private var embyEpisodeSection: some View {
        Section("选集") {
            wholeLineDownloadsRow
            if episodes.isEmpty {
                Text(isLoading ? "加载中…" : "没有可用线路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        NavigationLink {
                            destination(for: episode, at: index)
                        } label: {
                            embyEpisodeCard(episode, at: index)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 单张选集卡片。
    private func embyEpisodeCard(_ episode: PlaylistParser.Episode, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(episode.name.isEmpty ? "第 \(index + 1) 集" : episode.name)
                    .font(.footnote)
                    .lineLimit(1)
                if showsUnsupportedBadge(for: episode) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if isLastWatched(index) {
                Text("上次看到")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius)
                .fill(Color.secondary.opacity(0.12))
        )
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
    private var progressSummary: String? {
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
    private func isLastWatched(_ index: Int) -> Bool {
        guard let progress, !progress.isFinished else {
            return false
        }
        return progress.episodeIndex == index && progress.position > 0
    }

    @ViewBuilder
    private func destination(for episode: PlaylistParser.Episode, at index: Int) -> some View {
        if let resource = makeResource(for: episode) {
            PlaybackView(
                resource: resource,
                title: episode.displayName,
                settings: model.playbackSettings,
                progressContext: progressContext(for: episode, at: index),
                progressStore: model.progressStore
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
                progressKey: progressKey
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
                progressKey: progressKey
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
