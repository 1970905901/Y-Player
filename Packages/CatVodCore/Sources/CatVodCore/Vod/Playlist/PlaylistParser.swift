import Foundation

/// 播放列表解析：`vod_play_from` / `vod_play_url`。
///
/// 格式规则（webhtv `docs/integration/result-vod.md`）：
/// - 线路之间用 `$$$`；
/// - 单线路内选集用 `#`；
/// - 单集为 `集名$播放地址`；
/// - `vod_play_from` 与 `vod_play_url` 线路数量必须一致。
public enum PlaylistParser {
    /// 线路分隔符。
    public static let lineSeparator = "$$$"
    /// 选集分隔符。
    public static let episodeSeparator = "#"
    /// 集名与地址的分隔符。
    public static let fieldSeparator = "$"

    /// 播放线路。
    public struct Line: Sendable, Hashable, Identifiable {
        public var name: String
        public var episodes: [Episode]

        public var id: String { name }

        public init(name: String, episodes: [Episode]) {
            self.name = name
            self.episodes = episodes
        }
    }

    /// 单集。
    public struct Episode: Sendable, Hashable, Identifiable {
        /// 集名；源未提供时为空串。
        public var name: String
        /// 播放 ID 或原始地址。
        public var url: String

        public var id: String { "\(name)\(fieldSeparator)\(url)" }

        public init(name: String, url: String) {
            self.name = name
            self.url = url
        }

        /// 展示名：源未提供集名时用「第 N 集」占位由 UI 层决定，这里只回退为空串。
        public var displayName: String {
            name.isEmpty ? url : name
        }
    }

    /// 线路名列表。
    public static func lineNames(_ playFrom: String) -> [String] {
        split(playFrom, by: lineSeparator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 单线路的选集列表。
    public static func episodes(_ playURL: String) -> [Episode] {
        split(playURL, by: episodeSeparator).compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            guard let range = text.range(of: fieldSeparator) else {
                // 源省略集名：整段视为播放地址。
                return Episode(name: "", url: text)
            }
            let name = String(text[text.startIndex..<range.lowerBound])
            let url = String(text[range.upperBound...])
            guard !url.isEmpty else {
                return nil
            }
            return Episode(name: name, url: url)
        }
    }

    /// 解析整份播放列表。
    ///
    /// 线路名与线路数量不一致时按较长的维度补全：
    /// 缺名线路使用「线路 N」，缺数据线路为空选集，避免直接丢数据。
    public static func parse(playFrom: String, playURL: String) -> [Line] {
        let names = lineNames(playFrom)
        let groups = split(playURL, by: lineSeparator)
        let count = max(names.count, groups.count)

        guard count > 0 else {
            return []
        }

        return (0..<count).map { index in
            let name = index < names.count && !names[index].isEmpty ? names[index] : "线路 \(index + 1)"
            let episodes = index < groups.count ? episodes(groups[index]) : []
            return Line(name: name, episodes: episodes)
        }
    }

    /// 一致性校验：返回可记录的告警文本（空数组表示一致）。
    public static func consistencyIssues(playFrom: String, playURL: String) -> [String] {
        let names = lineNames(playFrom)
        let groups = split(playURL, by: lineSeparator)

        var issues: [String] = []
        if names.count != groups.count {
            issues.append("线路名数量(\(names.count))与播放列表数量(\(groups.count))不一致")
        }
        for (index, name) in names.enumerated() where name.isEmpty {
            issues.append("第 \(index + 1) 个线路名为空")
        }
        // 以「线路名与播放列表」的并集为准：声明了线路却没有对应数据也要报出来，
        // 否则 `playURL` 为空这种最常见的坏数据会被静默忽略。
        for index in 0..<max(names.count, groups.count) {
            let group = index < groups.count ? groups[index] : ""
            if episodes(group).isEmpty {
                issues.append("第 \(index + 1) 个线路没有可用选集")
            }
        }
        return issues
    }

    /// 按分隔符切分并保留空段（`$$$` 连续出现时代表空线路，不能静默丢弃）。
    private static func split(_ text: String, by separator: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        return text.components(separatedBy: separator)
    }
}
