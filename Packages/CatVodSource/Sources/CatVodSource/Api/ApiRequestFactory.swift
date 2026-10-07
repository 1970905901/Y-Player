import CatVodCore
import CatVodNet
import Foundation

// 请求组装细节：与 ApiURLBuilder 同属一个职责，拆文件只为控制单文件体积。
extension ApiURLBuilder {
    /// `ext` 归一化为字符串：对象转 JSON、字符串原样、空值返回空串。
    static func extString(_ ext: AnyJSONValue) -> String {
        switch ext {
        case .null:
            return ""
        case .string(let value):
            return value
        default:
            return JSONSupport.lenientString(from: ext)
        }
    }

    static func makeRequest(
        site: Site,
        api: String,
        params: [String: String]
    ) throws -> HTTPRequest {
        var finalParams = params
        let extText = extString(site.ext)
        if !extText.isEmpty {
            finalParams["extend"] = extText
        }

        guard let baseURL = URL(string: api), baseURL.scheme != nil else {
            throw CatVodError.config(reason: "站点 \(site.key) 的 api 不是合法地址：\(api)")
        }

        // 参数顺序稳定，便于排查与测试。
        let orderedKeys = finalParams.keys.sorted()
        let usePOST = extText.count > maxExtLengthForGET
        return usePOST
            ? try postRequest(url: baseURL, keys: orderedKeys, params: finalParams, site: site)
            : try getRequest(url: baseURL, keys: orderedKeys, params: finalParams, site: site)
    }

    static func getRequest(
        url: URL,
        keys: [String],
        params: [String: String],
        site: Site
    ) throws -> HTTPRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CatVodError.config(reason: "无法解析 api 地址：\(url.absoluteString)")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: keys.map { URLQueryItem(name: $0, value: params[$0]) })
        components.queryItems = items
        guard let finalURL = components.url else {
            throw CatVodError.config(reason: "无法构造请求地址：\(url.absoluteString)")
        }
        return HTTPRequest(
            url: finalURL,
            method: .get,
            headers: site.header,
            timeout: TimeInterval(site.timeout)
        )
    }

    static func postRequest(
        url: URL,
        keys: [String],
        params: [String: String],
        site: Site
    ) throws -> HTTPRequest {
        var form = URLComponents()
        form.queryItems = keys.map { URLQueryItem(name: $0, value: params[$0]) }
        var merged = site.header
        merged["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
        return HTTPRequest(
            url: url,
            method: .post,
            headers: merged,
            body: Data((form.percentEncodedQuery ?? "").utf8),
            timeout: TimeInterval(site.timeout)
        )
    }
}
