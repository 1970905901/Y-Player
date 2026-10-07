import Foundation

/// host 匹配规则。
///
/// 对照上游 `com.github.catvod.utils.Util.containOrMatch`：
/// `text.contains(regex) || text.matches(regex)` —— 即「包含」或「整串正则匹配」；
/// 代理规则在此基础上单独支持 `*`（`OkProxySelector.matches`：
/// `"*".equals(rule) || Util.containOrMatch(host, rule)`）。
/// `proxy[].hosts`、`headers[].host`、`rules[].hosts` 三处共用这一套语义，不能各自实现。
public enum HostRuleMatcher {
    /// 规则里是否含通配符（上游 `bean.Proxy.init`：`hosts.any { it.contains("*") }`）。
    public static func isWildcard(_ rule: String) -> Bool {
        rule.contains("*")
    }

    /// 单条规则是否命中文本。
    ///
    /// - Parameters:
    ///   - text: 被匹配的文本。宿主要匹配 host 时传 host；
    ///     嗅探规则要把「URL 的 host + `url` 查询参数里的 host」拼起来再传（见 `Sniffer.getRule`）。
    ///   - rule: 规则原文，支持 `*`、子串、Java 风格整串正则。
    public static func matches(text: String, rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.isEmpty else {
            return false
        }
        if trimmed == "*" {
            return true
        }
        return text.contains(trimmed) || fullMatch(text, trimmed)
    }

    /// 多规则里第一条命中的规则；用于日志里说明「是哪条规则生效」。
    public static func firstMatch(text: String, rules: [String]) -> String? {
        rules.first { matches(text: text, rule: $0) }
    }

    /// 上游 `String.matches(regex)`：必须**整串**匹配。
    ///
    /// `NSRegularExpression` 只提供「查找」，因此这里显式比较匹配区间是否覆盖整串。
    /// 正则非法时上游 catch 后返回 false，这里同样退化为「不命中」。
    private static func fullMatch(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let full = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: full) else {
            return false
        }
        return match.range == full
    }
}
