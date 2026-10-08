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

    /// 一条候选规则 + 它当前是否生效（对齐上游 `GroupRuleConfig.Entry`）。
    ///
    /// 为什么要包一层：**内置规则不看自己的 `enabled`**（它恒为真，只受「本地关掉的 id」影响），
    /// 而接口 / 用户规则是「自己的 `enabled` × 没被关掉」—— 两者判法不同，塞在一个布尔表达式里迟早写错。
    public struct Entry: Sendable, Equatable {
        public let rule: GroupRule
        public let isEnabled: Bool
    }

    /// 全部候选规则 —— **内置 → 接口 → 用户**，逐个算出「当前是否生效」。
    ///
    /// 顺序照上游 `entries()` 抄：它决定同一段站点名被多条规则命中时标签的先后，所以别随手调。
    /// （上游在「接口」和「用户」之间还有一档 AI 规则，来自 `AiGroupRuleStore`：本项目还没接 AI 服务，
    /// 位置先留在这里，接的时候插在 `interfaceRules` 与 `userRules` 之间。）
    public static func entries(
        interfaceRules: [GroupRule] = [],
        userRules: [GroupRule] = [],
        disabledIDs: Set<String> = []
    ) -> [Entry] {
        var items: [Entry] = []
        for rule in builtins {
            items.append(Entry(rule: rule, isEnabled: !disabledIDs.contains(rule.id)))
        }
        for rule in interfaceRules where !rule.id.isEmpty {
            items.append(Entry(rule: rule, isEnabled: rule.enabled && !disabledIDs.contains(rule.id)))
        }
        for rule in userRules where !rule.id.isEmpty {
            items.append(Entry(rule: rule, isEnabled: rule.enabled && !disabledIDs.contains(rule.id)))
        }
        return items
    }

    /// 当前生效的规则（`entries()` 里启用且正则编得出来的）。
    public static func activeRules(
        interfaceRules: [GroupRule] = [],
        userRules: [GroupRule] = [],
        disabledIDs: Set<String> = []
    ) -> [GroupRule] {
        entries(interfaceRules: interfaceRules, userRules: userRules, disabledIDs: disabledIDs)
            .filter { $0.isEnabled && $0.rule.isValid }
            .map(\.rule)
    }

    /// 生效条数 / 候选条数（设置页显示「已启用 N / 共 M」）。
    public static func enabledCount(
        interfaceRules: [GroupRule] = [],
        userRules: [GroupRule] = [],
        disabledIDs: Set<String> = []
    ) -> Int {
        activeRules(interfaceRules: interfaceRules, userRules: userRules, disabledIDs: disabledIDs).count
    }

    public static func totalCount(interfaceRules: [GroupRule] = [], userRules: [GroupRule] = []) -> Int {
        entries(interfaceRules: interfaceRules, userRules: userRules).count
    }

    /// 从文本里抽标签（对齐上游 `GroupRuleConfig.extract`）：所有生效规则的结果合并、**去重**、保持出现顺序。
    public static func extract(
        _ text: String,
        interfaceRules: [GroupRule] = [],
        userRules: [GroupRule] = [],
        disabledIDs: Set<String> = []
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        var groups: [String] = []
        let rules = activeRules(interfaceRules: interfaceRules, userRules: userRules, disabledIDs: disabledIDs)
        for rule in rules {
            for group in rule.extract(text) where !groups.contains(group) {
                groups.append(group)
            }
        }
        return groups
    }
}
