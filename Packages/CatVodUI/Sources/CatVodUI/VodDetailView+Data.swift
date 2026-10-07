import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import SwiftUI

// 详情页数据逻辑与播放能力判定。

extension VodDetailView {
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
            return "该集中转播放（type=4 的 play 接口）尚未实现（M2 后续）。"
        case .spider:
            return "该集来自 Spider 站点（type=3）：JS 源需内嵌 Node 服务（M1.6），JAR/Python 源在 Apple 平台不支持。"
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
                Text("M1.6：内嵌 Node 运行时（js2p 的 JS 源站点）")
                Text("M5：解析链（parse/jx、Web 嗅探、聚合解析）")
            }
        }
        .adaptiveListStyle()
        .navigationTitle("暂不可播放")
    }
}
