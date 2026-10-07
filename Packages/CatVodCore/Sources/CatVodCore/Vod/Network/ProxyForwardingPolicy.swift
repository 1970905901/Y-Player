import Foundation

/// 本地代理的 header 转发策略。
///
/// 依据（见 `docs/架构设计.md`「播放内核」）：**header 必须覆盖主清单、子清单、分片、密钥与字幕请求**。
/// AVPlayer 只会给主请求带上 URL 里的信息，因此这些请求都要由本机代理补 header 后转发。
///
/// 三条规则：
/// 1. 逐跳 header（`Connection`、`Transfer-Encoding`、`Host`…）不得透传（RFC 9110 §7.6.1）；
/// 2. 客户端能透传的只有「播放器语义 + 站点鉴权」相关的那几项，其余丢弃（避免把本机 header 泄漏给源站）；
/// 3. 响应侧只回传实体与缓存相关 header，**`Content-Encoding` / `Content-Length` 例外**：
///    `URLSession` 已把 gzip 解压，这里交给本机服务按实际字节重新计算长度，否则播放器会解压失败。
public enum ProxyForwardingPolicy {
    /// 逐跳 header（不区分大小写）。
    public static let hopByHopHeaders: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
    ]

    /// 客户端 → 上游可透传的请求 header（`range` 是分片播放的关键）。
    public static let forwardableRequestHeaders: Set<String> = [
        "range",
        "if-range",
        "if-modified-since",
        "if-none-match",
        "accept",
        "accept-language",
        "user-agent",
        "referer",
        "origin",
        "cookie",
        "authorization",
        "x-requested-with",
        "dnt",
    ]

    /// 上游 → 客户端可透传的响应 header。
    public static let forwardableResponseHeaders: Set<String> = [
        "content-type",
        "content-range",
        "accept-ranges",
        "content-disposition",
        "etag",
        "last-modified",
        "cache-control",
        "expires",
        "date",
        "vary",
    ]

    /// 允许网页跨域读取（M5c 的 Web 嗅探要用 `fetch`/`XHR` 读响应体）。
    public static let corsResponseHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, POST, OPTIONS",
        "Access-Control-Expose-Headers": "*",
    ]

    /// 合并「客户端请求 header + 注入 header」，并剥掉逐跳 header 与非白名单项。
    ///
    /// 注入的 header 覆盖同名客户端 header（与站点头部注入的既定优先级一致：站点配置 > 播放器）；
    /// 同名判定**不区分大小写**（播放器发 `Referer`、站点配 `referer` 是同一件事，不能两条都发）。
    public static func upstreamRequestHeaders(
        client: [String: String],
        injected: [String: String]
    ) -> [String: String] {
        let forwarded = filter(client, keeping: forwardableRequestHeaders)
        let overrides = filter(injected, keeping: forwardableRequestHeaders)
        let overridden = Set(overrides.keys.map { $0.lowercased() })
        var result = forwarded.filter { !overridden.contains($0.key.lowercased()) }
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }

    /// 上游响应 header → 回给客户端的 header（含 CORS）。
    public static func clientResponseHeaders(upstream: [String: String]) -> [String: String] {
        var headers = filter(upstream, keeping: forwardableResponseHeaders)
        for (key, value) in corsResponseHeaders where headers[key] == nil {
            headers[key] = value
        }
        return headers
    }

    /// 是否允许透传到客户端。
    public static func isForwardableResponseHeader(_ name: String) -> Bool {
        forwardableResponseHeaders.contains(name.lowercased())
    }

    /// 是否逐跳 header。
    public static func isHopByHop(_ name: String) -> Bool {
        hopByHopHeaders.contains(name.lowercased())
    }

    /// 按白名单过滤（大小写不敏感），并剥掉逐跳 header。
    private static func filter(_ headers: [String: String], keeping allowed: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            let lowered = key.lowercased()
            guard allowed.contains(lowered), !hopByHopHeaders.contains(lowered) else {
                continue
            }
            result[key] = value
        }
        return result
    }
}
