import CatVodCore
import CatVodSource
import CatVodStore
import SwiftUI

/// 详情页：影片信息 → 线路 → 选集 → 播放。
///
/// 播放能力边界：
/// - 直链且无需解析的集（`parse = 0`）可直接用系统播放器播放；
/// - js2p / CatSpider HTTP 站点（`type=3` 且 `api` 含 `/spider/`）走 ``SpiderEpisodePlaybackView``：
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

    public var body: some View {
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
        .navigationTitle(vod?.vodName.isEmpty == false ? (vod?.vodName ?? "详情") : "详情")
        .refreshable {
            await loadDetail(force: true)
            await loadProgress()
        }
        .adaptiveToolbar {
            EmptyView()
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
        }
        .onAppear {
            // 从播放页返回时刷新「上次看到这里」标记。
            Task { await loadProgress() }
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
                        if makeResource(for: episode) == nil, !(site.map(isSpiderPlayable) ?? false) {
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
                progressKey: progressKey,
                progressEpisodeIndex: index,
                progressStore: model.progressStore
            )
        } else if let site, isSpiderPlayable(site) {
            // js2p / CatSpider 站点：播放地址要用 `POST /play` 换，因此走异步入口。
            SpiderEpisodePlaybackView(
                model: model,
                site: site,
                episode: episode,
                title: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episodeIndex: index,
                progressKey: progressKey
            )
        } else {
            UnsupportedPlaybackView(reason: unsupportedReason(for: episode))
        }
    }
}
