import Foundation

/// 弹幕**搜索接口**的地址策略（对齐上游 `api/DanmakuApi.java`）。
///
/// 上游支持两种约定，写在用户填的那一个地址里：
/// 1. **模板**：地址里出现 `{name}` / `{episode}` → 直接做百分号编码替换，走 **GET**；
/// 2. **基地址**：否则先按 `getSearchUrl` 规则推出搜索地址，再走 **POST**，表单字段 `name` / `episode`。
///
/// `getSearchUrl` 的三条规则（上游原样）：
/// - 路径最后一段已经是 `danmaku`（大小写不敏感）→ 原样用；
/// - 路径**超过一段**（如 `/api/v1`）→ 原样用（约定 path 自带接口名）；
/// - 否则 → 补一段 `/danmaku`。
public enum DanmakuAPI {
    /// 一次搜索请求（GET 模板 / POST 表单）。
    public enum SearchRequest: Sendable, Equatable {
        case get(URL)
        case post(URL, fields: [String: String])
    }

    /// 组装搜索请求；地址为空、URL 解析不出来时返回 nil（上游 `newCall` 的判法）。
    public static func searchRequest(api: String, name: String, episode: String) -> SearchRequest? {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        // 上游只做简繁转换（`Trans.t2s`），本项目没有对应资源表，这里仅去掉首尾空白。
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodeName = episode.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("{name}") || trimmed.contains("{episode}") {
            let filled = trimmed
                .replacingOccurrences(of: "{name}", with: percentEncoded(title))
                .replacingOccurrences(of: "{episode}", with: percentEncoded(episodeName))
            guard let url = URL(string: filled) else {
                return nil
            }
            return .get(url)
        }

        guard let url = searchURL(trimmed) else {
            return nil
        }
        return .post(url, fields: ["name": title, "episode": episodeName])
    }

    /// 基地址 → 搜索地址（上游 `getSearchUrl`）。
    public static func searchURL(_ api: String) -> URL? {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if segments.last?.lowercased() == "danmaku" || segments.count > 1 {
            return components.url
        }
        components.path += "/danmaku"
        return components.url
    }

    /// 表单编码（`application/x-www-form-urlencoded`：空格用 `+`，与 OkHttp `FormBody` 一致）。
    public static func formEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(percentEncoded($0.key, plusForSpace: false))=\(percentEncoded($0.value, plusForSpace: true))" }
            .joined(separator: "&")
    }

    /// 百分号编码：保留 RFC 3986 的 unreserved（与 Android `Uri.encode` 的保守程度相当）。
    static func percentEncoded(_ value: String, plusForSpace: Bool = false) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if Self.unreserved.contains(scalar) {
                result.unicodeScalars.append(scalar)
                continue
            }
            if plusForSpace, scalar == " " {
                result.append("+")
                continue
            }
            for byte in String(scalar).utf8 {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
