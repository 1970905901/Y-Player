import Foundation

/// 站点**显示名**与**搜索命中**的规则（逐条对齐上游 `setting/SiteNameRules.java`）。
///
/// 站点名有三个来源，优先级就是下面这几条：**用户自定义名 > 配置里的原始名 > 站点 key**。
/// 分组条（`GroupRule`）吃的是 ``effectiveName(rawName:customName:)`` ——
/// 用户把站点改名成 `[主力]爸妈用` 之后，标签要按**新名**抽（上游 `SiteNameRules.groups` 同理）。
public enum SiteNameRules {
    /// 生效名：自定义名（去空白后）非空就用它，否则用原始名。
    public static func effectiveName(rawName: String, customName: String) -> String {
        let custom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? rawName : custom
    }

    /// 面板上显示的名字：生效名为空时回落站点 key（上游 `SiteNameStore.getDisplayName`）。
    public static func displayName(rawName: String, customName: String, key: String) -> String {
        let name = effectiveName(rawName: rawName, customName: customName)
        return name.isEmpty ? key : name
    }

    /// 落盘用的自定义名：和原始名（各自去空白后）**一样就不存** ——
    /// 存了等于把「还原成原名」变成「改成一个看起来一样的名字」，用户再也无法真的还原。
    public static func customNameForStorage(rawName: String, inputName: String) -> String {
        let value = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == rawName.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : value
    }

    /// 从**生效名**里抽分组标签。
    public static func groups(
        rawName: String,
        customName: String,
        interfaceRules: [GroupRule] = [],
        userRules: [GroupRule] = [],
        disabledIDs: Set<String> = []
    ) -> [String] {
        let name = effectiveName(rawName: rawName, customName: customName)
        return GroupRuleConfig.extract(
            name,
            interfaceRules: interfaceRules,
            userRules: userRules,
            disabledIDs: disabledIDs
        )
    }

    /// 搜索命中：**生效名 / 原始名 / 站点 key** 任一包含关键词即算（大小写不敏感）。
    ///
    /// 三个都查是有意的：改过名的站点仍要能被原名搜到（用户可能记不住自己改成了什么），
    /// `csp_xxx` 这种 key 也应当能被搜到（面板上看得见的名字可能为空）。
    public static func matchesSearch(
        rawName: String,
        customName: String,
        key: String,
        keyword: String
    ) -> Bool {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return true
        }
        let candidates = [effectiveName(rawName: rawName, customName: customName), rawName, key]
        return candidates.contains { $0.lowercased().contains(query) }
    }
}
