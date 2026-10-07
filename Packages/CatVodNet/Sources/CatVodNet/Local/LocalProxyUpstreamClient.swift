import CatVodCore
import Foundation

/// 本地代理的上游取回器。
///
/// 只做三件事：转发（走既有 ``HTTPTransport``，从而自动获得默认 UA、`headers[]` 注入与 `ads[]` 拦截）、
/// 体积保护、把失败统一成 ``CatVodCore/CatVodError``。
///
/// 体积保护的意义：本轮实现是**缓冲式**转发（一次把上游响应读进内存），
/// HLS 分片/密钥/清单都在几 MB 以内，没问题；但超大文件会撑爆内存，
/// 因此超过上限时明确报错而不是静默截断（流式转发与临时文件落地见 M6b）。
public actor LocalProxyUpstreamClient {
    /// 上游响应。
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    private let transport: any HTTPTransport
    /// 单次响应体上限（字节）。
    public let maximumBodyBytes: Int

    public init(transport: any HTTPTransport, maximumBodyBytes: Int = 32 * 1024 * 1024) {
        self.transport = transport
        self.maximumBodyBytes = maximumBodyBytes
    }

    /// 取回一次上游响应。
    public func fetch(_ request: LocalProxyForwardRequest) async throws -> Response {
        let upstream = HTTPRequest(
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: request.body,
            timeout: request.timeout
        )
        let response = try await transport.send(upstream)
        guard response.body.count <= maximumBodyBytes else {
            throw CatVodError.localServer(
                reason: "上游响应 \(response.body.count) 字节超过本地代理上限 \(maximumBodyBytes) 字节：\(request.url.absoluteString)"
            )
        }
        return Response(status: response.status, headers: response.headers, body: response.body)
    }
}
