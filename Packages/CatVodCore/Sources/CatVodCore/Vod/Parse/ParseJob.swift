import Foundation

/// 解析任务：**选好一个解析器 + 待解析地址 + 该任务的全部执行参数**。
///
/// 为什么要这个类型：M2 只做到「路由」（``PlayUrlPrefix`` 认得 `json:`/`parse:`），M5 要真的执行，
/// 就必须先把「用哪个解析器、解析哪个地址、带什么 header/click、超时多少、失败算什么原因」收敛成一个
/// **可单测的值类型** —— 执行器只吃 `ParseJob`，不自己判断协议。
///
/// 逐条对齐上游 `ParseJob`（webhtv `app/src/main/java/com/fongmi/android/tv/player/ParseJob.java`）：
/// - `setParse()`：`json:{url}` → 临时 `type=1`；`parse:{name}` → 配置里的具名解析器；
///   都拿不到时 → `type=0`，把 `playUrl` 本身当解析页地址；
/// - `parse.setHeader(result.header)` **只在解析器自身 `ext.header` 为空时**生效；
/// - `click` 站点级优先、结果级兜底（`getClick`）；
/// - `TIMEOUT_PARSE_DEF` / `TIMEOUT_PARSE_WEB` 都是 15 秒。
public struct ParseJob: Sendable, Hashable {
    /// 这个任务是怎么来的（诊断与文案用，不参与执行）。
    public enum Origin: Sendable, Hashable {
        /// 结果级 `playUrl` 以 `json:` 开头（临时 `type=1` 解析器）。
        case jsonPrefix
        /// 结果级 `playUrl` 以 `parse:{name}` 开头（配置里的具名解析器）。
        case namedParser
        /// 结果级 `playUrl` 是裸地址（`type=0` Web 解析页）。
        case webPage
        /// 结果级为空，回退到站点级 `playUrl` 前缀。
        case sitePrefix
        /// 结果需要解析时，配置里的默认解析器（`config.parse`）。
        case defaultParser

        /// 界面/日志用的一句话说明。
        public var summary: String {
            switch self {
            case .jsonPrefix: "结果级 playUrl 的 json: 前缀（临时 JSON 解析器）"
            case .namedParser: "结果级 playUrl 的 parse: 前缀（配置里的具名解析器）"
            case .webPage: "裸地址（Web 解析页）"
            case .sitePrefix: "站点级 playUrl 前缀（结果级为空时回退）"
            case .defaultParser: "配置里的默认解析器"
            }
        }
    }

    /// 选中的解析器（类型、地址、`ext.header`/`ext.flag`、`click` 来源）。
    public var parser: ParserRule
    /// 待解析地址（上游叫 `webUrl`）：通常是视频直链或播放页地址。
    public var webURL: String
    /// 线路名（协议里的 `flag`）：`type=3`/`type=4` 用它筛解析器。
    public var flag: String
    /// 结果 header：仅当解析器自身 `ext.header` 为空时生效。
    public var headers: [String: String]
    /// WebView 点击脚本（站点级优先，其次结果级）。
    public var click: String
    /// 超时（秒）。
    public var timeout: TimeInterval
    /// 任务来源。
    public var origin: Origin

    public init(
        parser: ParserRule,
        webURL: String,
        flag: String = "",
        headers: [String: String] = [:],
        click: String = "",
        timeout: TimeInterval = ParseJobResolver.defaultTimeout,
        origin: Origin = .webPage
    ) {
        self.parser = parser
        self.webURL = webURL
        self.flag = flag
        self.headers = headers
        self.click = click
        self.timeout = timeout
        self.origin = origin
    }

    /// 解析类型（解析器的 `type`；未知类型为 `nil`）。
    public var kind: ParserKind? {
        parser.kind
    }

    /// 当前平台能不能执行这个任务（JAR 两类明确不可用）。
    public var availability: SiteAvailability {
        parser.availability
    }

    /// 执行时实际要用的 header：解析器自己的优先，为空才用结果 header。
    public var effectiveHeaders: [String: String] {
        parser.ext.header.isEmpty ? headers : parser.ext.header
    }

    /// 该解析器是否适用于当前线路（`ext.flag` 为空表示适用全部）。
    public var acceptsFlag: Bool {
        parser.ext.accepts(flag: flag)
    }
}
