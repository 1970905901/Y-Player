import CatVodCore
import CatVodNet
import Foundation

/// JSON/XML CMS 站点客户端（`type=0/1/2/4`）。
///
/// 请求构造全部走 ``ApiURLBuilder``（逐行对齐 `SiteApi.java`），响应按类型解析：
/// - `type=0`：XML → ``VodXMLParser``；
/// - `type=1/2`：JSON → ``SpiderResult``；
/// - `type=3`：交给 `CatSpiderHTTPClient`/JS 运行时，不在本类型范围内（会抛 `unsupported`）；
/// - `type=4`：与 JSON 同构（`fetchExt` 的远程文本由调用方预先注入 `remoteExtAPI`）。
public struct CMSClient: Sendable {
    public var transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 首页（含分类与推荐）。
    public func home(site: Site, remoteExtAPI: String? = nil) async throws -> SpiderResult {
        try await perform(ApiURLBuilder.homeRequest(site: site, remoteExtAPI: remoteExtAPI), site: site, path: "/home")
    }

    /// 分类翻页（`extend` 为筛选项，类型 1 用 `f`、类型 4 用 base64 `ext`）。
    public func category(
        site: Site,
        categoryID: String,
        page: Int,
        extend: [String: String] = [:]
    ) async throws -> SpiderResult {
        try await perform(
            ApiURLBuilder.categoryRequest(site: site, categoryID: categoryID, page: page, extend: extend),
            site: site,
            path: "/category"
        )
    }

    /// 详情（返回线路与选集）。
    public func detail(site: Site, vodID: String) async throws -> SpiderResult {
        try await perform(ApiURLBuilder.detailRequest(site: site, vodID: vodID), site: site, path: "/detail")
    }

    /// 搜索。
    public func search(site: Site, keyword: String, page: Int = 1, quick: Bool = true) async throws -> SpiderResult {
        try await perform(
            ApiURLBuilder.searchRequest(site: site, keyword: keyword, page: page, quick: quick),
            site: site,
            path: "/search"
        )
    }

    /// 补图：列表缺图时按 `ids` 批量拉取（仅类型 0/1/2，失败时返回原结果）。
    public func fillingPictures(site: Site, result: SpiderResult) async throws -> SpiderResult {
        guard let request = try ApiURLBuilder.pictureRequest(site: site, ids: result.list.map(\.vodID)) else {
            return result
        }
        let enriched = try await perform(request, site: site, path: "/picture")
        guard !enriched.list.isEmpty else {
            return result
        }
        var merged = result
        merged.list = enriched.list
        return merged
    }

    // MARK: - 执行与解析

    private func perform(_ request: HTTPRequest, site: Site, path: String) async throws -> SpiderResult {
        switch site.kind {
        case .xmlApi, .jsonApi, .jsonApiCompat, .httpApiBase64Ext:
            break
        default:
            throw CatVodError.unsupported(
                feature: "CMSClient",
                reason: "站点 \(site.key) 的类型 \(site.type) 不走 CMS HTTP 通道"
            )
        }

        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(status: response.status, url: request.url.absoluteString, reason: "站点 \(site.key) 返回非 2xx")
        }
        guard !response.body.isEmpty else {
            // 部分源在无数据时返回空体：按协议给空结果而不是报错。
            return .empty(page: 1)
        }

        if site.kind == .xmlApi {
            guard let parsed = VodXMLParser.parse(data: response.body) else {
                throw CatVodError.decoding(path: "\(site.key)\(path)", reason: "XML 解析失败")
            }
            return parsed
        }

        do {
            return try JSONDecoder().decode(SpiderResult.self, from: response.body)
        } catch {
            throw CatVodError.decoding(path: "\(site.key)\(path)", reason: "JSON 不符合 SpiderResult 协议：\(error)")
        }
    }
}
