import Foundation

/// 规则解码失败的原因（元素级失败会被 `lenientArray` 跳过，所以这里只有「这条规则是坏的」一种含义）。
public enum GroupRuleDecodingError: Error, Equatable {
    /// 没有正则：上游 `normalize` 也是直接丢掉（空规则会变成「命中一切」）。
    case missingRegex
}

/// 站点名**分组规则**（上游 `app/src/main/java/com/fongmi/android/tv/bean/GroupRule.java`）。
///
/// 干什么：把一条正则套到站点名上，抠出**第 1 个捕获组**当「标签」；站点面板顶部那条分组条显示的就是这些标签
/// （`💥木偶|4K` → `4K`；`[主力][短剧]我的站` → `主力`、`短剧`）。上游链路：
/// `SiteDialog → Site.getGroups → SiteNameStore → SiteNameRules.groups → GroupRuleConfig.extract → Rule.extract`。
///
/// ⚠️ **形状修正**（M06d 同批）：本项目原来按 `{name, hosts, regex: [String]}` 建模 ——
/// 上游是 `id` / `name` / `regex`（**单条字符串**）/ `enabled` / `source` / `wrapBracket`，根本没有 `hosts`。
/// 形状错的模型不会报错，只会让配置里的 `groupRules` 解析成空规则、**静默失效**（和 `hlsRules` 那次一模一样）。
public struct GroupRule: Codable, Sendable, Hashable {
    /// 来源：内置规则。
    public static let sourceBuiltin = "builtin"
    /// 来源：用户自己加的。
    public static let sourceUser = "user"
    /// 来源：接口配置给的（缺省值）。
    public static let sourceInterface = "interface"
    /// 来源：AI 生成（要过安全子集校验，见 ``isSafeAIRegExp(_:)``）。
    public static let sourceAI = "ai"

    /// AI 规则的匹配文本长度上限：超了直接不匹配（别拿几 KB 的名字去跑正则）。
    public static let maxAIMatchTextLength = 256
    /// AI 规则允许的正则嵌套深度上限。
    public static let maxAINestingDepth = 8
    /// AI 规则同一层里允许的量词个数。
    public static let maxAIQuantifiersPerDepth = 2

    public var id: String
    public var name: String
    /// 抽标签用的正则（**单条字符串**，不是数组）。
    public var regex: String
    public var enabled: Bool
    /// 来源：``sourceBuiltin`` / ``sourceUser`` / ``sourceInterface`` / ``sourceAI``。
    public var source: String
    /// 抽出来的标签要不要套成 `[标签]`（让不同来源的标签长得一致）。
    public var wrapBracket: Bool

    /// 解码：**没有正则的规则直接丢掉**（对齐上游 `normalize`：脏规则不该变成「命中一切」的空规则）。
    ///
    /// 元素级失败由 `lenientArray` 吞掉（`LenientElement` + `try?`），所以这里抛错就等于「跳过这一条」。
    /// 缺 `source` / `enabled` 时按上游补默认值；缺 `id` 时**按正则算稳定 id**（上游随机生成 UUID，
    /// 那样每次加载都不一样、按 id 存的开关会失配 —— 这里刻意改了一点，理由写在这）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        regex = container.lenientString(.regex).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !regex.isEmpty else {
            throw GroupRuleDecodingError.missingRegex
        }
        let rawID = container.lenientString(.id).trimmingCharacters(in: .whitespaces)
        id = rawID.isEmpty ? Self.automaticID(regex: regex, name: name) : rawID
        source = container.lenientString(.source, default: Self.sourceInterface)
        enabled = container.lenientBool(.enabled, default: true)
        wrapBracket = container.lenientBool(.wrapBracket)
    }

    /// 缺 id 时的稳定 id：`auto-` + 正则与名字的摘要。
    public static func automaticID(regex: String, name: String) -> String {
        "auto-" + String(MD5.hexDigest(of: name + "|" + regex).prefix(16))
    }

    /// 直接构造（内置规则与测试用）。
    public init(
        id: String,
        name: String,
        regex: String,
        enabled: Bool = true,
        source: String,
        wrapBracket: Bool = false
    ) {
        self.id = id
        self.name = name
        self.regex = regex
        self.enabled = enabled
        self.source = source
        self.wrapBracket = wrapBracket
    }

    /// 构一条内置规则（对齐上游 `GroupRule.builtin`：来源内置、默认启用）。
    public static func builtin(id: String, name: String, regex: String, wrapBracket: Bool = false) -> GroupRule {
        GroupRule(id: id, name: name, regex: regex, source: sourceBuiltin, wrapBracket: wrapBracket)
    }

    /// 构一条用户规则（对齐上游 `createUser`：来源用户、默认启用、id 自动算）。
    public static func user(name: String, regex: String, wrapBracket: Bool = false) -> GroupRule {
        GroupRule(id: automaticID(regex: regex, name: name),
                  name: name,
                  regex: regex,
                  source: sourceUser,
                  wrapBracket: wrapBracket)
    }

    /// 构一条 AI 规则（对齐上游 `createAi`：来源 AI，因此要过安全子集校验）。
    public static func ai(name: String, regex: String, wrapBracket: Bool = false) -> GroupRule {
        GroupRule(id: automaticID(regex: regex, name: name),
                  name: name,
                  regex: regex,
                  source: sourceAI,
                  wrapBracket: wrapBracket)
    }

    /// 这条规则能不能用（正则编得出来；AI 来源还要过安全子集）。
    public var isValid: Bool {
        compiledPattern() != nil
    }

    /// 是不是 AI 生成的规则。
    public var isAI: Bool {
        source == Self.sourceAI
    }

    /// 从文本里抽标签（对齐上游 `extract`）：正则**全局查找**、取第 1 个捕获组（没有就取整段匹配）、
    /// 去掉首尾空白、``wrapBracket`` 时套成 `[标签]`、结果去重且保持出现顺序。
    public func extract(_ text: String) -> [String] {
        guard !text.isEmpty, !regex.isEmpty else { return [] }
        if isAI, text.count > Self.maxAIMatchTextLength { return [] }
        guard let pattern = compiledPattern() else { return [] }

        var groups: [String] = []
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        pattern.enumerateMatches(in: text, options: [], range: range) { result, _, _ in
            guard let result else { return }
            var value = captureValue(result, in: text)
            guard !value.isEmpty else { return }
            if wrapBracket, !(value.hasPrefix("[") && value.hasSuffix("]")) {
                value = "[" + value + "]"
            }
            if !groups.contains(value) {
                groups.append(value)
            }
        }
        return groups
    }

    /// 捕获组 1（参与了匹配才用，否则退回整段匹配），去掉首尾空白。
    private func captureValue(_ result: NSTextCheckingResult, in text: String) -> String {
        if result.numberOfRanges > 1, let range = Range(result.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let range = Range(result.range, in: text) else { return "" }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 编译正则（AI 来源先过安全子集；编不出来返回 nil）。
    private func compiledPattern() -> NSRegularExpression? {
        if isAI, !Self.isSafeAIRegExp(regex) {
            return nil
        }
        return try? NSRegularExpression(pattern: regex)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case regex
        case enabled
        case source
        case wrapBracket
    }
}
