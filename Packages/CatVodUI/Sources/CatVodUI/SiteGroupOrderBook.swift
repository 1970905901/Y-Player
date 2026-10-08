import CatVodCore
import Foundation

// 站点面板分组条的**顺序**存档：**接口 → 分组名数组**（JSON 落 `UserDefaults`，键 `yplayer.siteGroupOrder`）。
//
// 上游把顺序存成 `site_group_order_<cid>`（按接口 id 分桶）。本项目按**接口地址**分桶：
// 换接口时分组名会整套换掉，混在一份存档里会互相污染（与 `LiveKeepBook` / `LiveFavoriteBook` 同一套路）。

/// 分组顺序的存档（与界面无关的纯数据变换）。
enum SiteGroupOrderBook {
    /// 读存档：**坏数据当空**（存档坏了最坏就是回到默认顺序，不该影响面板打开），空桶丢掉。
    static func decode(_ raw: String?) -> [String: [String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for (bucket, order) in decoded where !bucket.isEmpty {
            let valid = SiteGroupOrder.normalized(order)
            if !valid.isEmpty {
                result[bucket] = valid
            }
        }
        return result
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有存过顺序」，不写坏数据）。
    static func encode(_ book: [String: [String]]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 把某个接口的新顺序写进存档（桶名为空时原样返回：没有可用的桶；空顺序 = 删掉这一项）。
    static func recording(_ order: [String], for bucket: String, in book: [String: [String]]) -> [String: [String]] {
        guard !bucket.isEmpty else {
            return book
        }
        var updated = book
        let normalized = SiteGroupOrder.normalized(order)
        if normalized.isEmpty {
            updated.removeValue(forKey: bucket)
        } else {
            updated[bucket] = normalized
        }
        return updated
    }
}
