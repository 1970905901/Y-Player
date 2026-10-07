import CatVodCore
import CatVodNet
import Foundation

/// 站点 API 地址构造。
///
/// **逐行对齐**参考实现 `app/src/main/java/com/fongmi/android/tv/api/SiteApi.java`：
///
/// - 首页：类型 0/1/2 无参数；类型 4 追加 `filter=true`（api 取 `ext` 指向的远程文本）；
/// - 分类：`ac` + `t=<分类ID>` + `pg=<页码>`；类型 1 追加 `f={json(extend)}`；
///   类型 4 追加 `ext={base64(extend)}`；
/// - 详情：`ac` + `ids=<ID>`；
/// - 搜索：`wd` + `quick` + `extend=""`，`pg` 仅在 `page != 1` 时携带；
/// - `ac` 取值：类型 0 为 `videolist`，其余为 `detail`。
///
/// `ext` 非空时统一追加 `extend` 参数；`ext` 长度 ≤ 1000 用 GET，否则改 POST 表单。
public enum ApiURLBuilder {
    /// `ext` 超过该长度改用 POST（与参考实现一致）。
    public static let maxExtLengthForGET = 1000

    /// 首页请求。
    public static func homeRequest(site: Site, remoteExtAPI: String? = nil) throws -> HTTPRequest {
        var params: [String: String] = [:]
        if site.kind == .httpApiBase64Ext {
            params["filter"] = "true"
        }
        return try makeRequest(site: site, api: remoteExtAPI ?? site.api, params: params)
    }

    /// 分类请求。
    public static func categoryRequest(
        site: Site,
        categoryID: String,
        page: Int,
        extend: [String: String] = [:]
    ) throws -> HTTPRequest {
        var params: [String: String] = [:]
        switch site.kind {
        case .jsonApi:
            if !extend.isEmpty {
                params["f"] = try JSONSupport.string(from: extend)
            }
        case .httpApiBase64Ext:
            params["ext"] = Base64URL.encode(JSONSupport.lenientString(from: extend))
        default:
            break
        }
        params["ac"] = ac(for: site)
        params["t"] = categoryID
        params["pg"] = String(max(page, 1))
        return try makeRequest(site: site, api: site.api, params: params)
    }

    /// 详情请求。
    public static func detailRequest(site: Site, vodID: String) throws -> HTTPRequest {
        try makeRequest(site: site, api: site.api, params: [
            "ac": ac(for: site),
            "ids": vodID,
        ])
    }

    /// 搜索请求。
    ///
    /// 注意 `pg` 仅在 `page != 1` 时携带（参考实现 `hasPage = !page.equals("1")`）。
    public static func searchRequest(
        site: Site,
        keyword: String,
        page: Int,
        quick: Bool
    ) throws -> HTTPRequest {
        var params: [String: String] = [
            "wd": keyword,
            "quick": quick ? "true" : "false",
            "extend": "",
        ]
        if page != 1 {
            params["pg"] = String(page)
        }
        return try makeRequest(site: site, api: site.api, params: params)
    }

    /// 补图请求：列表缺图时按 `ids` 批量补图（仅类型 0/1/2 生效）。
    public static func pictureRequest(site: Site, ids: [String]) throws -> HTTPRequest? {
        guard site.kind != .spider, site.kind != .httpApiBase64Ext, !ids.isEmpty else {
            return nil
        }
        return try makeRequest(site: site, api: site.api, params: [
            "ac": ac(for: site),
            "ids": ids.joined(separator: ","),
        ])
    }

    /// `ac` 取值：类型 0 用 `videolist`，其余用 `detail`。
    public static func ac(for site: Site) -> String {
        site.kind == .xmlApi ? "videolist" : "detail"
    }
}
