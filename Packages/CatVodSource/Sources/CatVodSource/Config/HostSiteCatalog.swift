import CatVodCore
import CatVodNet
import Foundation

/// js2p 宿主的站点清单客户端。
///
/// 契约**逐字实测**（Windows + 真 bundle，证据见 `docs/任务记录/M16P2-宿主站点清单实测.md`）：
///
/// | 项 | 实测结果 |
/// | --- | --- |
/// | 清单路由 | `GET <base>/full-config`；`GET <base>/config` 返回**同一载荷** |
/// | 清单形状 | `{"video":{"sites":[…]},"read":{…},"comic":{…},"music":{…},"pan":{…},"color":[…]}` |
/// | 站点条数 | 真实环境 85 条（`type` ∈ {3,4}，无 JAR 站点） |
/// | 站点形状（节选） | `{"key":"nodejs_douban","name":"豆瓣\|首页","type":3,"indexs":1}`
/// | | `{"enable":true,"searchable":1,"quickSearch":1,"api":"/spider/douban/3"}` |
/// | `api` 形态 | **相对路径** `/spider/<spiderKey>/<type>`，宿主模式下必须补成全路径 |
/// | 探活 | `GET <base>/health` → `{"ok":true,"name":"CatVodSpiderios"}` |
///
/// 因此宿主编排必须做两件我们以前没写的事：
/// 1. 把相对 `api` 补成 `http://127.0.0.1:<port>/spider/<spiderKey>/<type>`
///    —— 见 ``absoluteAPI(_:baseURL:)``；补全后 `api` 含 `/spider/`，
///    正好满足 `CatSpider.java#matches` 与 ``Site/isCatSpiderHTTP`` 的判定；
/// 2. 过滤 `enable == false` 的站点（宿主已禁用，App 不应展示）。
public struct HostSiteCatalog: Sendable {
    /// 完整配置路由。
    ///
    /// 实测 `/config` 与 `/full-config` 载荷完全一致（同为 19114 字节）；取后者语义更明确。
    public static let configPath = "/full-config"
    /// 探活路由。
    public static let healthPath = "/health"

    private let transport: HTTPTransport
    private let timeout: TimeInterval

    public init(transport: HTTPTransport, timeout: TimeInterval = 30) {
        self.transport = transport
        self.timeout = timeout
    }

    // MARK: - 请求

    /// 就绪后的二次探活。
    ///
    /// 就绪行（`NodeReadiness.readyMarker`）说明 `listen` 成功，这里再确认应用层可用。
    /// 只看 `ok` 字段，不与上游改名耦合；任何异常都按「不可用」处理。
    public func health(baseURL: URL) async -> Bool {
        guard let url = Self.url(path: Self.healthPath, baseURL: baseURL) else {
            return false
        }
        guard let response = try? await transport.send(HTTPRequest(url: url, timeout: timeout)),
              response.isSuccess
        else {
            return false
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body),
              let map = object as? [String: Any]
        else {
            return false
        }
        return map["ok"] as? Bool ?? false
    }

    /// 宿主提供的可用站点（已补全 `api`、已过滤被禁用项）。
    public func sites(baseURL: URL) async throws -> [Site] {
        try await config(baseURL: baseURL).sites
    }

    /// 拉取并归一化宿主完整配置。
    public func config(baseURL: URL) async throws -> HostConfigSnapshot {
        guard let url = Self.url(path: Self.configPath, baseURL: baseURL) else {
            throw CatVodError.config(reason: "宿主地址无法解析：\(baseURL.absoluteString)")
        }
        let response = try await transport.send(HTTPRequest(url: url, timeout: timeout))
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: url.absoluteString,
                reason: "宿主站点清单获取失败"
            )
        }

        let payload: HostConfigPayload
        do {
            payload = try JSONDecoder().decode(HostConfigPayload.self, from: response.body)
        } catch {
            throw CatVodError.config(reason: "宿主配置不是合法 JSON：\(error)")
        }

        let entries = payload.video?.sites ?? []
        let enabled = entries.filter(\.enabled)
        return HostConfigSnapshot(
            sites: enabled.compactMap { makeSite(from: $0, baseURL: baseURL) },
            disabledSiteCount: entries.count - enabled.count
        )
    }

    // MARK: - 归一化

    /// 相对 `api` → 绝对地址。
    ///
    /// 实测形态是 `/spider/douban/3`（含 spider key 与 type 两段）；
    /// 已带 scheme 的地址原样返回，空值返回空串（缺 `api` 的站点由调用方过滤）。
    public static func absoluteAPI(_ api: String, baseURL: URL) -> String {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return trimmed.hasPrefix("/") ? base + trimmed : base + "/" + trimmed
    }

    private func makeSite(from entry: HostSite, baseURL: URL) -> Site? {
        let api = Self.absoluteAPI(entry.api, baseURL: baseURL)
        let key = entry.key.isEmpty ? Self.spiderKey(fromAPI: api) : entry.key
        guard !key.isEmpty, !api.isEmpty else {
            return nil
        }
        return Site(
            key: key,
            name: entry.name.isEmpty ? key : entry.name,
            type: entry.type,
            api: api,
            indexs: entry.indexs,
            searchable: entry.searchable,
            quickSearch: entry.quickSearch
        )
    }

    /// 兜底：站点没给 `key` 时，用 `/spider/<spiderKey>/<type>` 的 `<spiderKey>` 段。
    static func spiderKey(fromAPI api: String) -> String {
        guard let range = api.range(of: "/spider/") else {
            return ""
        }
        let tail = api[range.upperBound...]
        return String(tail.prefix { $0 != "/" && $0 != "?" })
    }

    private static func url(path: String, baseURL: URL) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

/// 宿主完整配置的归一化结果。
public struct HostConfigSnapshot: Sendable, Equatable {
    /// 可用站点：`api` 已补全为绝对地址。
    public var sites: [Site]
    /// 因 `enable == false` 被过滤掉的站点数（用于界面提示，不是错误）。
    public var disabledSiteCount: Int

    public init(sites: [Site], disabledSiteCount: Int) {
        self.sites = sites
        self.disabledSiteCount = disabledSiteCount
    }
}

// MARK: - 解码（仅内部使用）

/// `GET /full-config` 的载荷。
///
/// 只解 `video` 分区：其余分区（`read`/`comic`/`music`/`pan`）实测都是空 `sites`，
/// `color` 是数组（主题色），因此整包不能用「全部字段必填」的结构去解。
private struct HostConfigPayload: Decodable {
    var video: Section?

    struct Section: Decodable {
        var sites: [HostSite]?
    }
}

/// 宿主站点条目。
///
/// 只覆盖宿主**实际发出**的字段（`key`/`name`/`type`/`api`/`indexs`/`enable`/`searchable`/
/// `quickSearch`）；其余字段一律走 ``Site`` 的默认值 —— 宿主不发的字段不猜。
private struct HostSite: Decodable {
    let key: String
    let name: String
    let type: Int
    let api: String
    let indexs: Int
    let searchable: Int
    let quickSearch: Int
    let enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case key
        case name
        case type
        case api
        case indexs
        case searchable
        case quickSearch
        case enabled = "enable"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.hostString(.key)
        name = container.hostString(.name)
        type = container.hostInt(.type)
        api = container.hostString(.api)
        indexs = container.hostInt(.indexs)
        searchable = container.hostInt(.searchable, default: 1)
        quickSearch = container.hostInt(.quickSearch, default: 1)
        enabled = container.hostBool(.enabled) ?? true
    }
}

/// 宿主载荷的类型噪声容错：上游可能给字符串数字、数字布尔（`1`/`0`）。
private extension KeyedDecodingContainer {
    func hostString(_ key: Key) -> String {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return ""
    }

    func hostInt(_ key: Key, default fallback: Int = 0) -> Int {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key), let value = Int(text) {
            return value
        }
        return fallback
    }

    func hostBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
