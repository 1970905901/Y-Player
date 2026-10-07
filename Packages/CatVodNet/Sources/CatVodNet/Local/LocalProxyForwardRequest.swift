import CatVodCore
import Foundation

/// 本地代理要转发的一次上游请求。
public struct LocalProxyForwardRequest: Sendable, Hashable {
    /// 目标地址。
    public var url: URL
    /// 转发用的 HTTP 方法。
    public var method: HTTPRequest.Method
    /// 已经过 ``ProxyForwardingPolicy`` 过滤/合并的 header。
    public var headers: [String: String]
    /// 上游请求体（本地 `POST /proxy?url=…` 时透传）。
    public var body: Data?
    /// 超时秒数。
    public var timeout: TimeInterval?

    public init(
        url: URL,
        method: HTTPRequest.Method = .get,
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
}
