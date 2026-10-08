import CatVodCore
import Foundation

// 直播收藏频道的存档：**源名 → 收藏列表**（JSON 落 `UserDefaults`，键 `yplayer.liveFavorites`）。
//
// 上游把收藏放在 SQLite 的 `Keep` 表里（同一张表还放点播收藏，用 `type` / `cid` 区分）。
// 本项目点播收藏走 `FavoriteStore`（GRDB），直播收藏是「几十条以内、只需整表读写」的小表，
// 先按 `LiveKeepBook` 那套存 `UserDefaults`；等真要做「收藏分组排序 / 跨设备同步」再迁 GRDB。
//
// 按源名分桶的理由同 keep 位置：一个接口里可能有好几个直播源，频道名会撞车。

/// 直播收藏的存档（与界面无关的纯数据变换）。
enum LiveFavoriteBook {
    /// 写入某个源的收藏列表；源名为空时原样返回（没有可用的桶）。
    static func recording(
        _ favorites: [LiveFavorite],
        for sourceName: String,
        in book: [String: [LiveFavorite]]
    ) -> [String: [LiveFavorite]] {
        guard !sourceName.isEmpty else {
            return book
        }
        var updated = book
        updated[sourceName] = favorites
        return updated
    }

    /// 读存档：**坏数据当空**（收藏坏了不该让直播页打不开），空源名与空名字的条目丢掉。
    static func decode(_ raw: String?) -> [String: [LiveFavorite]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: [LiveFavorite]].self, from: data) else {
            return [:]
        }
        var result: [String: [LiveFavorite]] = [:]
        for (sourceName, favorites) in decoded where !sourceName.isEmpty {
            let valid = favorites.filter { !$0.name.isEmpty }
            if !valid.isEmpty {
                result[sourceName] = valid
            }
        }
        return result
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有收藏」，不写坏数据）。
    static func encode(_ book: [String: [LiveFavorite]]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
