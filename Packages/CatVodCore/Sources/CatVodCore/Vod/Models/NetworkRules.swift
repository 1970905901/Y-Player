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

// （M06d 修正）这里原来有个 `HlsRule`（`hosts` / `regex` / `exclude`），用来接配置的 `hlsRules`。
//
// 那是个**形状错误**：上游的 `hlsRules` 是 `HlsAdRule`（规则包形态：`id` / `playlistHostSuffixes` /
// `segmentUrlRegex` / `minDuration` / `enabled` …，见 `HlsAdRule.arrayFrom(fetchArray(object, "hlsRules"))`），
// 而 `{hosts, regex, exclude}` 那种形状属于 `rules`（解析规则，对应本项目的 `SniffRule`）。
// 按错的形状建模 ⇒ 真配置里的规则解析成空对象、**静默失效**（不报错、也没有一条能匹配）——
// 所以整条删掉：`hlsRules` 用 `HLSAdRule`，解析规则的 `exclude` 走 `SniffRule+CleanerRule.swift`。

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
