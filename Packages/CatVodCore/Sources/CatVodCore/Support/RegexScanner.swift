import Foundation

/// 正则小工具：仓库里多处需要「Java 风格的正则查找/替换」，语义必须一致。
///
/// 为什么单独成类型：`Sniffer`（嗅探规则）、`Catchup`（时移模板）、`HostRuleMatcher`（host 规则）
/// 都要用同一套语义 —— **查找是 `find()`（能找到就行），不是整串匹配**；正则非法时统一退化为「不命中」，
/// 而不是抛异常或崩溃（上游 Java 会抛 `PatternSyntaxException` 被上层吞掉，行为等价但更难排查）。
public enum RegexScanner {
    /// 正则**找得到**（Java `Matcher.find()`）。
    public static func finds(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    /// 正则查找并返回第一处匹配（Java `m.group(0)`）；正则非法或文本为空时返回 `nil`。
    public static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard !pattern.isEmpty, !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let matched = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matched])
    }

    /// 正则替换（Java `String.replaceAll` 也是**正则**替换）；正则非法时退化为原样返回。
    ///
    /// 注意 `template` 里的 `$1` 会被当作捕获组引用（与 Java/`NSRegularExpression` 一致）。
    public static func replacingMatches(_ pattern: String, with template: String, in text: String) -> String {
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 捕获组列表（Java `m.group(i)`）；`0` 是整段匹配。不匹配时返回空数组。
    public static func groups(_ pattern: String, in text: String) -> [String] {
        guard !pattern.isEmpty, !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return []
        }
        return (0 ..< match.numberOfRanges).map { index in
            guard let groupRange = Range(match.range(at: index), in: text) else {
                return ""
            }
            return String(text[groupRange])
        }
    }
}
