import CatVodCore
import CatVodNet
import Foundation

// 供 PlayRequestBuilder 复用的请求组装入口（与 ApiURLBuilder 共用 ext/extend 规则）。
extension ApiURLBuilder {
    /// 以给定参数构造请求（用于类型 4 的播放路由）。
    static func makeRequestForPlay(site: Site, params: [String: String]) throws -> HTTPRequest {
        try makeRequest(site: site, api: site.api, params: params)
    }
}
