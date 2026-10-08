import Foundation

/// HLS 规则的**启用状态**：稳定的键 + 生效值解析。
///
/// 对齐参考实现 `app/src/main/java/com/fongmi/android/tv/bean/HlsRuleState.java`：
///
/// - 键是 `来源:源标识摘要:规则 id`；源标识先做摘要（接口地址可能很长、还可能带 token，不能直接进键）。
///   参考实现用 SHA-256 前 8 字节，本项目复用仓库里已有的 ``MD5``（Core 里没有 CryptoKit），
///   同样取 16 个十六进制字符 —— 这个键只是**本地偏好键**，不需要与上游互通，形状一致就够了；
/// - `:` 一律换成 `_`，免得键里出现分隔符歧义。
///
/// 生效值规则（**一处都不能松**）：本地开关 > 规则自己的 `enabledByDefault` > 关。
/// 内置规则默认关闭是硬要求（规则的来源是社区配置，见参考项目的 `docs/hls-rule-sources.md`）。
public enum HLSAdRuleState {
    /// 状态键。
    public static func key(origin: String, sourceID: String, ruleID: String) -> String {
        safe(origin) + ":" + digest(sourceID) + ":" + safe(ruleID)
    }

    /// 生效值：本地开关优先，其次规则自己的建议默认值，都没有就是关。
    ///
    /// 用于**规则包**（`HLSAdRulePackage`）：包里的规则默认关闭，要显式打开。
    /// 接口配置里的 `hlsRules` 不走这条 —— 它的基准是规则自己写的 `enabled`，见 ``resolveInterfaceEnabled(_:key:overrides:)``。
    public static func resolveEnabled(_ rule: HLSAdRule, key: String, overrides: [String: Bool]) -> Bool {
        if let override = overrides[key] {
            return override
        }
        return rule.enabledByDefault
    }

    /// 接口配置里的 `hlsRules` 的生效值：基准是**规则自己写的 `enabled: true`**（上游 `compileExternal` 的判法），
    /// 本地开关可以覆盖它 —— 两个方向都行（把接口写 `enabled: true` 的规则在本机关掉，或反过来）。
    public static func resolveInterfaceEnabled(_ rule: HLSAdRule, key: String, overrides: [String: Bool]) -> Bool {
        overrides[key] ?? rule.isEnabled
    }

    /// 一条接口规则在列表里的样子（界面用它做 `ForEach` 的 id，也用它做过滤）。
    ///
    /// 为什么包一层而不是返回元组：`ForEach` 的 `id:` 要 keyPath，元组取不了 keyPath。
    public struct Entry: Identifiable, Sendable, Equatable {
        public var rule: HLSAdRule
        /// 状态键（本地开关按它存）。
        public var key: String
        /// 当前是否生效（本地开关 > 规则自己写的 `enabled`）。
        public var isEnabled: Bool

        public var id: String { key }
    }

    /// 一批接口规则里**真正要生效**的那些；同时给出每条规则的状态键（界面列表要用同一份键，
    /// 免得「列表显示的开关」与「真正过滤用的键」两处对不上）。
    public static func interfaceEntries(
        _ rules: [HLSAdRule],
        origin: String,
        sourceID: String,
        overrides: [String: Bool]
    ) -> [Entry] {
        rules.map { rule in
            let ruleKey = key(origin: origin, sourceID: sourceID, ruleID: rule.id)
            let enabled = resolveInterfaceEnabled(rule, key: ruleKey, overrides: overrides)
            return Entry(rule: rule, key: ruleKey, isEnabled: enabled)
        }
    }

    /// `:` → `_`（参考实现 `safe`）。
    private static func safe(_ value: String) -> String {
        value.replacingOccurrences(of: ":", with: "_")
    }

    /// 源标识摘要（前 16 个十六进制字符）。
    private static func digest(_ value: String) -> String {
        String(MD5.hexDigest(of: safe(value)).prefix(16))
    }
}
