import CatVodCore
import Foundation

// 「组名里的 `_` 不当密码」这个本地覆盖的存档：**源名 → 覆盖值**（JSON 落 `UserDefaults`）。
//
// 按源存：上游 `pass` 就是每个源自己的字段，一个配置里两个源可能只有一个需要这个开关。
// 存显式布尔值而不是「打开过的源集合」：开关要**两个方向**都能拨（源里写了 `pass: true`
// 而用户想关掉），所以覆盖值必须能表达 `false`。

/// 本地覆盖的存档（与界面无关的纯数据变换）。
enum LivePassBook {
    /// 给某个源写一个覆盖值；源名为空时原样返回（没有可用的桶）。
    static func setting(_ enabled: Bool, for sourceName: String, in book: [String: Bool]) -> [String: Bool] {
        guard !sourceName.isEmpty else {
            return book
        }
        var updated = book
        updated[sourceName] = enabled
        return updated
    }

    /// 清掉某个源的覆盖（回到「跟源自己的 `pass`」）；源名为空或本来没有覆盖就原样返回。
    static func clearing(_ sourceName: String, in book: [String: Bool]) -> [String: Bool] {
        guard !sourceName.isEmpty, book[sourceName] != nil else {
            return book
        }
        var updated = book
        updated.removeValue(forKey: sourceName)
        return updated
    }

    /// 读存档：**坏数据当空**（覆盖坏了不该让直播页打不开），丢掉空源名。
    static func decode(_ raw: String?) -> [String: Bool] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded.filter { !$0.key.isEmpty }
    }

    /// 写存档：编码失败返回空串（调用方把它当「没有覆盖」，不写坏数据）。
    static func encode(_ book: [String: Bool]) -> String {
        guard let data = try? JSONEncoder().encode(book) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
