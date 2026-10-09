import Foundation

/// TMDB 元信息层（Emby 视图）的配置：**只在切到 Emby 视图时才需要填**。
///
/// 三项都有明确读者：`apiKey` / `apiProxy` 给 ``apiURL(path:query:)`` 拼接口地址，
/// `imageProxy` 给 ``imageURL(_:)`` 改写图片地址 —— 不是「先存着备用」的字段。
public struct TMDBConfig: Sendable, Hashable {
    /// TMDB api key（v3）。
    public var apiKey: String
    /// TMDB **接口**代理地址（国内直连不到）。空 = 直连。
    public var apiProxy: String
    /// **图片**代理地址。空 = 不改写。
    public var imageProxy: String

    public init(apiKey: String = "", apiProxy: String = "", imageProxy: String = "") {
        self.apiKey = apiKey
        self.apiProxy = apiProxy
        self.imageProxy = imageProxy
    }

    /// 配齐没有：**只有 api key 是必需的**，代理都空着也能用（直连）。
    /// 没配时这一层整体不工作、界面显示占位，但不弹错 —— 这就是「切到 Emby 才要求填」的判定。
    public var isConfigured: Bool { !apiKey.isEmpty }

    /// TMDB 接口地址：直连 `https://api.themoviedb.org/3/...`，设了代理就交出去。
    public func apiURL(path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.themoviedb.org"
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = "/3/\(trimmedPath)"
        var items = query
        if !apiKey.isEmpty {
            items.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let direct = components.url?.absoluteString else {
            return nil
        }
        return URL(string: Self.rewrite(direct, with: apiProxy))
    }

    /// TMDB 图片地址：`raw` 可以是 `/abc.jpg` 这样的路径，也可以已经是完整地址。
    ///
    /// 路径一律按 `original` 尺寸拼（详情页顶部是全幅大图，小尺寸会糊）——
    /// 将来要省流量再按位置传尺寸，不在这里猜。
    public func imageURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let direct = trimmed.hasPrefix("http")
            ? trimmed
            : "https://image.tmdb.org/t/p/original\(trimmed.hasPrefix("/") ? "" : "/")\(trimmed)"
        return URL(string: Self.rewrite(direct, with: imageProxy))
    }

    /// 代理地址两种写法统一在这里收口（接口与图片**同一套规则**，省得用户记两套）：
    /// - 含 `{url}` → 当模板替换；
    /// - 否则 → 当前缀拼接（自动补一个 `/`，少踩一个坑）。
    private static func rewrite(_ direct: String, with proxy: String) -> String {
        let trimmed = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return direct
        }
        if trimmed.contains("{url}") {
            return trimmed.replacingOccurrences(of: "{url}", with: direct)
        }
        return trimmed.hasSuffix("/") ? trimmed + direct : trimmed + "/" + direct
    }
}

// MARK: - 落盘

extension TMDBConfig {
    /// 落 `UserDefaults` 的形态：`apiKey|apiProxy|imageProxy`。
    ///
    /// 用 `|` 做分隔是安全的：key 是字母数字，代理是地址，三个字段都不会含 `|`。
    /// （与本仓其它偏好一致 —— 见 `DanmakuDisplayConfig` / `SubtitleDisplayConfig` 的「落盘形态」。）
    public var storageString: String {
        [apiKey, apiProxy, imageProxy].joined(separator: "|")
    }

    /// 从存储串还原。**字段数不对就整条作废**（回落空配置）：
    /// 宁可不工作（界面会提示没填 key），也不要留下「半条配置」这种查不出的怪状态。
    public init(storageString: String) {
        let parts = storageString.components(separatedBy: "|")
        guard parts.count == 3 else {
            self.init()
            return
        }
        self.init(apiKey: parts[0], apiProxy: parts[1], imageProxy: parts[2])
    }
}

