import CatVodNet
import CatVodSource
import SwiftUI

/// Emby 视图顶部：**元信息驱动的背景图 + 标题 + 简介**（M11 第一片）。
///
/// 数据经 `AppModel.tmdbBundle(for:mode:)`（会话缓存 + 并发合流，与选集卡片**共用同一次刮削**），
/// **不把加载状态塞进 `VodDetailView`**：
/// 那片代码已经很大，而元信息是独立的一层 —— 它拉不到也不该拖垮详情本身。
///
/// 三态都明说，不静默：
/// - 拉到了 → 背景图（按 ``PosterMode``）+ 标题 + 简介；
/// - 没配 key → 一行提示 + 站点自带的海报兜底；
/// - 拉失败 / 没搜到 → 一行原因，图仍用站点海报兜底。
struct TMDBDetailHeader: View {
    let model: AppModel
    /// 用来搜 TMDB 的片名（站点详情里的名字）。
    let title: String
    /// 站点自带的海报：TMDB 没结果时兜底，免得顶部空着。
    let fallbackPoster: String
    /// 取图策略（顶部与卡片共用同一套，见 ``PosterPicker``）。
    let mode: PosterMode

    @State private var posterSet: TMDBPosterSet?
    @State private var metadata: TMDBMetadata?
    @State private var noticeText = ""
    /// 轮播步进：每转一格 +1。
    @State private var step = 0
    /// 进页面定一次的随机种子 —— 每一步都换种子会变成闪烁的图（见 ``PosterPicker``）。
    @State private var seed = UInt64.random(in: 0 ..< UInt64.max)

    /// 轮播间隔（秒）。
    private let rotateInterval: TimeInterval = 6

    /// 重新拉取的触发键：片名或取图模式变了才重来（换源 / 设置里换模式都会变）。
    private var loadKey: String {
        "\(title)|\(mode.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            poster
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.title3)
                    .bold()
                if let metadata, !metadata.overview.isEmpty {
                    Text(metadata.overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !noticeText.isEmpty {
                    Text(noticeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: loadKey) {
            await load()
            await rotate()
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let url = posterURL, let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    // 加载中也给**有形状**的骨架，不是空白（与参考视频的加载态一致）。
                    skeleton
                }
            }
            .frame(height: 200)
            .clipped()
            .cornerRadius(12)
        } else {
            skeleton
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 200)
    }

    /// 现在该显示哪张：TMDB 图集优先，其次站点海报。
    private var posterURL: String? {
        if let posterSet, let picked = posterSet.image(step: step, seed: seed) {
            return picked
        }
        return fallbackPoster.isEmpty ? nil : fallbackPoster
    }

    private var displayTitle: String {
        guard let metadata, !metadata.title.isEmpty else {
            return title
        }
        return metadata.title
    }

    private func load() async {
        guard !title.isEmpty else {
            return
        }
        // 重拉之前先清旧值：换源（片名变了）时旧元信息不能留在屏上。
        metadata = nil
        posterSet = nil
        noticeText = ""
        let outcome = await model.tmdbBundle(for: title, mode: mode)
        switch outcome {
        case let .found(bundle):
            metadata = bundle.metadata
            posterSet = bundle.posterSet
        case .disabled:
            noticeText = "元信息刮削已关（详情页「⋯」里可以打开）。"
        case .notConfigured:
            noticeText = "没填 TMDB api key —— 这一层不工作（设置 → 播放 → 播放页）。"
        case .notFound:
            noticeText = "TMDB 里没搜到「\(title)」，暂用站点的海报。"
        case let .failed(reason):
            noticeText = "元信息没取到：\(reason)"
        }
    }

    /// 轮播：等一个间隔、步进一步。只有 `.rotate` 且真有多张图时才转。
    private func rotate() async {
        while !Task.isCancelled, mode == .rotate, (posterSet?.urls.count ?? 0) > 1 {
            try? await Task.sleep(nanoseconds: UInt64(rotateInterval * 1_000_000_000))
            if Task.isCancelled {
                return
            }
            step += 1
        }
    }
}
