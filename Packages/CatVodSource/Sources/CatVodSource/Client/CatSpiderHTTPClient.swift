import CatVodCore
import CatVodNet
import Foundation

/// CatSpider HTTP 协议客户端。
///
/// 严格对齐参考实现 `app/src/main/java/com/fongmi/android/tv/api/loader/CatSpider.java`：
/// - 站点匹配：`api` 以 `http` 开头且包含 `/spider/`；
/// - 全部路由使用 `POST` + JSON；
/// - 字段名与类型：`id`/`page`(整数)/`wd`/`filters`(对象)/`flag`；
/// - 响应若为 `{code,data}` 则取 `data`；`data` 为数组时包装成 `{list: [...]}`。
///
/// 本项目的主接口（`index.js` + `index.js.md5`）就是这种形态：本地 JS 宿主起服务后，
/// `api` 指向 `http://127.0.0.1:<port>/spider/...`。
public struct CatSpiderHTTPClient: Sendable {
    /// 路由表。
    public enum Route: String, Sendable, CaseIterable {
        case initialize = "/init"
        case home = "/home"
        case category = "/category"
        case detail = "/detail"
        case search = "/search"
        case play = "/play"
        /// 站点列表由 CatPawOpen 的 `/config` 提供（参考实现 CatSpider.java 的类注释）。
        case config = "/config"
    }

    public var baseURL: URL
    public var transport: HTTPTransport
    /// 站点级 header（合并进每次请求）。
    public var headers: [String: String]
    public var timeout: TimeInterval

    public init(
        baseURL: URL,
        transport: HTTPTransport,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.headers = headers
        self.timeout = timeout
    }

    /// 由站点配置创建客户端；`api` 尾部斜杠会被归一化。
    public init?(site: Site, transport: HTTPTransport) {
        let trimmed = site.api.hasSuffix("/") ? String(site.api.dropLast()) : site.api
        guard site.isCatSpiderHTTP, let url = URL(string: trimmed) else {
            return nil
        }
        self.init(
            baseURL: url,
            transport: transport,
            headers: site.header,
            timeout: TimeInterval(site.timeout)
        )
    }

    // MARK: - 协议方法

    public func initialize() async throws -> SpiderResult {
        try await post(.initialize, payload: [:], as: SpiderResult.self)
    }

    public func home() async throws -> SpiderResult {
        try await post(.home, payload: [:], as: SpiderResult.self)
    }

    public func category(
        id: String,
        page: Int,
        filters: [String: String] = [:]
    ) async throws -> SpiderResult {
        var payload: [String: PayloadValue] = [
            "id": .string(id),
            "page": .int(max(page, 1))
        ]
        if !filters.isEmpty {
            payload["filters"] = .object(filters)
        }
        return try await post(.category, payload: payload, as: SpiderResult.self)
    }

    public func detail(id: String) async throws -> SpiderResult {
        try await post(.detail, payload: ["id": .string(id)], as: SpiderResult.self)
    }

    public func search(keyword: String, page: Int) async throws -> SpiderResult {
        try await post(.search, payload: [
            "wd": .string(keyword),
            "page": .int(max(page, 1))
        ], as: SpiderResult.self)
    }

    public func play(flag: String, id: String) async throws -> SpiderResult {
        try await post(.play, payload: [
            "flag": .string(flag),
            "id": .string(id)
        ], as: SpiderResult.self)
    }

    /// 拉取站点清单（CatPawOpen `/config`）；不可用时由上层回退到其它入口。
    public func configuration() async throws -> SpiderResult {
        try await post(.config, payload: [:], as: SpiderResult.self)
    }

    // MARK: - 请求

    private func post(
        _ route: Route,
        payload: [String: PayloadValue],
        as type: SpiderResult.Type
    ) async throws -> SpiderResult {
        guard let url = URL(string: baseURL.absoluteString + route.rawValue) else {
            throw CatVodError.network(status: nil, url: baseURL.absoluteString, reason: "无法拼接路由 \(route.rawValue)")
        }
        let body = try CatSpiderPayload.encode(payload)
        let request = HTTPRequest.json(url: url, body: body, headers: headers, timeout: timeout)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(status: response.status, url: url.absoluteString, reason: "CatSpider 路由 \(route.rawValue) 返回非 200")
        }
        return try CatSpiderResponseDecoder.decode(response.body, as: type, path: route.rawValue)
    }
}
