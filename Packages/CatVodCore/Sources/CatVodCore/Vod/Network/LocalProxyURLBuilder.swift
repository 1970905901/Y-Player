import Foundation

/// 本地代理服务的一次转发请求：目标地址 + 要注入的 header。
public struct LocalProxyRequest: Sendable, Hashable {
    /// 目标地址（未编码的原始 URL 文本）。
    public var url: String
    /// 要注入/覆盖的 header（站点 header → 详情 header → 解析器 header 合并后的结果）。
    public var headers: [String: String]

    public init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// 本地代理地址构造与参数编解码。
///
/// 端点契约（本项目自定义，理由见 `docs/任务记录/M06a-本地HTTP服务与本地代理.md`）：
/// `GET|HEAD /proxy?url=<percent-encoded>&h=<base64(JSON)>`，
/// 另支持 `POST /proxy`，请求体为 `{"url": "...", "headers": {...}}`（header 很多时更省事）。
///
/// 为什么不用上游的 `?do=<js代理器>`：上游 `/proxy` 是给 JS 代理器（`BaseLoader.proxy`）用的蜘蛛侧通道；
/// 本项目要解决的是**播放侧**的硬问题——AVPlayer 无法给 HLS 主清单之外的子清单/分片/密钥单独设 header，
/// 于是统一改走 `http://127.0.0.1:<port>/proxy?…`，由本机服务补 header 再取。
public struct LocalProxyURLBuilder: Sendable {
    /// 服务基地址，例如 `http://127.0.0.1:9978`。
    public var baseURL: URL
    /// 端点路径（不带 `/`）：默认 `proxy`；HLS 清单用 `m3u8`（见 ``path(forMediaURL:contentType:)``）。
    public var path: String

    public init(baseURL: URL, path: String = "proxy") {
        self.baseURL = baseURL
        self.path = path
    }

    /// 由 host/port 构造。
    public init(host: String = "127.0.0.1", port: UInt16, path: String = "proxy") {
        baseURL = URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "/")
        self.path = path
    }

    /// 按媒体地址自动选端点：HLS 清单走 `m3u8`，其余走 `proxy`。
    ///
    /// 为什么清单必须走 `/m3u8`：`/proxy` 只转发**被请求的那一条**地址，清单里的子清单 / 分片 / 密钥
    /// 地址不会被改写 —— 播放器会直接向上游取它们，站点 header 就丢了（分片 403 的常见原因）。
    /// `/m3u8` 会把整条链路的地址都指回本机（见 ``HLSPlaylistRewriter``）。
    public static func path(forMediaURL url: String, contentType: String = "") -> String {
        HLSPlaylistRewriter.isPlaylist(url: url, contentType: contentType) ? "m3u8" : "proxy"
    }

    /// `/proxy` 或 `/m3u8` 地址；参数非法时返回 nil。
    public func proxyURL(for request: LocalProxyRequest) -> URL? {
        guard !request.url.isEmpty else {
            return nil
        }
        let target = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = [URLQueryItem(name: "url", value: request.url)]
        if !request.headers.isEmpty {
            items.append(URLQueryItem(name: "h", value: Self.encodeHeaders(request.headers)))
        }
        components.queryItems = items
        return components.url
    }

    /// 便捷重载。
    public func proxyURL(for url: String, headers: [String: String] = [:]) -> URL? {
        proxyURL(for: LocalProxyRequest(url: url, headers: headers))
    }

    /// `/health` 地址（就绪探测与设置页展示用）。
    public func healthURL() -> URL? {
        baseURL.appendingPathComponent("health")
    }

    /// header 表 → 查询参数值（JSON 后 base64）。
    ///
    /// 用 base64 而不是「`name:value` 分号拼接」：header 值里本来就可能出现 `:`、`;`、换行（Cookie），
    /// 拼字符串会歧义；base64 还能原样保留 header 名的大小写。
    public static func encodeHeaders(_ headers: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(headers) else {
            return ""
        }
        return data.base64EncodedString()
    }

    /// 查询参数值 → header 表；非法输入退化为空表。
    public static func decodeHeaders(_ value: String?) -> [String: String] {
        guard let value, !value.isEmpty, let data = Data(base64Encoded: value) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// 从 `/proxy` 地址还原转义请求；缺 `url` 参数返回 nil。
    public static func decode(url proxyURL: URL) -> LocalProxyRequest? {
        guard let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard let items = components.queryItems else {
            return nil
        }
        var target: String?
        var headers: [String: String] = [:]
        for item in items {
            switch item.name {
            case "url":
                target = item.value
            case "h":
                headers = decodeHeaders(item.value)
            default:
                continue
            }
        }
        guard let target, !target.isEmpty else {
            return nil
        }
        return LocalProxyRequest(url: target, headers: headers)
    }
}
