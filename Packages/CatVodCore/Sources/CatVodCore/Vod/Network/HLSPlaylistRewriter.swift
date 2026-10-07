import Foundation

/// HLS 清单改写：把播放列表里的子清单 / 分片 / `URI="…"` 全部换成走本机服务。
///
/// 对照上游 `server/process/M3u8.java`（`/m3u8` 路由；为「直播源直接吐 `127.0.0.1:9978/m3u8?url=…`」
/// 这类写法兜底 —— 解析器或直播源里写死了本机地址时，本机必须真的能应答）：
/// 1. **只有清单才改写**：`Content-Type` 含 `mpegurl`/`m3u8`，或地址路径（去掉 query）以 `.m3u8`/`.m3u` 结尾；
/// 2. **改写规则**：非空且不以 `#` 开头的行 → 解析成绝对地址后代理；
///    含 `URI="…"` 的注释行（`#EXT-X-KEY` / `#EXT-X-MAP` / `#EXT-X-MEDIA`）→ 逐个替换属性里的地址；
/// 3. 分片 / 密钥请求也走同一条路由，由上层**原样转发**（只有清单会被改写）。
///
/// 为什么必须改写子清单：主清单里的 `#EXT-X-STREAM-INF` 指向的子清单如果保持原样，
/// 播放器会直接向上游取，子清单里的分片就**带不上**站点 header（这正是本地服务的意义）；
/// 而且子清单里的相对路径也会失去基准地址。
///
/// 与上游的差别（有意为之，均已记录）：
/// - 代理地址不硬编码 `127.0.0.1:9978`：本项目端口是扫出来的，由调用方给出（见 `LocalProxyHandler`）；
/// - 行分隔原样保留（上游 `String.split` 会吃掉结尾空行，这里保留，播放器对结尾换行更宽容）；
/// - 额外的 header 透传由调用方在 `proxy` 闭包里处理（上游那条路用的是写死的 UA/Referer）。
public enum HLSPlaylistRewriter {
    /// 响应是不是 HLS 清单（上游 `M3u8.isPlaylist`）。
    public static func isPlaylist(url: String, contentType: String = "") -> Bool {
        let mime = contentType.lowercased()
        if mime.contains("mpegurl") || mime.contains("m3u8") {
            return true
        }
        var path = url.lowercased()
        if let cutoff = path.firstIndex(of: "?") {
            path = String(path[path.startIndex ..< cutoff])
        }
        return path.hasSuffix(".m3u8") || path.hasSuffix(".m3u")
    }

    /// 文本是不是清单（上游 `M3u8.looksLikePlaylist`：去掉首尾空白后以 `#EXTM3U` 开头）。
    public static func looksLikePlaylist(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    /// 改写清单：把每条地址交给 `proxy` 处理（`proxy` 收到的是**已解析成绝对地址**的 URL）。
    public static func rewrite(
        _ playlist: String,
        baseURL: String,
        proxy: (String) -> String
    ) -> String {
        playlist.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                return proxy(resolve(trimmed, against: baseURL))
            }
            if trimmed.hasPrefix("#"), trimmed.contains("URI=\"") {
                return rewriteURIAttributes(line, baseURL: baseURL, proxy: proxy)
            }
            return line
        }
        .joined(separator: "\n")
    }

    /// 把一条地址解析成绝对地址（等价上游 `HttpUrl.resolve`）：
    /// 相对路径按清单地址解析，`//host/x` 这类协议相对地址也会补上 scheme；解析失败时原样返回。
    ///
    /// 基准地址**必须带 scheme** 才算可用：`URL(string:)` 对 `"not a url"` 这种文本也返回非 nil，
    /// 拿它当基准会把 `seg.ts` 解析成 `//seg.ts`（CI 实测过一个断言）。没有 scheme 就没有可解析的上下文。
    public static func resolve(_ value: String, against baseURL: String) -> String {
        guard let base = URL(string: baseURL), base.scheme != nil else {
            return value
        }
        return URL(string: value, relativeTo: base)?.absoluteString ?? value
    }

    /// 替换一行里所有 `URI="…"`（密钥 / 初始化段 / 字幕）。
    ///
    /// 实现说明：不用正则 —— 上游用 `URI="([^"]+)"` 逐个替换，这里做等价的手工扫描：
    /// 语义相同（`URI=` 大小写敏感、成对引号内的整段替换），但少一处正则依赖。
    static func rewriteURIAttributes(_ line: String, baseURL: String, proxy: (String) -> String) -> String {
        var result = ""
        var rest = Substring(line)
        while let openQuote = rest.range(of: "URI=\"") {
            result += rest[rest.startIndex ..< openQuote.upperBound]
            rest = rest[openQuote.upperBound...]
            guard let closeQuote = rest.firstIndex(of: "\"") else {
                // 引号不闭合：原样吐出剩余部分，不猜。
                return result + rest
            }
            result += proxy(resolve(String(rest[rest.startIndex ..< closeQuote]), against: baseURL))
            rest = rest[closeQuote...]
        }
        return result + rest
    }
}
