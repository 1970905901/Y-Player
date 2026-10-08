import CatVodCore
import Foundation

// 站点面板的**自定义名**存档：**接口摘要 → {站点 key: 自定义名}**（JSON 落 `UserDefaults`，键 `yplayer.siteNames`）。
//
// 上游对应 `setting/SiteNameStore`（键 `site_names`，形状一致：`{config: {siteKey: name}}`）。
// 桶键用 `ConfigIdentity.key(for:)` 的摘要、不用明文地址：地址里可能带 token，而这是要落盘的东西
// （与 `HLSAdRuleState` 的源标识摘要同一考虑）。

/// 站点自定义名的存档（与界面无关的纯数据变换）。
enum SiteNameBook {
    /// 读存档：**坏数据当空**（名字坏了最坏就是回到原始名），空桶与空名字都丢掉。
    static func decode(_ raw: String?) -> [String: [String: String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        var result: [String: [String: String]] = [:]
        for (config, names) in decoded where !config.isEmpty {
            let valid = names.filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !valid.isEmpty {
                result[config] = valid
            }
        }
        return result
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有自定义名」，不写坏数据）。
    static func encode(_ book: [String: [String: String]]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 记一个自定义名：`inputName` 用 ``SiteNameRules/customNameForStorage(rawName:inputName:)`` 规整
    /// （与原名一样 = 删除这一项，用户才算真的还原）；没有桶名就原样返回。
    static func recording(
        _ inputName: String,
        rawName: String,
        for siteKey: String,
        config: String,
        in book: [String: [String: String]]
    ) -> [String: [String: String]] {
        guard !config.isEmpty, !siteKey.isEmpty else {
            return book
        }
        var updated = book
        var names = updated[config] ?? [:]
        let value = SiteNameRules.customNameForStorage(rawName: rawName, inputName: inputName)
        if value.isEmpty {
            names.removeValue(forKey: siteKey)
        } else {
            names[siteKey] = value
        }
        if names.isEmpty {
            updated.removeValue(forKey: config)
        } else {
            updated[config] = names
        }
        return updated
    }
}
