import Foundation

/// 直播时移（catchup）配置。
///
/// 逐条对齐上游 `bean/Catchup.java`：
/// - `isEmpty` = **`source` 为空**（不是「全字段为空」）—— `decide` 靠它判断用哪一级；
/// - ``decide(major:minor:)``：频道级（主）非空用频道级，否则用直播源级（次），都空则 `nil`；
/// - ``matches(url:)`` = `url.contains(regex) || 正则 find`（与 ``HostRuleMatcher`` 同一套「包含 / 正则」语义）；
/// - ``playbackURL(_:start:end:)``：把 `source` 里的 `{…}` 令牌换成时间；`default` 类型直接给出，
///   其余「追加」到直播地址后（先按 `replace` 的 `原串,新串` 做替换，已有 query 时把 `?` 改成 `&`）。
public struct LiveCatchup: Codable, Sendable, Hashable {
    /// 时移类型：`default`（源里直接给时间）或 `append`（拼到直播地址后）。
    public var type: String
    /// 可回看天数（协议字段，播放侧用）。
    public var days: String
    /// 命中判定用的正则（例如 `/PLTV/`）。
    public var regex: String
    /// 时间模板，例如 `?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}`。
    public var source: String
    /// 追加前的地址替换规则 `原串,新串`。
    public var replace: String

    public init(
        type: String = "",
        days: String = "",
        regex: String = "",
        source: String = "",
        replace: String = ""
    ) {
        self.type = type
        self.days = days
        self.regex = regex
        self.source = source
        self.replace = replace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.lenientString(.type)
        days = container.lenientString(.days)
        regex = container.lenientString(.regex)
        source = container.lenientString(.source)
        replace = container.lenientString(.replace)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case days
        case regex
        case source
        case replace
    }

    /// 上游 `Catchup.PLTV()`：内置的 PLTV 时移规则（部分源直接用它）。
    public static func pltv() -> LiveCatchup {
        LiveCatchup(
            type: "append",
            days: "7",
            regex: "/PLTV/",
            source: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",
            replace: "/PLTV/,/TVOD/"
        )
    }

    /// 上游 `Catchup.isEmpty()`：`source` 为空即视为「没配时移」。
    public var isEmpty: Bool {
        source.isEmpty
    }

    /// 上游 `Catchup.decide(major, minor)`。
    public static func decide(major: LiveCatchup?, minor: LiveCatchup?) -> LiveCatchup? {
        if let major, !major.isEmpty {
            return major
        }
        if let minor, !minor.isEmpty {
            return minor
        }
        return nil
    }

    /// 上游 `Catchup.match(url)`。
    public func matches(url: String) -> Bool {
        guard !regex.isEmpty else {
            return false
        }
        return url.contains(regex) || RegexScanner.finds(regex, in: url)
    }

    /// `type == "default"`。
    public var isDefaultType: Bool {
        type == "default"
    }

    // MARK: - 时移地址

    /// 生成时移地址（上游 `Catchup.format(url, data)`）。
    ///
    /// - Parameters:
    ///   - url: 直播地址。
    ///   - start: 节目开始时间（`(b…)` 与 `utc:` 令牌用它）。
    ///   - end: 节目结束时间（`(e…)` 与 `utcend:` 令牌用它）。
    public func playbackURL(_ url: String, start: Date, end: Date) -> String {
        let query = replacingTokens(in: source, start: start, end: end)
        guard !isDefaultType else {
            return query
        }
        return appending(to: url, query: query)
    }

    /// 把 `{…}` 令牌换成时间（上游 `TOKEN_PATTERN` + `format(group, start, end)`）。
    func replacingTokens(in template: String, start: Date, end: Date) -> String {
        let pattern = "\\$?\\{[^}]*\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return template
        }
        var result = template
        let range = NSRange(template.startIndex ..< template.endIndex, in: template)
        // 从后往前替换：前一处替换不影响后一处的区间。
        for match in regex.matches(in: template, range: range).reversed() {
            guard let tokenRange = Range(match.range, in: result) else {
                continue
            }
            let token = String(result[tokenRange])
            result.replaceSubrange(tokenRange, with: tokenValue(token, start: start, end: end))
        }
        return result
    }

    /// 单个令牌 → 时间文本（上游 `format(String group, long start, long end)`）。
    func tokenValue(_ token: String, start: Date, end: Date) -> String {
        guard let open = token.firstIndex(of: "{"), let close = token.lastIndex(of: "}"), open < close else {
            return ""
        }
        let tag = String(token[token.index(after: open) ..< close])
        if tag.hasPrefix("(b"), let paren = tag.firstIndex(of: ")") {
            return Self.formatTime(start, pattern: String(tag[tag.index(after: paren)...]))
        }
        if tag.hasPrefix("(e"), let paren = tag.firstIndex(of: ")") {
            return Self.formatTime(end, pattern: String(tag[tag.index(after: paren)...]))
        }
        if tag.hasPrefix("utcend:") {
            return String(Int64(end.timeIntervalSince1970))
        }
        if tag.hasPrefix("utc:") {
            return String(Int64(start.timeIntervalSince1970))
        }
        return ""
    }

    /// 时间格式化（上游 `formatTime`）：`timestamp` 给秒级时间戳，其余按日期模板。
    ///
    /// 说明：`yyyyMMddHHmmss` 这类常用模板在 Java 与 `DateFormatter` 下一致；
    /// 依赖 Java 特有含义的写法（如 `YYYY` 表示周、`mm` 在 Java 里是分钟）不保证等价，已在文档里写明。
    static func formatTime(_ date: Date, pattern: String) -> String {
        if pattern == "timestamp" {
            return String(Int64(date.timeIntervalSince1970))
        }
        guard !pattern.isEmpty else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// 「追加」型时移（上游 `append`）：先按 `replace` 替换地址，再把时间串接上（已有 query 时把 `?` 换成 `&`）。
    func appending(to url: String, query: String) -> String {
        var base = url
        let splits = replace.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        if splits.count == 2 {
            base = RegexScanner.replacingMatches(String(splits[0]), with: String(splits[1]), in: base)
        }
        var suffix = query
        if !Self.query(of: base).isEmpty {
            suffix = suffix.replacingOccurrences(of: "?", with: "&")
        }
        return base + suffix
    }

    /// 地址里的 query（上游用 `URI.create(url).getQuery()` 判「已经有 query」）。
    static func query(of url: String) -> String {
        guard let marker = url.firstIndex(of: "?") else {
            return ""
        }
        return String(url[url.index(after: marker)...])
    }
}
