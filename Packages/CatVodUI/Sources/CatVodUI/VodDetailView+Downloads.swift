import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 详情页的**下载入口**一簇（M10i / M10i 下半场）：整部下载的两批集怎么算、点了以后怎么排。
///
/// 拆出来的原因很实在：`VodDetailView` 的**类型体**逼近 SwiftLint `type_body_length`
/// 的 error 线（450 行；CI 的 lint 是阻断项），扩展不计入类型体 —— 与 `VodDetailView+Data.swift`
/// / `VodDetailView+Emby.swift` 是同一个做法。
///
/// 这些成员因此**不能写 `private`**（private 是文件级，跨文件就看不见了）。
extension VodDetailView {
    /// 「整部下载」能排的集：**现在就能直接播**的那些。
    ///
    /// 判定用详情页自己那套 ``makeResource(for:)``（也就是 `PlayRequestBuilder` 说「直链且无需解析」）
    /// —— 不另立一套规则，免得「按钮说能下、点进去播不了」。
    var directDownloadEpisodes: [PlaylistParser.Episode] {
        episodes.filter { makeResource(for: $0) != nil }
    }

    /// 「整部下载」的第二批：要**逐集向站点 / 宿主换地址**的那些（`type=3/4`）。
    ///
    /// 判定与「能不能换地址」那一处**完全一致**（``isSpiderPlayable(_:)`` 或
    /// ``requiresSitePlay(_:episode:)``，换地址走 ``siteResource(site:episode:)``）——
    /// 不另立规则，免得「按钮说能下、换出来是空的」。
    var siteDownloadEpisodes: [PlaylistParser.Episode] {
        guard let site else {
            return []
        }
        return episodes.filter { episode in
            makeResource(for: episode) == nil
                && (isSpiderPlayable(site) || requiresSitePlay(site, episode: episode))
        }
    }

    /// 「整部下载」入口（M10i；逐集换地址那一半是 M10i 下半场）。两种视图形态（精简 / Emby）
    /// 共用这一行，免得只有一种形态有入口。
    ///
    /// 分两批，**各自说清自己那一批有多少集**：
    /// - 直链可下的（``directDownloadEpisodes``）：一次全排上；
    /// - 要逐集向站点 / 宿主换地址的（``siteDownloadEpisodes``）：点了以后**串行**换、换到一集排一集，
    ///   进度与最终结果都写在下面（见 ``SiteDownloadSummary``）；
    /// - 剩下那些（要走解析链 / 没有地址）**不排**，也如实写出条数 —— 不假装整部都排上了。
    @ViewBuilder
    // （internal：拆分出的 `VodDetailView+Emby.swift` 也要用，不能是 private。）
    var wholeLineDownloadsRow: some View {
        if let site {
            if !directDownloadEpisodes.isEmpty {
                Button {
                    let requests = directDownloadEpisodes.map {
                        DownloadRequest(episode: $0.displayName, line: currentLine?.name ?? "", url: $0.url)
                    }
                    Task {
                        // 入队即开跑（M10h）：不用等用户再进「下载管理」页。
                        await model.enqueueDownloadsAndStart(requests, siteKey: site.key, title: vod?.vodName ?? "")
                    }
                } label: {
                    Label("整部下载（\(directDownloadEpisodes.count) 集）", systemImage: "arrow.down.circle")
                }
            }
            if !siteDownloadEpisodes.isEmpty {
                Button {
                    Task { await enqueueSiteDownloads(site: site) }
                } label: {
                    Label("整部下载（逐集换地址，\(siteDownloadEpisodes.count) 集）", systemImage: "arrow.down.circle")
                }
                .disabled(isResolvingDownloads)
                if !resolvingDownloadsText.isEmpty {
                    Text(resolvingDownloadsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            let unresolved = episodes.count - directDownloadEpisodes.count - siteDownloadEpisodes.count
            if unresolved > 0 {
                Text("另有 \(unresolved) 集要走解析链或没有可用地址，整部下载排不上 —— 单独播一次再用播放页的「下载本集」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
