import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import CatVodStore
import SwiftUI

/// 「需要解析」的集的播放入口：先按解析链换出真实地址，再进播放页。
///
/// 与 ``SpiderEpisodePlaybackView``（`type=3` 的 `POST /play`）同一形态：解析是**异步**的，
/// 塞不进 `@ViewBuilder` 的同步 `destination(for:at:)`，因此单开一层。
///
/// 当前能执行 `type=1`（JSON）解析（M5b）；`type=0` Web 嗅探与 `type=4` 聚合属 M5c，
/// 页面会给出明确原因而不是静默失败（见 `docs/任务记录/M05b-type1-JSON解析.md`）。
@MainActor
struct ParsePlaybackView: View {
    let model: AppModel
    let site: Site
    /// 影片名（播放页标题与进度元数据都用它）。
    let vodName: String
    /// 线路名（协议里的 `flag`）。
    let lineName: String
    let episode: PlaylistParser.Episode
    let episodeIndex: Int
    /// 详情返回的原始结果（`playUrl`/`header`/`click`/`format`/`artwork` 都从这里取）。
    let detail: SpiderResult
    let progressKey: PlaybackKey?

    @State private var parsed: ParsedPlayback?
    @State private var errorText = ""

    var body: some View {
        Group {
            if let parsed {
                PlaybackView(
                    resource: resource(from: parsed),
                    title: episode.displayName,
                    settings: model.playbackSettings,
                    progressContext: progressContext,
                    progressStore: model.progressStore
                )
            } else if errorText.isEmpty {
                ProgressView("正在解析播放地址…")
                    .navigationTitle(episode.displayName)
            } else {
                UnsupportedPlaybackView(reason: errorText)
            }
        }
        .task {
            await resolve()
        }
    }

    // MARK: - 解析

    /// 解析一次：目前只执行 `type=1`，其它类型给出里程碑说明。
    private func resolve() async {
        guard parsed == nil, errorText.isEmpty else {
            return
        }
        do {
            let job = try ParseJobResolver.resolve(parseContext())
            guard job.kind == .json else {
                errorText = milestoneReason(job)
                return
            }
            parsed = try await JSONParser(transport: model.transportForConfiguration()).parse(job)
        } catch let error as ParseJobError {
            // 构造阶段已经有可读原因（缺名解析器 / JAR 不可用 / 没有可解析地址）。
            errorText = error.reason
        } catch {
            errorText = userFacingMessage(error)
        }
    }

    /// 与 ``ParseJobResolver`` 对齐的上下文：结果级 `playUrl` 优先、站点级回退；`useParse` 取详情的 `parse/jx`。
    private func parseContext() -> ParseContext {
        let config = model.state.loadedSource?.config
        return ParseContext(
            resultPlayURL: detail.playUrl,
            sitePlayURL: site.playUrl,
            webURL: episode.url,
            flag: lineName,
            siteClick: site.click,
            resultClick: detail.click,
            headers: HTTPHeaderMerger.merge([site.header, detail.header]),
            parsers: config?.parses ?? [],
            defaultParserName: config?.parse ?? "",
            useParse: detail.requiresParsing,
            timeout: TimeInterval(site.timeout)
        )
    }

    /// 尚未实现的解析类型的说明（必须写清「是什么 + 哪个里程碑」）。
    private func milestoneReason(_ job: ParseJob) -> String {
        guard let kind = job.kind else {
            return "无法判断该集的解析类型（type=\(job.parser.type)），见 `docs/协议兼容矩阵.md`。"
        }
        switch kind {
        case .web:
            return "该集需要 Web 解析（type=0）：打开解析页嗅探真实地址，依赖 M6 的本地代理与平台 WebView，属 M5c。"
        case .aggregate:
            return "该集需要聚合解析（type=4）：并发尝试多个解析器、谁先成功算谁，属 M5c。"
        case .jarJson, .jarMix:
            return "该集需要 JAR 解析（type=\(job.parser.type)）：Apple 平台没有 JVM，不支持。"
        case .json:
            // 调用方 `resolve()` 已先处理 type=1，这里保持 switch 穷尽。
            return "该集需要 JSON 解析（type=1）。"
        }
    }

    // MARK: - 播放

    /// 播放资源：站点 header → 详情 header → 解析器给的 header，后者覆盖前者。
    ///
    /// 最后交给 ``AppModel/proxiedMediaResource(_:)``：需要 header 时改走本机 `/proxy`（M6），
    /// 让 header 覆盖到子清单/分片/密钥请求上。
    private func resource(from parsed: ParsedPlayback) -> MediaResource {
        model.proxiedMediaResource(MediaResource(
            url: parsed.url,
            headers: HTTPHeaderMerger.merge([site.header, detail.header, parsed.headers]),
            startPosition: 0,
            format: detail.format,
            title: [vodName, episode.displayName].filter { !$0.isEmpty }.joined(separator: " "),
            artwork: detail.artwork
        ))
    }

    /// 进度上下文：与 ``VodDetailView`` 的直链播放保持一致（片名/封面/站源/线路/集名）。
    private var progressContext: PlaybackProgressContext? {
        progressKey.map {
            PlaybackProgressContext(
                key: $0,
                episodeIndex: episodeIndex,
                metadata: PlaybackEntryMetadata(
                    vodName: vodName,
                    picture: detail.artwork,
                    siteName: site.name.isEmpty ? site.key : site.name,
                    lineName: lineName,
                    episodeName: episode.displayName
                )
            )
        }
    }
}
