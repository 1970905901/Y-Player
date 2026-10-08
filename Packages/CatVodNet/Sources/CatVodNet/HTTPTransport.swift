import Foundation

/// 统一的 HTTP 传输抽象。
///
/// 设计要点：`CatVodNet` 只负责「发请求」，不关心站点语义；
/// 因此所有运行时（JSON/XML CMS、CatSpider HTTP、js2p 本地服务、JS `req()`）共用这一层，
/// header/cookie/代理/广告拦截等横切能力都在具体实现里统一处理。
///
/// ⚠️ `DoH` 与 `hosts` 覆盖**不在这条链上**：它们是平台缺口，不是还没接的线 ——
/// 见 `URLSessionTransport` 的说明与 `docs/任务记录/M06m-DNS方案与决策.md`。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 请求描述。
public struct HTTPRequest: Sendable, Hashable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case head = "HEAD"
    }

    public var url: URL
    public var method: Method
    /// 请求 header；同名 header 由上层（站点/结果/解析器）合并后传入。
    public var headers: [String: String]
    /// 原始请求体（POST 用）。
    public var body: Data?
    /// 超时秒数；`nil` 表示使用传输层默认值。
    public var timeout: TimeInterval?

    public init(
        url: URL,
        method: Method = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// JSON 请求体便捷构造。
    public static func json(
        url: URL,
        body: Data,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) -> HTTPRequest {
        var merged = headers
        merged["Content-Type"] = "application/json; charset=utf-8"
        return HTTPRequest(url: url, method: .post, headers: merged, body: body, timeout: timeout)
    }
}

/// 响应描述。
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// 是否 2xx。
    public var isSuccess: Bool {
        (200 ..< 300).contains(status)
    }

    /// 按 UTF-8 解码文本体；失败时回退到 Latin-1（部分老站点不是 UTF-8）。
    public var text: String {
        String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? ""
    }
}

/// 请求 header 合并工具：站点 header → 结果 header → 解析器 header，后者覆盖前者。
public enum HTTPHeaderMerger {
    public static func merge(_ sources: [[String: String]]) -> [String: String] {
        var result: [String: String] = [:]
        for source in sources {
            for (key, value) in source {
                result[key] = value
            }
        }
        return result
    }
}
