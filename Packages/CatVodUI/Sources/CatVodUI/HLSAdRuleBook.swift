import CatVodCore
import Foundation

// 广告清理规则的**本地开关**存档：`{状态键: 开 / 关}`（JSON 落 `UserDefaults`，键 `yplayer.hlsAdRuleOverrides`）。
//
// 状态键由 `HLSAdRuleState.key(origin:sourceID:ruleID:)` 生成，**已经含源标识摘要**（接口地址不落明文），
// 所以这里不需要再按接口分桶 —— 键本身就是全局唯一且可读的。

/// 广告规则开关的存档（与界面无关的纯数据变换）。
enum HLSAdRuleBook {
    /// 读存档：**坏数据当空**（开关坏了最坏就是回到「按规则的默认值」），空键丢掉。
    static func decode(_ raw: String?) -> [String: Bool] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded.filter { !$0.key.isEmpty }
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有本地开关」，不写坏数据）。
    static func encode(_ book: [String: Bool]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 写入 / 清掉某个键的开关；键为空就原样返回。
    static func recording(_ enabled: Bool?, for key: String, in book: [String: Bool]) -> [String: Bool] {
        guard !key.isEmpty else {
            return book
        }
        var updated = book
        if let enabled {
            updated[key] = enabled
        } else {
            // 传 nil = 回到「按规则自己的默认值」，而不是留一个显式的关
            updated.removeValue(forKey: key)
        }
        return updated
    }
}
