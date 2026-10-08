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
    public static func resolveEnabled(_ rule: HLSAdRule, key: String, overrides: [String: Bool]) -> Bool {
        if let override = overrides[key] {
            return override
        }
        return rule.enabledByDefault
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
