import Foundation

// 顶层网络规则模型。字段对照 webhtv docs/integration/configuration.md 的子对象字段表。

/// DNS over HTTPS 配置。
public struct DohConfig: Codable, Sendable, Hashable {
    /// 显示名。
    public var name: String
    /// DoH endpoint，例如 `https://dns.google/dns-query`。
    public var url: String
    /// bootstrap DNS IP；为空时用系统 DNS 解析 DoH host。
    public var ips: [String]

    public init(name: String = "", url: String = "", ips: [String] = []) {
        self.name = name
        self.url = url
        self.ips = ips
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        url = container.lenientString(.url)
        ips = container.lenientStringArray(.ips)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case ips
    }
}

/// 代理规则。
public struct ProxyRule: Codable, Sendable, Hashable {
    /// 代理规则名。
    public var name: String
    /// host 匹配规则；支持 `contains`、Java 正则和 `*`。
    public var hosts: [String]
    /// 代理地址；支持 `http://`、`socks://`、`socks5://`，账号密码写 `scheme://user:pass@host:port`。
    public var urls: [String]

    public init(name: String = "", hosts: [String] = [], urls: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.urls = urls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        hosts = container.lenientStringArray(.hosts)
        urls = container.lenientStringArray(.urls)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case hosts
        case urls
    }
}

/// 按 host 注入请求 header。
public struct HeaderRule: Codable, Sendable, Hashable {
    /// host 匹配规则。
    public var host: String
    /// 命中后注入的 header，覆盖同名值。
    public var header: [String: String]

    public init(host: String = "", header: [String: String] = [:]) {
        self.host = host
        self.header = header
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = container.lenientString(.host)
        header = container.lenientStringMap(.header)
    }

    enum CodingKeys: String, CodingKey {
        case host
        case header
    }
}

/// 嗅探规则。
public struct SniffRule: Codable, Sendable, Hashable {
    /// 规则名。
    public var name: String
    /// 适用 host；匹配 URL host 和 `url` 查询参数里的 host。
    public var hosts: [String]
    /// 视频 URL 识别规则（正则）。
    public var regex: [String]
    /// 排除规则（正则）。
    public var exclude: [String]
    /// WebView 页面加载后执行的 JS。
    public var script: [String]

    public init(
        name: String = "",
        hosts: [String] = [],
        regex: [String] = [],
        exclude: [String] = [],
        script: [String] = []
    ) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
        self.exclude = exclude
        self.script = script
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        hosts = container.lenientStringArray(.hosts)
        regex = container.lenientStringArray(.regex)
        exclude = container.lenientStringArray(.exclude)
        script = container.lenientStringArray(.script)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case hosts
        case regex
        case exclude
        case script
    }
}

/// HLS 广告清理规则（字段形状与 `rules` 一致的精简版）。
public struct HlsRule: Codable, Sendable, Hashable {
    public var hosts: [String]
    public var regex: [String]
    public var exclude: [String]

    public init(hosts: [String] = [], regex: [String] = [], exclude: [String] = []) {
        self.hosts = hosts
        self.regex = regex
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = container.lenientStringArray(.hosts)
        regex = container.lenientStringArray(.regex)
        exclude = container.lenientStringArray(.exclude)
    }

    enum CodingKeys: String, CodingKey {
        case hosts
        case regex
        case exclude
    }
}

/// 直播分组规则。
public struct GroupRule: Codable, Sendable, Hashable {
    public var name: String
    public var hosts: [String]
    public var regex: [String]

    public init(name: String = "", hosts: [String] = [], regex: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        hosts = container.lenientStringArray(.hosts)
        regex = container.lenientStringArray(.regex)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case hosts
        case regex
    }
}
