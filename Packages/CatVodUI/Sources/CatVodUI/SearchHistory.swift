import Foundation

// 搜索历史的纯逻辑：去重置顶、封顶、存档读写。
//
// 为什么单独抽出来：这几条规则在真机上都不好逐个造（要凑出重复关键词、凑满上限、造一份坏存档），
// 而做错的表现又是「点了历史没反应」「历史里出现两条一样的」这类只能靠人肉发现的问题。
//
// 存档用 JSON 而不是 `|` 这类分隔符：关键词里完全可能出现分隔符、换行或表情，
// 拼接式存储遇到这种关键词就会把一条历史读成两条。

/// 搜索历史（与界面无关的纯数据变换）。
enum SearchHistory {
    /// 最多保留多少条：够用，又不会把小屏的历史区撑到需要滚动。
    static let limit = 20

    /// 记录一次搜索：去首尾空白、忽略空串、重复的提到最前、超出上限丢最旧的。
    static func adding(_ keyword: String, to history: [String]) -> [String] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return history
        }
        var updated = history.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        return Array(updated.prefix(limit))
    }

    /// 读存档：**坏数据当空历史**（历史坏了不该让搜索页打不开），超过上限的裁掉。
    static func decode(_ raw: String) -> [String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(limit))
    }

    /// 写存档：编码失败就返回空串（调用方把它当「没有历史」，不写坏数据）。
    static func encode(_ history: [String]) -> String {
        guard let data = try? JSONEncoder().encode(history) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
