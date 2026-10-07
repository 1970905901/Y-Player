import Foundation

/// 播放地址集合。
///
/// 对照 webhtv `docs/integration/player.md` 的「URL 结构」，`url` 支持三种形态：
/// ```json
/// { "url": "https://example.com/video.m3u8" }
/// { "url": ["标清", "https://example.com/sd.m3u8", "高清", "https://example.com/hd.m3u8"] }
/// { "url": { "values": [ { "n": "高清", "v": "..." } ], "position": 0 } }
/// ```
public struct PlaybackURLs: Codable, Sendable, Hashable {
    /// 单条地址：`name` 为显示名（可能为空）。
    public struct Entry: Codable, Sendable, Hashable {
        public var name: String
        public var url: String

        public init(name: String = "", url: String = "") {
            self.name = name
            self.url = url
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.lenientString(.name)
            url = container.lenientString(.url)
            guard name.isEmpty || url.isEmpty else {
                return
            }
            // 对象形态使用 { n, v } 短键；用独立别名容器解码，避免与编码键冲突。
            let aliases = try decoder.container(keyedBy: ShortNameKeys.self)
            if name.isEmpty {
                name = aliases.lenientString(.n)
            }
            if url.isEmpty {
                url = aliases.lenientString(.v)
            }
        }

        enum CodingKeys: String, CodingKey {
            case name
            case url
        }

        private enum ShortNameKeys: String, CodingKey {
            case n
            case v
        }
    }

    public var entries: [Entry]
    /// 默认选中下标（对象形态的 `position`）。
    public var selectedIndex: Int

    public init(entries: [Entry] = [], selectedIndex: Int = 0) {
        self.entries = entries
        self.selectedIndex = selectedIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            entries = []
            selectedIndex = 0
            return
        }

        let value = (try? container.decode(AnyJSONValue.self)) ?? .null
        switch value {
        case .string(let url):
            entries = [Entry(name: "", url: url)]
            selectedIndex = 0
        case .array(let values):
            entries = Self.pairEntries(values)
            selectedIndex = 0
        case .object(let object):
            entries = Self.objectEntries(object)
            selectedIndex = (object["position"]?.intValue ?? 0).clamped(to: 0...(max(entries.count - 1, 0)))
        default:
            entries = []
            selectedIndex = 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if entries.count == 1, entries[0].name.isEmpty {
            try container.encode(entries[0].url)
            return
        }
        try container.encode(entries)
    }

    /// 数组形态：`[显示名1, 地址1, 显示名2, 地址2]`；
    /// 数量为奇数时最后一项按“只有地址”处理（与上游宽松解析一致）。
    private static func pairEntries(_ values: [AnyJSONValue]) -> [Entry] {
        var result: [Entry] = []
        var index = 0
        while index < values.count {
            let text = values[index].stringValue ?? ""
            if index + 1 < values.count {
                let next = values[index + 1].stringValue ?? ""
                result.append(Entry(name: text, url: next))
                index += 2
            } else {
                result.append(Entry(name: "", url: text))
                index += 1
            }
        }
        return result.filter { !$0.url.isEmpty }
    }

    /// 对象形态：`{ values: [{n, v}], position }`，也兼容 `{ url: ... }` 嵌套。
    private static func objectEntries(_ object: [String: AnyJSONValue]) -> [Entry] {
        if let values = object["values"]?.arrayValue {
            return values.compactMap { item in
                guard let url = item["v"]?.stringValue ?? item["url"]?.stringValue, !url.isEmpty else {
                    return nil
                }
                return Entry(name: item["n"]?.stringValue ?? item["name"]?.stringValue ?? "", url: url)
            }
        }
        if let nested = object["url"] {
            return pairEntries(nested.arrayValue ?? [nested])
        }
        if let direct = object["v"]?.stringValue {
            return [Entry(name: object["n"]?.stringValue ?? "", url: direct)]
        }
        return []
    }
}

public extension PlaybackURLs {
    var isEmpty: Bool {
        entries.isEmpty
    }

    var first: Entry? {
        entries.first
    }

    /// 默认选中的地址；下标越界时回退到第一条。
    var selected: Entry? {
        guard !entries.isEmpty else {
            return nil
        }
        let index = entries.indices.contains(selectedIndex) ? selectedIndex : entries.startIndex
        return entries[index]
    }
}

extension Comparable {
    /// 把值夹取到区间内。
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
