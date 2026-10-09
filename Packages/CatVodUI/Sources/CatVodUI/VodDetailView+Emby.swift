import CatVodCore
import CatVodSource
import CatVodStore
import SwiftUI

/// Emby 视图（M11）的成员：加载骨架、大播放按钮、图标行、Emby 版式与选集横滑。
///
/// 拆出来的原因很实在：`VodDetailView` 的**类型体**超过 SwiftLint `type_body_length`
/// 的 error 线（450 行）。扩展不计入类型体 —— 与仓库既有的 `VodDetailView+Data.swift`
/// 是同一个做法。
///
/// 这些成员因此**不能写 `private`**（private 是文件级，跨文件就看不见了）。
/// 它们访问的 `detail` / `episodes` / `progress` / `model` 等本来就是 internal；
/// 反向依赖（`wholeLineDownloadsRow` / `autoPlayLink` / `progressSummary` /
/// `isLastWatched(_:)` / `destination(for:at:)`）随本次拆分从 private 放宽到 internal，
/// 主文件里各自带一行说明。
extension VodDetailView {
    /// 骨架加载态（M11）：和真布局**同一副骨架** —— 封面 + 几行字 + 播放条 + 选集条。
    ///
    /// 参考视频里加载中就是这个形状，不是一个居中转圈。所以第一次进页面时，
    /// 屏幕上先出现「就是这里将来会有东西」的灰块，内容回来时原地换成真东西、不跳版。
    var embySkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                skeletonBlock(width: 104, height: 146)
                VStack(alignment: .leading, spacing: 8) {
                    skeletonBlock(width: 140, height: 16)
                    skeletonBlock(width: 96, height: 12)
                    skeletonBlock(width: 120, height: 12)
                    skeletonBlock(width: 72, height: 12)
                }
            }
            // 播放条
            skeletonBlock(width: nil, height: 34)
            // 选集：参考视频是两张一行，这里先铺一排占位
            HStack(spacing: 8) {
                skeletonBlock(width: 56, height: 76)
                skeletonBlock(width: 56, height: 76)
                skeletonBlock(width: 56, height: 76)
                skeletonBlock(width: 56, height: 76)
            }
        }
    }

    /// 灰块：`width: nil` 表示占满可用宽度。
    func skeletonBlock(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    /// 图标行（M11）。**目前只有「⋯」** —— 参考视频里还有 🔍 聚合搜索与 ♡ 收藏，
    /// 那两项各自的落地点（海报墙搜索页、收藏落地）是独立的片，**先不放空按钮**：
    /// 按下去没反应比没有这个按钮更糟。
    ///
    /// 菜单里的每一项都真的做事，且都能在别处找到同一套逻辑（不各写一份）。
    var iconRow: some View {
        HStack {
            Spacer()
            Menu {
                Toggle("元信息刮削", isOn: $model.tmdbScrapeEnabled)
                Text(model.isTMDBConfigured ? "TMDB 已配置" : "TMDB 未配置（设置 → 播放 → 播放页）")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            Spacer()
        }
    }

    /// 该播哪一集：**有观看记录就是那一集**（=「继续播放」），否则第一集。
    var playSlot: (index: Int, episode: PlaylistParser.Episode)? {
        guard let first = episodes.first else {
            return nil
        }
        let index = progress?.episodeIndex ?? 0
        guard episodes.indices.contains(index) else {
            return (0, first)
        }
        return (index, episodes[index])
    }

    /// 大播放按钮（M11）：参考视频里它是**上行动作 + 下行信息**两行。
    ///
    /// 下行用的是站点给的集名 —— 视频里那一行 `[1.4GB]157.mp4 【X 仙逆】 · 01:51`
    /// 就是「文件名（自带体积）+ 上次进度」，两个数据站点都已经给了，不用另造。
    @ViewBuilder
    var playButtonRow: some View {
        if let slot = playSlot {
            NavigationLink {
                destination(for: slot.episode, at: slot.index)
            } label: {
                VStack(spacing: 2) {
                    Label(actionTitle, systemImage: "play.fill")
                        .font(.headline)
                    if !subtitle(of: slot.episode).isEmpty {
                        Text(subtitle(of: slot.episode))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 「继续播放」还是「播放」：**有进度且没看完**才叫继续。
    var actionTitle: String {
        guard let progress, progress.position > 0, !progress.isFinished else {
            return "播放"
        }
        return "继续播放"
    }

    func subtitle(of episode: PlaylistParser.Episode) -> String {
        var parts = [episode.displayName]
        if let progress, progress.position > 0, !progress.isFinished {
            parts.append(Self.timeText(Int(progress.position)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `01:51` / `1:02:03`。自己拼不用 `String(format:)`，省一个 Foundation 依赖。
    static func timeText(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        func pad(_ value: Int) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        return hour > 0
            ? "\(hour):\(pad(minute)):\(pad(second))"
            : "\(pad(minute)):\(pad(second))"
    }

    // MARK: - Emby 视图

    /// Emby 视图（设置 → 播放 → 播放页 → 显示视图）：大封面 + 横向滚动的线路与选集卡片。
    ///
    /// 数据与精简视图完全相同（`detail` / `lines` / `episodes` / `progress`），
    /// 只是把「一行行文字」换成「卡片 + 横向滚动」—— 收藏、换源、续播的行为一致。
    var embyLayout: some View {
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
    var embyHeader: some View {
        Section("影片") {
            playButtonRow
            iconRow
            if isLoading, detail.list.isEmpty {
                // 第一次进页面才给骨架；内容回来后原地换掉。
                embySkeleton
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
    var embyLineSection: some View {
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
    var embyEpisodeSection: some View {
        Section("选集") {
            wholeLineDownloadsRow
            if episodes.isEmpty {
                if isLoading {
                    // 选集区的加载态：和卡片同一副骨架（一排灰卡片），不是一行小字 ——
                    // 参考视频里加载中屏幕上就是这些形状。卡片接图后高度跟着改。
                    HStack(spacing: 8) {
                        skeletonBlock(width: 92, height: 48)
                        skeletonBlock(width: 92, height: 48)
                        skeletonBlock(width: 92, height: 48)
                    }
                } else {
                    Text("没有可用线路")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 8) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                            NavigationLink {
                                destination(for: episode, at: index)
                            } label: {
                                embyEpisodeCard(episode, at: index)
                            }
                            .buttonStyle(.borderless)
                            .id(index)
                        }
                    }
                    .padding(.vertical, 2)
                    .onAppear { centerCurrentEpisode(on: proxy) }
                    .onChange(of: selectedLineIndex) { _ in centerCurrentEpisode(on: proxy) }
                }
            }
        }
    }

    /// 单张选集卡片。
    func embyEpisodeCard(_ episode: PlaylistParser.Episode, at index: Int) -> some View {
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

    /// 把「该播的那一集」滚到横滑正中 —— 参考视频里当前集在中间，不在左端。
    ///
    /// 两处刻意的写法：
    /// 1. 先 `Task.sleep` 一小会儿再滚：进页面时卡片还没布局完，立刻滚会滚不动
    ///    （`ScrollViewReader` 的常见坑）；
    /// 2. 换线路也滚一次（`selectedLineIndex`）：集数变了，位置不该留在上一条线路的地方。
    ///
    /// `onChange` 用的是单参数闭包版本 —— 双参数版要 iOS 17，本目标的底线是 iOS 15。
    func centerCurrentEpisode(on proxy: ScrollViewProxy) {
        guard let slot = playSlot else {
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(slot.index, anchor: .center)
            }
        }
    }
}
