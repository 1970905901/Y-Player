import Foundation

/// 嗅探规则引擎：逐条对齐上游 `Sniffer`（webhtv `app/src/main/java/com/fongmi/android/tv/utils/Sniffer.java`）。
///
/// 为什么单独成类型：`type=0`（Web 嗅探）与 `type=4`（聚合）都要回答同一组问题 ——
/// 「拦到的这条地址是不是真实播放地址」「这个 host 是不是广告」「页面加载完要注入哪些脚本」。
/// 判定收进纯函数，测试就不必为了验规则去起 WebView（WebKit 载体见 `CatVodUI` 的 Web 嗅探视图）。
///
/// 平台差异（有意为之，逐条记录）：
/// - 上游用 Java `Pattern.compile`，正则**非法**时抛 `PatternSyntaxException` 被上层吞掉；
///   这里非法正则一律退化为「不命中」，且不静默 —— ``decision(forURL:)`` 会把原因说清。
/// - 上游 `Uri.getHost()` 的行为随 Android 版本略有差异；这里统一走 `URLComponents.host`。
public struct SniffRules: Sendable, Hashable {
    /// 嗅探规则清单（`SourceConfig.rules`；上游 `RuleConfig.getRules()` 会把点播与直播的规则合并）。
    public var rules: [SniffRule]
    /// 广告 host / 正则（`SourceConfig.ads`；上游 `RuleConfig.getAds()`）。
    public var ads: [String]

    /// 上游 `Sniffer.SNIFFER`：默认媒体地址正则。
    public static let mediaPatternSource = "https?://[^\\s]{12,}\\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\\?.*)?"
        + "|https?://.*?video/tos[^\\s]*|rtmp:[^\\s]+"

    /// 上游 `Sniffer.AI_PUSH`：从一段文本里抽直链。
    public static let pushPatternSource = "(https?|thunder|magnet|ed2k|video):\\S+"

    /// 上游 `CustomWebView.PLAYER`：识别「播放页里又套了一层播放页」。
    public static let playerPagePatternSource = "player.*https?://"

    /// 上游 `CustomWebView.MAX_URLS`。
    public static let maximumDetectedPages = 5

    public init(rules: [SniffRule] = [], ads: [String] = []) {
        self.rules = rules
        self.ads = ads
    }

    // MARK: - 规则命中

    /// 上游 `Sniffer.getRule(Uri)`：匹配文本 = `URL 的 host` + `url` 查询参数里的 host（逗号连接）。
    ///
    /// 上游固定拼两项（`TextUtils.join(",")`，取不到 host 时为空串）；这里只拼非空项 ——
    /// 对 ``HostRuleMatcher`` 的「包含 / 整串正则 / `*`」三种语义来说，空项只多一个逗号，结果一致。
    public static func hostMatchText(for url: String) -> String {
        [host(of: url), host(of: queryValue(named: "url", in: url))]
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    /// 命中的第一条规则；没有规则命中时返回 `nil`（上游返回 `Rule.empty()`）。
    public func rule(forURL url: String) -> SniffRule? {
        let text = Self.hostMatchText(for: url)
        guard !text.isEmpty else {
            return nil
        }
        return rules.first { rule in
            rule.hosts.contains { HostRuleMatcher.matches(text: text, rule: $0) }
        }
    }

    /// 页面加载完要注入的 JS（上游 `Sniffer.getScript(Uri)`）。
    public func scripts(forURL url: String) -> [String] {
        rule(forURL: url)?.script ?? []
    }

    // MARK: - 判定

    /// 上游 `Sniffer.isVideoFormat(String)`。
    public func isVideoFormat(_ url: String) -> Bool {
        decision(forURL: url).isMedia
    }

    /// 与 ``isVideoFormat(_:)`` 同一套判定，但把「为什么」说清楚（UI 与日志用）。
    ///
    /// 判定顺序与上游一字不改：
    /// 1. 命中规则的 `exclude`（先 `contains` 再正则）→ **不是**媒体；
    /// 2. 命中规则的 `regex`（先 `contains` 再正则）→ **是**媒体；
    /// 3. 含 `url=http` / `v=http` / `.html` → **不是**媒体；
    /// 4. 默认媒体正则 `SNIFFER` 命中 → **是**媒体。
    public func decision(forURL url: String) -> SniffDecision {
        if let matched = rule(forURL: url) {
            for pattern in matched.exclude where url.contains(pattern) {
                return .ruleExcluded(rule: matched.name, pattern: pattern)
            }
            for pattern in matched.exclude where Self.regexFinds(pattern, in: url) {
                return .ruleExcluded(rule: matched.name, pattern: pattern)
            }
            for pattern in matched.regex where url.contains(pattern) {
                return .ruleMatched(rule: matched.name, pattern: pattern)
            }
            for pattern in matched.regex where Self.regexFinds(pattern, in: url) {
                return .ruleMatched(rule: matched.name, pattern: pattern)
            }
        }
        if url.contains("url=http") || url.contains("v=http") || url.contains(".html") {
            return .notMediaFormat(reason: "含 `url=http` / `v=http` / `.html`，按协议判为不是媒体地址")
        }
        guard Self.firstMatch(pattern: Self.mediaPatternSource, in: url) != nil else {
            return .notMediaFormat(reason: "不匹配默认媒体正则（m3u8/mp4/mkv/flv/mp3/m4a/aac/mpd、video/tos、rtmp）")
        }
        return .defaultPatternMatched
    }

    // MARK: - 广告与 player 页

    /// 上游 `CustomWebView.isAd(String host)`：`ads` 里任一命中即算广告（命中后该请求被拦掉）。
    public func isAd(host: String) -> Bool {
        HostRuleMatcher.firstMatch(text: host, rules: ads) != nil
    }

    /// 上游 `CustomWebView.PLAYER`：命中说明「这个请求本身就是个播放页」，要再开一层嗅探。
    public static func isPlayerPage(_ url: String) -> Bool {
        regexFinds(playerPagePatternSource, in: url)
    }

    // MARK: - 文本抽取

    /// 上游 `Sniffer.getUrl(String)`：JSON 对象或含 `$` 时原样返回，否则抽 `AI_PUSH` 的第一个匹配。
    public static func mediaURL(inText text: String) -> String {
        if isJSONObject(text) || text.contains("$") {
            return text
        }
        return firstMatch(pattern: pushPatternSource, in: text) ?? text
    }

    /// 从一段文本里找第一条像媒体地址的 URL（默认媒体正则）。
    public static func firstMediaURL(inText text: String) -> String? {
        firstMatch(pattern: mediaPatternSource, in: text)
    }

    /// 上游 `Json.isObj(String)`：能解析成 JSON **对象**才算（数组/标量都不算）。
    static func isJSONObject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return false
        }
        return (try? JSONDecoder().decode(AnyJSONValue.self, from: Data(trimmed.utf8)))?.objectValue != nil
    }

    // MARK: - URL 拆解

    /// URL 的 host（取不到返回空串；上游 `UrlUtil.host(Uri)`）。
    static func host(of url: String) -> String {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return components.host ?? ""
    }

    /// 查询参数的值（上游 `Uri.getQueryParameter("url")`；按 URL 规则解码）。
    static func queryValue(named name: String, in url: String) -> String {
        guard let components = URLComponents(string: url) else {
            return ""
        }
        return components.queryItems?.first { $0.name == name }?.value ?? ""
    }

    /// 正则**找得到**（Java `Matcher.find()`，不是整串匹配）。
    static func regexFinds(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern: pattern, in: text) != nil
    }

    /// 正则查找并返回第一处匹配（Java `m.group(0)`）；正则非法或文本为空时返回 `nil`。
    static func firstMatch(pattern: String, in text: String) -> String? {
        guard !pattern.isEmpty, !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let matched = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matched])
    }
}

/// 嗅探判定结果：把「是不是媒体地址」和「为什么」放在同一个值里。
///
/// 为什么要这个类型：上游只返回 `boolean`，排查「为什么这个源嗅探不到」时只能靠日志猜；
/// 这里把命中的规则名与模式一起带出来，UI 与日志可以直接展示。
public enum SniffDecision: Sendable, Hashable {
    /// 命中嗅探规则的 `regex`。
    case ruleMatched(rule: String, pattern: String)
    /// 被嗅探规则的 `exclude` 排除。
    case ruleExcluded(rule: String, pattern: String)
    /// 没有规则命中，但默认媒体正则通过。
    case defaultPatternMatched
    /// 判定为「不是媒体地址」。
    case notMediaFormat(reason: String)

    /// 是否为媒体地址（等价上游 `Sniffer.isVideoFormat` 的返回值）。
    public var isMedia: Bool {
        switch self {
        case .ruleMatched, .defaultPatternMatched: true
        case .ruleExcluded, .notMediaFormat: false
        }
    }

    /// 可读原因。
    public var reason: String {
        switch self {
        case let .ruleMatched(rule, pattern):
            "命中嗅探规则「\(rule)」的 regex：\(pattern)"
        case let .ruleExcluded(rule, pattern):
            "被嗅探规则「\(rule)」排除：\(pattern)"
        case .defaultPatternMatched:
            "匹配默认媒体正则"
        case let .notMediaFormat(reason):
            reason
        }
    }
}
