import Foundation

/// 顶层配置。
///
/// 字段与默认值对照 webhtv `docs/integration/configuration.md` 的「顶层字段」表。
/// 注意：`msg` 非空表示这是一份错误响应，加载流程必须直接失败（见 ``isErrorResponse``）。
public struct SourceConfig: Codable, Sendable, Hashable {
    /// 全局 JAR Spider 地址；站点/直播源未单独指定 `jar` 时使用。
    public var spider: String = ""
    /// 点播站点列表。
    public var sites: [Site] = []
    /// 点播解析器列表。
    public var parses: [ParserRule] = []
    /// 直播配置列表。
    public var lives: [LiveSource] = []
    /// DNS over HTTPS 配置。
    public var doh: [DohConfig] = []
    /// 代理规则。
    public var proxy: [ProxyRule] = []
    /// host 覆盖规则，格式 `匹配规则=目标host或IP`。
    public var hosts: [String] = []
    /// 按 host 注入请求 header。
    public var headers: [HeaderRule] = []
    /// 嗅探规则。
    public var rules: [SniffRule] = []
    /// HLS 广告清理规则。
    public var hlsRules: [HlsRule] = []
    /// 直播分组规则。
    public var groupRules: [GroupRule] = []
    /// 广告域名或正则字符串。
    public var ads: [String] = []
    /// 播放 flag 字符串数组。
    public var flags: [String] = []
    /// 壁纸 URL 或路径。
    public var wallpaper: String = ""
    /// 配置图标。
    public var logo: String = ""
    /// 配置公告。
    public var notice: String = ""
    /// 默认站点 `key`。
    public var home: String = ""
    /// 默认解析器 `name`。
    public var parse: String = ""
    /// 配置仓库/多配置入口。
    public var urls: [String] = []
    /// 错误消息；非空时加载会直接失败。
    public var msg: String = ""

    public init() { }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spider = container.lenientString(.spider)
        sites = container.lenientArray(.sites)
        parses = container.lenientArray(.parses)
        lives = container.lenientArray(.lives)
        doh = container.lenientArray(.doh)
        proxy = container.lenientArray(.proxy)
        hosts = container.lenientStringArray(.hosts)
        headers = container.lenientArray(.headers)
        rules = container.lenientArray(.rules)
        hlsRules = container.lenientArray(.hlsRules)
        groupRules = container.lenientArray(.groupRules)
        ads = container.lenientStringArray(.ads)
        flags = container.lenientStringArray(.flags)
        wallpaper = container.lenientString(.wallpaper)
        logo = container.lenientString(.logo)
        notice = container.lenientString(.notice)
        home = container.lenientString(.home)
        parse = container.lenientString(.parse)
        urls = container.lenientStringArray(.urls)
        msg = container.lenientString(.msg)
    }

    enum CodingKeys: String, CodingKey {
        case spider
        case sites
        case parses
        case lives
        case doh
        case proxy
        case hosts
        case headers
        case rules
        case hlsRules
        case groupRules
        case ads
        case flags
        case wallpaper
        case logo
        case notice
        case home
        case parse
        case urls
        case msg
    }
}

public extension KeyedDecodingContainer {
    /// 读取对象数组；元素解码失败时**整项跳过**，不影响其它元素（上游常有单个坏站点）。
    func lenientArray<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> [T] {
        guard let values = try? decodeIfPresent([LenientElement<T>].self, forKey: key) else {
            return []
        }
        return values.compactMap(\.value)
    }
}

/// 数组元素包装：把元素级解码失败降级为 nil，而不是抛出。
public struct LenientElement<Value: Decodable>: Decodable {
    public let value: Value?

    public init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
