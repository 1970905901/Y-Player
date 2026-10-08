import CatVodCore
import Foundation

// 直播「上次观看」的存档：**源名 → `分组@@@频道@@@线路下标`**。
//
// 上游把这一行写进源对象自己的 `keep` 字段，随配置一起落库（`Live.keep(Channel)` + `LiveConfig`）；
// 本项目不持有可写的配置副本，所以另存一份：`UserDefaults` 键 `yplayer.liveKeep`。
// 按**源名**分桶是必须的 —— 一个接口里通常有好几个直播源，各自的频道名会撞车。
//
// 存档用 JSON 而不是自己拼分隔符：分组名/频道名里出现引号、换行都是可能的（分隔符本身
// `@@@` 也有可能出现），JSON 能把这些原样往返。坏存档当「没有记录」，不让直播页打不开。

/// 直播「上次观看」的存档（与界面无关的纯数据变换）。
enum LiveKeepBook {
    /// 记一次：写入 / 覆盖某个源的上次观看。源名为空时原样返回（没有可用的桶）。
    static func recording(_ keep: LiveKeep, for sourceName: String, in book: [String: String]) -> [String: String] {
        guard !sourceName.isEmpty else {
            return book
        }
        var updated = book
        updated[sourceName] = keep.rawValue
        return updated
    }

    /// 读存档：**坏数据当空**（存档坏了不该让直播页打不开），非字符串的值也会被丢掉。
    static func decode(_ raw: String) -> [String: String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有记录」，不写坏数据）。
    static func encode(_ book: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
