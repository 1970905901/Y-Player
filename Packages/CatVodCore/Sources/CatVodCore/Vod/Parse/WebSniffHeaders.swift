import Foundation

/// 解析页 header 的收敛规则：逐条对齐上游 `WebSniffHeaders`
/// （webhtv `app/src/main/java/com/fongmi/android/tv/utils/WebSniffHeaders.java`）。
///
/// 为什么要有它：点播源给的 header 常常是**给播放器**的（例如 `User-Agent: okhttp/3.12`），
/// 原样拿去开解析页会被站点判成爬虫。上游的做法是：非浏览器 UA 一律扔掉，
/// 只有当「确实扔掉了 UA」且「WebView 自己的 UA 是浏览器 UA」时，才回填一个干净的浏览器 UA。
///
/// 平台差异：上游用 `LinkedHashMap` 保序，这里用 Swift 字典（无序）；header 是键值集合，
/// 顺序不影响任何后续判定（``SniffRule`` 匹配看 host，不看 header）。
public enum WebSniffHeaders {
    /// 交给解析页的 header（上游 `forPage(headers, fallbackUserAgent)`）。
    ///
    /// - Parameter fallbackUserAgent: WebView 当前的 UA；仅在上面「扔掉了非浏览器 UA」时用作回填来源。
    public static func forPage(headers: [String: String], fallbackUserAgent: String = "") -> [String: String] {
        var result: [String: String] = [:]
        var rejectedMediaUserAgent = false
        for (key, value) in headers {
            if isUserAgent(key), !isBrowserUserAgent(value) {
                rejectedMediaUserAgent = true
                continue
            }
            result[key] = value
        }
        if rejectedMediaUserAgent, isBrowserUserAgent(fallbackUserAgent) {
            result["User-Agent"] = browserUserAgent(fallbackUserAgent)
        }
        return result
    }

    /// 是否浏览器 UA（上游 `isBrowserUserAgent`）：含 `mozilla/` 且（含 `applewebkit/` 或 `gecko/`）。
    public static func isBrowserUserAgent(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("mozilla/") && (lower.contains("applewebkit/") || lower.contains("gecko/"))
    }

    /// 去掉「WebView 标记」（上游 `browserUserAgent`）：`; wv)` → `)`，删掉 ` Version/4.0`。
    public static func browserUserAgent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "; wv)", with: ")")
            .replacingOccurrences(of: " Version/4.0", with: "")
    }

    /// header 名是不是 UA（大小写不敏感；上游 `HttpHeaders.USER_AGENT.equalsIgnoreCase(key)`）。
    public static func isUserAgent(_ key: String) -> Bool {
        key.lowercased() == "user-agent"
    }
}
