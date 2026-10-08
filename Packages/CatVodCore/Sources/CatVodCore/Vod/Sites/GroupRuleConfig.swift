import Foundation

/// 分组规则的「当前生效集合」：内置规则 + 接口规则 − 被关掉的，以及最终的抽标签入口。
///
/// 对应上游 `setting/GroupRuleConfig.java`（那边叫 Config，实际是「这一堆规则的生效集合」）。
/// 上游还有两个来源**我们没做**：`GroupRuleStore.loadUser()`（用户在界面上自己加的）与
/// `AiGroupRuleStore`（AI 生成的）—— 前者等规则管理界面，后者要连 AI 服务，见 M06d 文档第六节。
public enum GroupRuleConfig {
    /// 内置规则 id：方括号标签。
    public static let builtinBracket = "builtin_bracket_tag"
    /// 内置规则 id：竖线后缀。
    public static let builtinPipe = "builtin_pipe_quality"
    /// 内置规则 id：框线分隔。
    public static let builtinBox = "builtin_box_separator"
    /// 内置规则 id：圆点后缀。
    public static let builtinBullet = "builtin_bullet_suffix"

    /// 四条内置规则（正则与顺序都照上游 `builtins()` 抄，改动请先跑 `GroupRuleTests`）。
    public static var builtins: [GroupRule] {
        [
            .builtin(id: builtinBracket, name: "方括号标签", regex: "\\[([^\\]]+)\\]"),
            .builtin(id: builtinPipe, name: "竖线后缀", regex: "(?i)(?:[|｜])\\s*([^|｜]+?)\\s*$"),
            .builtin(id: builtinBox, name: "框线分隔", regex: "(?i)┆\\s*([^┆]+)\\s*$"),
            .builtin(id: builtinBullet, name: "圆点后缀", regex: "(?i)(?:[•·])\\s*([^•·]+?)\\s*$"),
        ]
    }

    /// 当前生效的规则：内置 + 接口规则，各自减掉 `disabledIDs`，再滤掉编不出正则的。
    ///
    /// 内置规则只看「有没有被关掉」（它们自己的 `enabled` 恒为真）；接口规则还要看它自己写的 `enabled`
    /// —— 与上游 `entries()` 的判法一致。
    public static func activeRules(interfaceRules: [GroupRule] = [], disabledIDs: Set<String> = []) -> [GroupRule] {
        var active: [GroupRule] = []
        for rule in builtins where !disabledIDs.contains(rule.id) && rule.isValid {
            active.append(rule)
        }
        for rule in interfaceRules where rule.enabled && !disabledIDs.contains(rule.id) && rule.isValid {
            active.append(rule)
        }
        return active
    }

    /// 从文本里抽标签（对齐上游 `GroupRuleConfig.extract`）：所有生效规则的结果合并、**去重**、保持出现顺序。
    public static func extract(
        _ text: String,
        interfaceRules: [GroupRule] = [],
        disabledIDs: Set<String> = []
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        var groups: [String] = []
        for rule in activeRules(interfaceRules: interfaceRules, disabledIDs: disabledIDs) {
            for group in rule.extract(text) where !groups.contains(group) {
                groups.append(group)
            }
        }
        return groups
    }
}
