import CatVodCore
import Foundation

// 站点分组规则的**本地设置**：`{接口摘要: {关掉的规则 id, 用户自建规则}}`
// （JSON 落 `UserDefaults`，键 `yplayer.siteGroupRules`）。
//
// 上游把这两件事分成两个存储（`GroupRuleStore.loadDisabled()` / `loadUser()`，另有 AI 规则一份），
// 本项目合成一份「按接口分桶」的存档：桶键理由同 `SiteNameBook`（不看明文地址、不泄漏 token），
// 而且规则本来就是「接口配置 + 我的本地调整」的组合，放一起读起来更直白。

/// 一个接口上的分组规则设置。
struct SiteGroupRuleSettings: Codable, Sendable, Equatable {
    /// 被本地关掉的规则 id（内置规则用固定 id；接口 / 用户规则用它们自己的 id）。
    var disabledIDs: [String] = []
    /// 用户自建规则（`source` 会被当成 user）。
    var userRules: [GroupRule] = []
}

/// 规则设置的存档（与界面无关的纯数据变换）。
enum SiteGroupRuleBook {
    /// 读存档：**坏数据当空**（设置坏了最坏就是回到「四条内置全开、没有自建规则」），空桶丢掉。
    static func decode(_ raw: String?) -> [String: SiteGroupRuleSettings] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: SiteGroupRuleSettings].self, from: data) else {
            return [:]
        }
        var result: [String: SiteGroupRuleSettings] = [:]
        for (bucket, settings) in decoded where !bucket.isEmpty {
            let ids = settings.disabledIDs.filter { !$0.isEmpty }
            let rules = settings.userRules.filter { !$0.id.isEmpty && !$0.regex.isEmpty }
            if ids.isEmpty, rules.isEmpty {
                continue
            }
            result[bucket] = SiteGroupRuleSettings(disabledIDs: ids, userRules: rules)
        }
        return result
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有本地设置」，不写坏数据）。
    static func encode(_ book: [String: SiteGroupRuleSettings]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 写入某个接口的设置；两样都空就删掉这一桶；没有桶名就原样返回。
    static func recording(
        _ settings: SiteGroupRuleSettings,
        for bucket: String,
        in book: [String: SiteGroupRuleSettings]
    ) -> [String: SiteGroupRuleSettings] {
        guard !bucket.isEmpty else {
            return book
        }
        var updated = book
        if settings.disabledIDs.isEmpty, settings.userRules.isEmpty {
            updated.removeValue(forKey: bucket)
        } else {
            updated[bucket] = settings
        }
        return updated
    }
}
