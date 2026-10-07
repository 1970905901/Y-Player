import Foundation

/// 点播解析器。
///
/// 对照 webhtv `docs/integration/parser.md`：解析器请求 header **只**从 `ext.header` 读取，
/// 顶层 `header` 字段不会反序列化为解析器配置。
public struct ParserRule: Codable, Sendable, Hashable, Identifiable {
    /// 解析器名称；UI 展示与 `parse:{name}` 前缀匹配的键。
    public var name: String
    /// 解析类型，取值语义见 ``ParserKind``。
    public var type: Int
    /// 解析地址或 JAR parser key。
    public var url: String
    /// 解析扩展（flag / header）。
    public var ext: ParserExt
    /// WebView 点击脚本。
    public var click: String

    public var id: String { name }

    public init(
        name: String,
        type: Int,
        url: String,
        ext: ParserExt = ParserExt(),
        click: String = ""
    ) {
        self.name = name
        self.type = type
        self.url = url
        self.ext = ext
        self.click = click
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        type = container.lenientInt(.type)
        url = container.lenientString(.url)
        ext = container.lenientValue(.ext) ?? ParserExt()
        click = container.lenientString(.click)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case url
        case ext
        case click
    }
}

/// 解析器扩展：`flag` 为适用播放线路，空数组表示不过滤。
public struct ParserExt: Codable, Sendable, Hashable {
    public var flag: [String]
    public var header: [String: String]

    public init(flag: [String] = [], header: [String: String] = [:]) {
        self.flag = flag
        self.header = header
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flag = container.lenientStringArray(.flag)
        header = container.lenientStringMap(.header)
    }

    enum CodingKeys: String, CodingKey {
        case flag
        case header
    }

    /// 该解析器是否适用于给定线路名（`flag` 为空表示适用全部线路）。
    public func accepts(flag: String) -> Bool {
        self.flag.isEmpty || self.flag.contains(flag)
    }
}

/// 解析类型。
///
/// 对照 webhtv `docs/integration/parser.md` 的「解析类型」表。
public enum ParserKind: Int, Sendable, CaseIterable {
    /// Web 解析：打开解析 WebView 嗅探真实播放地址。
    case web = 0
    /// JSON 解析：请求 `url + webUrl`，读取返回 JSON 的 `url` 或 `data.url`。
    case json = 1
    /// JAR Json 扩展：调用 `com.github.catvod.parser.Json{url}.parse(jxs, webUrl)`。
    case jarJson = 2
    /// JAR Mix 扩展：调用 `com.github.catvod.parser.Mix{url}.parse(jxs, parseName, flag, webUrl)`。
    case jarMix = 3
    /// 聚合解析：并发尝试符合 flag 的 JSON 与 Web 解析器。
    case aggregate = 4
}

public extension ParserRule {
    var kind: ParserKind? {
        ParserKind(rawValue: type)
    }

    /// 当前平台是否支持该解析器；JAR 类型明确不支持。
    var availability: SiteAvailability {
        switch kind {
        case .web, .json, .aggregate:
            return .available
        case .jarJson, .jarMix:
            return .unavailable(reason: "需要 JVM，Apple 平台不支持 JAR 解析器")
        case nil:
            return .unavailable(reason: "未知解析类型 type=\(type)")
        }
    }
}

/// 解析结果的最小成功判定。
///
/// 对照 webhtv `docs/integration/parser.md` 的错误处理：
/// JSON 解析返回的 `url` 长度大于 40 才视为成功。
public enum ParserOutcome {
    public static let minimumJSONURLCount = 41

    public static func isValidJSONResult(_ url: String) -> Bool {
        url.count >= minimumJSONURLCount
    }
}
