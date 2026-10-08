import Foundation

/// 接口地址的**本地标识摘要**（对齐上游 `PlaybackConfigIdentity.keyForUrl`）。
///
/// 为什么不用明文地址当键：接口地址经常带 token，而「按接口分桶」的本地偏好（分组顺序、站点自定义名…）
/// 是要落盘的 —— 明文就等于把 token 留在磁盘上。这里与 `HLSAdRuleState` 的处理一致：先摘要再进键。
public enum ConfigIdentity {
    /// 摘要前缀：一眼能看出这是「接口标识」，而不是原始地址。
    static let prefix = "cfg:"

    /// 取接口地址的摘要键；空地址返回空串（调用方据此判断「没有可用的桶」）。
    public static func key(for configURL: String) -> String {
        let trimmed = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return prefix + String(MD5.hexDigest(of: trimmed).prefix(16))
    }
}
