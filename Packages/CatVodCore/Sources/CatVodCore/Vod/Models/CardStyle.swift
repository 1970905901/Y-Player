import Foundation

/// 卡片样式。
///
/// 对应 webhtv `docs/integration/result-vod.md` 的 Style：
/// `type` ∈ `rect`/`oval`/`list`，`ratio` 最大 4，`land=1` 等价 `rect + ratio=1.33`，`circle=1` 等价 `oval + ratio=1.0`。
public struct CardStyle: Codable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case rect
        case oval
        case list
    }

    /// 原始 `type` 文本（保留原值便于排查非法样式）。
    public var type: String
    /// `ratio` 上限常量，超出会被夹取。
    public static let maxRatio: Double = 4

    public var ratio: Double
    public var land: Int
    public var circle: Int

    public init(
        type: String = Kind.rect.rawValue,
        ratio: Double = 0,
        land: Int = 0,
        circle: Int = 0
    ) {
        self.type = type
        self.ratio = ratio
        self.land = land
        self.circle = circle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.lenientString(.type, default: Kind.rect.rawValue)
        ratio = container.lenientDouble(.ratio)
        land = container.lenientInt(.land)
        circle = container.lenientInt(.circle)
    }

    /// 归一化后的样式类型：`land=1` → rect，`circle=1` → oval（与上游等价规则一致）。
    public var kind: Kind {
        if circle == 1 {
            return .oval
        }
        if land == 1 {
            return .rect
        }
        return Kind(rawValue: type) ?? .rect
    }

    /// 归一化后的宽高比：显式 `ratio` 优先，否则按 kind 与 land/circle 取默认值，最后夹取到 `maxRatio`。
    public var resolvedRatio: Double {
        let candidate: Double
        if ratio > 0 {
            candidate = ratio
        } else if kind == .oval {
            candidate = 1.0
        } else if kind == .rect {
            candidate = land == 1 ? 1.33 : 0.75
        } else {
            candidate = 1.0
        }
        return min(max(candidate, 0.1), Self.maxRatio)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case ratio
        case land
        case circle
    }
}

/// 卡片样式在站点/条目上的叠加规则：条目样式 > 站点样式 > 默认 rect。
public enum CardStyleResolver {
    public static let fallback = CardStyle()

    public static func resolve(item: CardStyle?, site: CardStyle?) -> CardStyle {
        item ?? site ?? fallback
    }
}
