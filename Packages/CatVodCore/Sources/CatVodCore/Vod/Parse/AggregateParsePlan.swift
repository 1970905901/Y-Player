import Foundation

/// `type=4` 聚合解析的**计划**：逐条对齐上游 `ParseJob.superParse`（webhtv `player/ParseJob.java`）。
///
/// 上游的做法是两组并跑：
/// - `VodConfig.getParses(1, flag)`：`type=1` 成员各自发一次请求（并发，谁先给出合法地址算谁）；
/// - `VodConfig.getParses(0, flag)`：`type=0` 成员**合并成一次** Web 嗅探 ——
///   地址用 `;` 连起来交给解析页，页面里为每个地址开一个 iframe。
///
/// 本类型只负责「怎么分组、拼什么地址、开几次」；执行见 ``AggregateParser``（JSON 侧）
/// 与 `CatVodUI` 的 Web 嗅探视图（Web 侧），两侧各自上报、先成功者胜（对齐上游的 `done` 标志）。
public struct AggregateParsePlan: Sendable, Hashable {
    /// 线路名（协议里的 `flag`）。
    public var flag: String
    /// `type=1` 且适用该线路的解析器（保持配置顺序）。
    public var jsonParsers: [ParserRule]
    /// `type=0` 且适用该线路的解析器（保持配置顺序）。
    public var webParsers: [ParserRule]

    /// 按线路名筛出两类成员。
    public init(parsers: [ParserRule], flag: String) {
        self.flag = flag
        jsonParsers = parsers.filter { $0.kind == .json && $0.ext.accepts(flag: flag) }
        webParsers = parsers.filter { $0.kind == .web && $0.ext.accepts(flag: flag) }
    }

    /// 一个成员都没有（配置里没有适用该线路的 `type=0`/`type=1` 解析器）。
    public var isEmpty: Bool {
        jsonParsers.isEmpty && webParsers.isEmpty
    }

    /// 上游 `superParse` 里的 `count`：`json.size() + (webs.isEmpty() ? 0 : 1)`。
    public var taskCount: Int {
        jsonParsers.count + (webParsers.isEmpty ? 0 : 1)
    }

    /// 是否需要开 Web 嗅探（上游：`if (!webs.isEmpty()) startWeb(webs, webUrl)`）。
    public var opensWebSniffer: Bool {
        !webParsers.isEmpty
    }

    /// 解析页 `jxs` 参数：`type=0` 解析器地址用 `;` 连接（上游 `sb.append(item.getUrl()).append(";")`）。
    ///
    /// 与上游的差别：上游把它塞进 `/parse?jxs=…&url=…` 这个**本机 HTTP 地址**，所以要 `Util.substring` 截断；
    /// Apple 侧直接把 HTML 交给 WebView（见 ``parsePageHTML(webURL:)``），没有 URL 长度限制，故**不截断**。
    public var webSniffQuery: String {
        webParsers.map(\.url).joined(separator: ";")
    }

    /// 聚合解析页的 HTML（语义见 ``ParsePageHTML``）。
    public func parsePageHTML(webURL: String) -> String {
        ParsePageHTML.page(webParserURLs: webSniffQuery, webURL: webURL)
    }

    /// 把 `type=1` 成员翻成可执行的 ``ParseJob``（顺序与配置一致；`origin` 标成 ``ParseJob/Origin/aggregateMember``）。
    public func jsonJobs(
        webURL: String,
        headers: [String: String] = [:],
        click: String = "",
        timeout: TimeInterval = ParseJobResolver.defaultTimeout
    ) -> [ParseJob] {
        jsonParsers.map {
            ParseJob(
                parser: $0,
                webURL: webURL,
                flag: flag,
                headers: headers,
                click: click,
                timeout: timeout,
                origin: .aggregateMember
            )
        }
    }
}
