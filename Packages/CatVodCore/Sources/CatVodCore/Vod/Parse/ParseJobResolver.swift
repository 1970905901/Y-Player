import Foundation

/// 构造解析任务所需的上下文。
///
/// 参数收进一个值类型，避免 9 个参数的长签名；全部带默认值，调用方只填需要的字段。
public struct ParseContext: Sendable, Hashable {
    /// 结果级 `playUrl`（`SpiderResult.playUrl`）。
    public var resultPlayURL: String
    /// 站点级 `playUrl`（结果级没有前缀时回退）。
    public var sitePlayURL: String
    /// 待解析地址（`SpiderResult.url` 的首选地址，上游叫 `webUrl`）。
    public var webURL: String
    /// 线路名（协议里的 `flag`）。
    public var flag: String
    /// 站点级点击脚本（优先）：``Site/click``。
    public var siteClick: String
    /// 结果级点击脚本（兜底）：``SpiderResult/click``。
    public var resultClick: String
    /// 结果 header（解析器自身 `ext.header` 为空时生效）。
    public var headers: [String: String]
    /// 配置里的解析器清单（`SourceConfig.parses`）。
    public var parsers: [ParserRule]
    /// 配置里的默认解析器名（`SourceConfig.parse`）。
    public var defaultParserName: String
    /// 结果是否需要解析（`parse = 1` 或 `jx = 1`）。
    ///
    /// 与上游 `ParseJob.start(result, useParse)` 的 `useParse` 同义：为 `true` 时**先**取配置里的默认解析器。
    public var useParse: Bool
    /// 站点播放超时（秒）；`nil` 用 ``ParseJobResolver/defaultTimeout``。
    public var timeout: TimeInterval?

    public init(
        resultPlayURL: String = "",
        sitePlayURL: String = "",
        webURL: String = "",
        flag: String = "",
        siteClick: String = "",
        resultClick: String = "",
        headers: [String: String] = [:],
        parsers: [ParserRule] = [],
        defaultParserName: String = "",
        useParse: Bool = false,
        timeout: TimeInterval? = nil
    ) {
        self.resultPlayURL = resultPlayURL
        self.sitePlayURL = sitePlayURL
        self.webURL = webURL
        self.flag = flag
        self.siteClick = siteClick
        self.resultClick = resultClick
        self.headers = headers
        self.parsers = parsers
        self.defaultParserName = defaultParserName
        self.useParse = useParse
        self.timeout = timeout
    }
}

/// 解析任务构造失败的原因（**必须可读**，不许静默失败）。
public enum ParseJobError: Error, Sendable, Hashable {
    /// 既没有前缀、也没有默认解析器，且结果级 `playUrl` 为空。
    case noParserAvailable
    /// `parse:{name}` 指名的解析器不在配置里。
    ///
    /// 刻意与上游不同：上游这时会退化成「把 `parse:名字` 当成 Web 解析页地址」，
    /// 只会得到一个莫名其妙的失败；这里直接给出「配置里没有这个名字」。
    case parserNotFound(name: String)
    /// 解析器在当前平台不可用（`type=2/3` 需要 JVM、未知 `type` 无法执行）。
    case parserUnavailable(reason: String)
    /// 没有可解析的地址（`SpiderResult.url` 为空）。
    case emptyWebURL

    /// 面向用户的中文说明。
    public var reason: String {
        switch self {
        case .noParserAvailable:
            "该集需要解析，但既没有可用的解析器，结果里也没有解析页地址。"
        case let .parserNotFound(name):
            "接口里没有名为「\(name)」的解析器（`parses` 里找不到）。"
        case let .parserUnavailable(reason):
            reason
        case .emptyWebURL:
            "详情里没有可解析的播放地址。"
        }
    }
}

/// 解析任务构造器：把「结果 + 站点 + 配置」翻成一条可执行的 ``ParseJob``。
///
/// 顺序逐条对齐上游 `ParseJob.setParse`（webhtv `player/ParseJob.java`）：
/// 1. 结果需要解析（`useParse`）→ 先取配置里的默认解析器（`config.parse`）；
/// 2. 结果级 `playUrl` 的 `json:` / `parse:` 前缀**无条件覆盖**；
/// 3. 结果级没有前缀时回退站点级 `playUrl`（本仓库既有约定；站点级不覆盖默认解析器）；
/// 4. 仍然什么都没有 → 把结果级 `playUrl` 当 `type=0` 的 Web 解析页；它也是空的才算失败。
public enum ParseJobResolver {
    /// 默认超时（秒）：上游 `Constant.TIMEOUT_PARSE_DEF` / `TIMEOUT_PARSE_WEB` 都是 15 秒。
    public static let defaultTimeout: TimeInterval = 15

    /// 构造解析任务。
    public static func resolve(_ context: ParseContext) throws -> ParseJob {
        let webURL = context.webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !webURL.isEmpty else {
            throw ParseJobError.emptyWebURL
        }
        let resultPlayURL = context.resultPlayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let sitePlayURL = context.sitePlayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        var selection: Selection?
        if context.useParse, let parser = named(context.defaultParserName, in: context.parsers) {
            selection = Selection(parser: parser, origin: .defaultParser)
        }
        if let prefixed = try select(from: PlayUrlPrefix.prefixedInstruction(resultPlayURL), parsers: context.parsers) {
            selection = prefixed
        } else if selection == nil {
            selection = try select(
                from: PlayUrlPrefix.prefixedInstruction(sitePlayURL),
                parsers: context.parsers,
                webOrigin: .sitePrefix
            )
        }
        if selection == nil, !resultPlayURL.isEmpty {
            // 上游第 4 步：没有解析器可选时，把结果级 playUrl 本身当 Web 解析页。
            selection = Selection(
                parser: ParserRule(name: "", type: ParserKind.web.rawValue, url: resultPlayURL),
                origin: .webPage
            )
        }
        if selection == nil, !sitePlayURL.isEmpty {
            // 结果级连地址都没有：站点级 playUrl 作为最后的 Web 解析页。
            selection = Selection(
                parser: ParserRule(name: "", type: ParserKind.web.rawValue, url: sitePlayURL),
                origin: .sitePrefix
            )
        }
        guard let selection else {
            throw ParseJobError.noParserAvailable
        }
        guard selection.parser.availability.isAvailable else {
            throw ParseJobError.parserUnavailable(reason: unavailableReason(selection.parser))
        }
        return ParseJob(
            parser: selection.parser,
            webURL: webURL,
            flag: context.flag,
            headers: context.headers,
            click: resolvedClick(siteClick: context.siteClick, resultClick: context.resultClick),
            timeout: context.timeout ?? defaultTimeout,
            origin: selection.origin
        )
    }

    /// 解析成功后**结果仍然需要解析**（`parse = 1` / `jx = 1`）时的后续任务。
    ///
    /// 与上游 `checkResult(Result)` 同义：把「刚解析出来的地址」交给默认解析链再排一次
    /// （配置里有默认解析器就用它；没有就是 `type=0` 的 Web 嗅探页，实现见 M5c）。
    public static func followUp(
        parsedURL: String,
        headers: [String: String],
        context: ParseContext
    ) throws -> ParseJob {
        var next = context
        next.headers = headers
        next.webURL = parsedURL
        // 之前那一步的前缀已经用掉了：这一步只看配置里的默认解析器 / 裸地址兜底。
        next.resultPlayURL = parsedURL
        next.sitePlayURL = ""
        next.useParse = true
        return try resolve(next)
    }

    // MARK: - 内部

    /// 命中的选择结果。
    private struct Selection {
        var parser: ParserRule
        var origin: ParseJob.Origin
    }

    /// 把「只看前缀」的指令翻成解析器；没有前缀（`nil`）时返回 `nil`，裸地址由调用方兜底。
    ///
    /// 名字刻意不叫 `selection`：`resolve` 里有个同名局部变量，重名会让调用被解析成「调用变量」。
    private static func select(
        from instruction: PlaybackInstruction?,
        parsers: [ParserRule],
        webOrigin: ParseJob.Origin = .webPage
    ) throws -> Selection? {
        // 先把可选值解开再 switch：避免在可选枚举上做模式匹配（SwiftLint 有对应风格规则）。
        guard let instruction else {
            return nil
        }
        switch instruction {
        case let .json(url):
            return Selection(
                parser: ParserRule(name: url, type: ParserKind.json.rawValue, url: url),
                origin: .jsonPrefix
            )
        case let .parser(name):
            guard let parser = named(name, in: parsers) else {
                throw ParseJobError.parserNotFound(name: name)
            }
            return Selection(parser: parser, origin: .namedParser)
        case let .web(url):
            return Selection(
                parser: ParserRule(name: "", type: ParserKind.web.rawValue, url: url),
                origin: webOrigin
            )
        case .none:
            return nil
        }
    }

    /// 按名字找解析器（上游 `VodConfig.getParse(name)`：精确匹配 `name`）。
    private static func named(_ name: String, in parsers: [ParserRule]) -> ParserRule? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return nil
        }
        return parsers.first { $0.name == target }
    }

    /// 点击脚本：站点级优先，其次结果级（上游 `getClick`）。
    ///
    /// 名字带 `resolved` 前缀：避免与 `ParseJob.click` 这个属性在阅读与调用上混淆。
    private static func resolvedClick(siteClick: String, resultClick: String) -> String {
        siteClick.isEmpty ? resultClick : siteClick
    }

    /// 不可用原因：带上解析器名字，方便用户回配置里核对。
    private static func unavailableReason(_ parser: ParserRule) -> String {
        let reason = parser.availability.reason ?? "该解析器在当前平台不可用"
        let name = parser.name.isEmpty ? "type=\(parser.type)" : parser.name
        return "解析器「\(name)」不可用：\(reason)"
    }
}
