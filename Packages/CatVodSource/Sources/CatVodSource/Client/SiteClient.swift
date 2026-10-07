import CatVodCore
import CatVodNet
import Foundation

/// 站点客户端门面：按站点类型分发到对应协议实现。
///
/// 为什么需要它：界面不该知道「这个站点是 CMS 还是 CatSpider」。`HomeView`/`SearchView`/详情页
/// 只调 `home/category/search/detail`，由这里按 `Site.kind` 与平台可用性挑实现：
///
/// | 站点 | 判定 | 实现 |
/// | --- | --- | --- |
/// | `type 0/1/2/4` | `kind != .spider` | ``CMSClient``（GET/JSON/XML） |
/// | `type 3` + `api` 含 `/spider/` | `Site/isCatSpiderHTTP` | ``CatSpiderHTTPClient``（js2p 宿主站点） |
/// | `type 3` + 其它 | JAR / Python / 未知 | 直接抛 ``CatVodError/unsupported(feature:reason:)``，**不发请求** |
///
/// 不可用原因直接复用 `Site.availability`，保证门面、界面、日志三处口径一致。
public struct SiteClient: Sendable {
    public var transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 分发结果。
    public enum Resolved: Sendable {
        case cms(CMSClient)
        case catSpider(CatSpiderHTTPClient)
    }

    /// 解析该站点该用哪个客户端；不可用时抛 ``CatVodError/unsupported(feature:reason:)``。
    public func resolve(_ site: Site) throws -> Resolved {
        if site.kind == .spider {
            guard site.isCatSpiderHTTP, let client = CatSpiderHTTPClient(site: site, transport: transport) else {
                throw CatVodError.unsupported(feature: "spider", reason: Self.spiderReason(site))
            }
            return .catSpider(client)
        }
        return .cms(CMSClient(transport: transport))
    }

    // MARK: - 统一入口

    /// 首页（含分类与推荐）。
    public func home(site: Site) async throws -> SpiderResult {
        switch try resolve(site) {
        case let .cms(client):
            return try await client.home(site: site)
        case let .catSpider(client):
            return try await client.home()
        }
    }

    /// 分类翻页（`extend` 是站点筛选项）。
    public func category(
        site: Site,
        categoryID: String,
        page: Int,
        extend: [String: String] = [:]
    ) async throws -> SpiderResult {
        switch try resolve(site) {
        case let .cms(client):
            return try await client.category(site: site, categoryID: categoryID, page: page, extend: extend)
        case let .catSpider(client):
            return try await client.category(id: categoryID, page: page, filters: extend)
        }
    }

    /// 详情（返回线路与选集）。
    public func detail(site: Site, vodID: String) async throws -> SpiderResult {
        switch try resolve(site) {
        case let .cms(client):
            return try await client.detail(site: site, vodID: vodID)
        case let .catSpider(client):
            return try await client.detail(id: vodID)
        }
    }

    /// 搜索。
    public func search(
        site: Site,
        keyword: String,
        page: Int = 1,
        quick: Bool = true
    ) async throws -> SpiderResult {
        switch try resolve(site) {
        case let .cms(client):
            return try await client.search(site: site, keyword: keyword, page: page, quick: quick)
        case let .catSpider(client):
            return try await client.search(keyword: keyword, page: page)
        }
    }

    /// 播放地址。
    ///
    /// - CatSpider 站点：`POST /play`（`flag` + `id`）；
    /// - CMS 站点：播放地址来自详情里的线路/选集，没有独立 play 接口 → 明确抛不支持，
    ///   避免界面误以为「调用失败」。
    public func play(site: Site, flag: String, id: String) async throws -> SpiderResult {
        switch try resolve(site) {
        case .cms:
            throw CatVodError.unsupported(
                feature: "play",
                reason: "CMS 站点的播放地址来自详情的线路/选集，不需要单独的 play 接口"
            )
        case let .catSpider(client):
            return try await client.play(flag: flag, id: id)
        }
    }

    // MARK: - 原因文案

    /// Spider 站点不可用的原因。
    ///
    /// 口径与 `Site.availability` 一致；这里额外覆盖「`type 3` 但 api 不含 `/spider/`」
    /// 这种 `availability` 判为可用、实际却无法按 CatSpider 协议调用的情形。
    static func spiderReason(_ site: Site) -> String {
        switch site.spiderRuntimeKind {
        case .catSpiderHTTP:
            return "站点 api 不含 /spider/，无法按 CatSpider HTTP 协议调用：\(site.api)"
        default:
            return site.availability.reason ?? "站点不可用：\(site.api)"
        }
    }
}
