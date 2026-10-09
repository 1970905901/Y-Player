import Foundation

/// 手动匹配：用户指定「这一片其实是 TMDB 的哪一条」（M11 片 5）。
///
/// 自动匹配是「按片名搜 TMDB、取第一条」，而站点给的片名常带杂质
/// （`[4K] 仙逆 第一季` / `仙逆 (2023)`）—— 搜不到、搜到别的，都真发生过。
/// 这一层就是给那种情况留的**人工纠正**通道：键是站点片名原文，值是 TMDB 的 kind + id。
public struct TMDBMatchKey: Hashable, Sendable {
    public var kind: TMDBClient.Kind
    public var id: Int

    public init(kind: TMDBClient.Kind, id: Int) {
        self.kind = kind
        self.id = id
    }

    /// 落盘 / 当加载键用的短 token：`movie:123` / `tv:456`。
    public var storageToken: String {
        "\(kind.rawValue):\(id)"
    }

    /// 从 token 还原。kind 不认识、id 不是正数就当**没有** ——
    /// 宁可不匹配（界面回落自动搜），也不拿一个错 id 去请求。
    public init?(storageToken: String) {
        let parts = storageToken.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = TMDBClient.Kind(rawValue: String(parts[0])),
              let id = Int(parts[1]),
              id > 0
        else {
            return nil
        }
        self.init(kind: kind, id: id)
    }

    /// 给人看的形态（面板里的「当前」那一行）：`剧集 · 1234`。
    public var displayText: String {
        "\(kind == .movie ? "电影" : "剧集") · \(id)"
    }
}

/// 「片名 → 该用 TMDB 的哪一条」的手动匹配表（M11 片 5），一行一条：`片名|movie:123`。
///
/// 片名**先百分号编码再落盘**：站点片名里出现 `|` 或换行时，分隔符不会被撕开
/// （其余字符全编码，编码后的串里不可能再有 `|`）。
///
/// 解析口径与本仓其它偏好**故意不同**：`TMDBConfig` 那种「字段数不对就整条作废」在这里不合适 ——
/// 一行坏记录只丢那一行，其余照留（用户手动配过的东西，不该被别的片名里的怪字符连坐）。
public struct TMDBMatchBook: Sendable, Equatable {
    private var entries: [String: TMDBMatchKey]

    public init(entries: [String: TMDBMatchKey] = [:]) {
        var normalized: [String: TMDBMatchKey] = [:]
        for (title, key) in entries {
            let trimmed = Self.normalizedTitle(title)
            guard !trimmed.isEmpty else {
                continue
            }
            normalized[trimmed] = key
        }
        self.entries = normalized
    }

    /// 从落盘串还原。
    public init(storageString: String) {
        var parsed: [String: TMDBMatchKey] = [:]
        for line in storageString.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let decoded = String(parts[0]).removingPercentEncoding,
                  let key = TMDBMatchKey(storageToken: String(parts[1]))
            else {
                continue
            }
            let title = Self.normalizedTitle(decoded)
            guard !title.isEmpty else {
                continue
            }
            parsed[title] = key
        }
        self.init(entries: parsed)
    }

    /// 落盘形态：**按片名排序**输出（同一张表每次写出同一串，便于比对、也便于测试）。
    public var storageString: String {
        entries
            .sorted { $0.key < $1.key }
            .compactMap { entry in
                guard let encoded = entry.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                    return nil
                }
                return "\(encoded)|\(entry.value.storageToken)"
            }
            .joined(separator: "\n")
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var count: Int {
        entries.count
    }

    /// 表里记着的片名（排序后；界面与日志用）。
    public var titles: [String] {
        entries.keys.sorted()
    }

    /// 查这一片的手动匹配：片名同样**去空白归一** —— 写的时候归一、查的时候不归一，
    /// 就会出现「明明设过却查不到」（Mac 上第一次跑测试就是这么红的）。
    public func key(for title: String) -> TMDBMatchKey? {
        entries[Self.normalizedTitle(title)]
    }

    /// 记一条 / 清一条：`key` 传 nil 就是「恢复自动匹配」。
    /// 空白片名直接忽略 —— 空键会把整页元信息串味。
    public mutating func setKey(_ key: TMDBMatchKey?, for title: String) {
        let trimmed = Self.normalizedTitle(title)
        guard !trimmed.isEmpty else {
            return
        }
        entries[trimmed] = key
    }

    /// 片名归一：去掉前后空白。**写、查、还原三处都走它** —— 三处不一致就会出现「写了却查不到」。
    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
