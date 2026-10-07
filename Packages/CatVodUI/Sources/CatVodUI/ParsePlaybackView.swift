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
/// 三条通道（对齐上游 `ParseJob.doInBackground` 的 `type` 分派）：
/// - `type=1`：JSON 解析（M5b，``JSONParser``）；
/// - `type=0`：Web 嗅探（M5c 第二阶段，``WebSniffSession``）；
/// - `type=4`：聚合 —— JSON 侧并发竞速（``AggregateParser``）与 Web 侧**并行**，谁先成功算谁。
///
/// 失败绝不静默：两条通道都失败时，把各自的原因合并后展示（见 ``reportFailureIfDone()``）。
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
    /// 正在跑的 Web 嗅探会话（非 nil 时页面里会渲染出它的 WebView）。
    @State private var webSession: WebSniffSession?
    /// JSON 通道是否还在跑（用于判断「是不是两条通道都结束了」）。
    @State private var jsonPending = false
    /// Web 通道是否还在跑。
    @State private var webPending = false
    @State private var jsonFailure = ""
    @State private var webFailure = ""

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
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView(statusText)
                    if let webSession {
                        WebSniffWebView(session: webSession)
                    }
                }
                .navigationTitle(episode.displayName)
            } else {
                UnsupportedPlaybackView(reason: errorText)
            }
        }
        .task {
            await resolve()
        }
    }

    /// 解析中的提示文案：走 Web 嗅探时要说清「在等页面」而不是笼统的「正在解析」。
    private var statusText: String {
        webSession == nil ? "正在解析播放地址…" : "正在用解析页嗅探真实地址…"
    }

    // MARK: - 解析

    /// 解析一次：按 `type` 分派到 JSON / Web 嗅探 / 聚合三条通道。
    private func resolve() async {
        guard parsed == nil, errorText.isEmpty else {
            return
        }
        do {
            let job = try ParseJobResolver.resolve(parseContext())
            switch job.kind {
            case .json:
                await resolveJSON(job)
            case .web:
                startWebSniffing(request: pageRequest(url: job.parser.url + job.webURL, job: job))
            case .aggregate:
                await resolveAggregate(job)
            case .jarJson, .jarMix, .none:
                jsonFailure = unsupportedReason(job)
                reportFailureIfDone()
            }
        } catch let error as ParseJobError {
            // 构造阶段已经有可读原因（缺名解析器 / JAR 不可用 / 没有可解析地址）。
            errorText = error.reason
        } catch {
            errorText = userFacingMessage(error)
        }
    }

    /// `type=1`：单发 JSON 解析。
    private func resolveJSON(_ job: ParseJob) async {
        jsonPending = true
        defer { jsonPending = false }
        do {
            let playback = try await JSONParser(transport: model.transportForConfiguration()).parse(job)
            finish(with: playback)
        } catch {
            jsonFailure = userFacingMessage(error)
            reportFailureIfDone()
        }
    }

    /// `type=4`：JSON 侧并发竞速 + （有 `type=0` 成员时）Web 侧并行，**谁先成功算谁**（上游 `superParse`）。
    private func resolveAggregate(_ job: ParseJob) async {
        let plan = AggregateParsePlan(parsers: model.state.loadedSource?.config.parses ?? [], flag: lineName)
        if plan.opensWebSniffer {
            let html = plan.parsePageHTML(webURL: job.webURL)
            startWebSniffing(request: pageRequest(html: html, from: webSourceName(plan), job: job))
        }
        guard !plan.jsonParsers.isEmpty else {
            jsonFailure = plan.opensWebSniffer
                ? ""
                : "聚合解析（type=4）没有可尝试的解析器：配置里没有适用线路「\(lineName)」的 type=1 / type=0 解析器。"
            reportFailureIfDone()
            return
        }
        jsonPending = true
        defer { jsonPending = false }
        do {
            let playback = try await AggregateParser(transport: model.transportForConfiguration())
                .parse(
                    plan,
                    webURL: job.webURL,
                    headers: job.effectiveHeaders,
                    click: job.click,
                    timeout: job.timeout
                )
            finish(with: playback)
        } catch {
            jsonFailure = userFacingMessage(error)
            reportFailureIfDone()
        }
    }

    // MARK: - Web 嗅探（type=0 / type=4 的 Web 侧）

    /// 启动 Web 嗅探会话（单页或聚合页）。
    private func startWebSniffing(request: WebSniffSession.Request) {
        let session = WebSniffSession()
        // 注意 `self.`：这是逃逸闭包，结构体里必须显式写明捕获语义。
        session.onSuccess = { playback in
            self.finish(with: playback)
        }
        session.onFailure = { reason in
            self.webFailure = reason
            self.webPending = false
            self.reportFailureIfDone()
        }
        webPending = true
        webSession = session
        session.start(request)
    }

    /// `type=0` 的解析页地址：解析器地址 + 待解析地址（上游 `item.getUrl() + webUrl`）。
    ///
    /// header 用解析器自己那份（``ParseJob/effectiveHeaders``：解析器 `ext.header` 为空时才是结果 header，
    /// 与上游 `parse.setHeader(result.getHeader())` 同义）。
    private func pageRequest(url: String, job: ParseJob) -> WebSniffSession.Request {
        var request = WebSniffSession.Request()
        request.url = url
        request.headers = job.effectiveHeaders
        request.click = job.click
        request.timeout = job.timeout
        request.rules = sniffRules()
        request.detectsPlayerPages = true
        request.from = job.parser.name
        return request
    }

    /// `type=4` 聚合页：把所有 `type=0` 解析器合成一页（上游 `startWeb(webs, webUrl)`）。
    ///
    /// 上游这条路传的是**空 header、空 click**（`startWeb(new HashMap<>(), 解析页地址)`），
    /// detect 仍为 true（解析页地址里不含 `player/?url=`），这里一一照搬。
    private func pageRequest(html: String, from: String, job: ParseJob) -> WebSniffSession.Request {
        var request = WebSniffSession.Request()
        request.html = html
        request.timeout = job.timeout
        request.rules = sniffRules()
        request.detectsPlayerPages = true
        request.from = from
        return request
    }

    /// 聚合页的来源说明（列出参与嗅探的解析器名，便于用户对着源核对）。
    private func webSourceName(_ plan: AggregateParsePlan) -> String {
        let names = plan.webParsers.map { $0.name.isEmpty ? "type=0" : $0.name }
        return names.isEmpty ? "聚合解析" : "聚合解析：" + names.joined(separator: "、")
    }

    /// 嗅探规则与广告表：与站点走同一份配置（判定在 ``SniffRules`` 里，平台层不重复实现）。
    private func sniffRules() -> SniffRules {
        let config = model.state.loadedSource?.config
        return SniffRules(rules: config?.rules ?? [], ads: config?.ads ?? [])
    }

    // MARK: - 收口

    /// 两条通道里任意一条成功即进播放页（先到先得，与上游 `done.compareAndSet` 同义）。
    private func finish(with playback: ParsedPlayback) {
        guard parsed == nil else {
            return
        }
        parsed = playback
        webSession?.stop()
        webPending = false
    }

    /// 两条通道都结束且都没成功时，把各通道的原因合并展示（不许静默失败）。
    private func reportFailureIfDone() {
        guard parsed == nil, !jsonPending, !webPending else {
            return
        }
        let reasons = [jsonFailure, webFailure].filter { !$0.isEmpty }
        errorText = reasons.isEmpty ? "解析失败：没有可用的解析通道。" : reasons.joined(separator: "；")
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

    /// 不可用的解析类型说明（必须写清「是什么 + 为什么」）。
    ///
    /// 说明：`type=0` / `type=4` 已在 M5c 第二阶段接通（见 ``startWebSniffing(request:)``），
    /// 这两个分支只为 switch 穷尽保留 —— 真走到这里说明分派逻辑被改坏了。
    private func unsupportedReason(_ job: ParseJob) -> String {
        guard let kind = job.kind else {
            return "无法判断该集的解析类型（type=\(job.parser.type)），见 `docs/协议兼容矩阵.md`。"
        }
        switch kind {
        case .web:
            return "内部错误：type=0 应当走 Web 嗅探通道（见 docs/任务记录/M05c-Web嗅探与聚合.md）。"
        case .aggregate:
            return "内部错误：type=4 应当走聚合通道（见 docs/任务记录/M05c-Web嗅探与聚合.md）。"
        case .jarJson, .jarMix:
            return "该集需要 JAR 解析（type=\(job.parser.type)）：Apple 平台没有 JVM，不支持。"
        case .json:
            return "内部错误：type=1 应当走 JSON 解析通道。"
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
