import CatVodCore
import FlyingFox
import Foundation

/// 本地服务的根处理器。
///
/// 路由模型对照上游 `server/impl/Process` + `Nano`：**按路径前缀分流**，而不是逐条注册路由
/// （上游 `Proxy.isRequest` 就是 `url.startsWith("/proxy")`），这样 `/proxy/…` 这类带子路径的写法也能命中。
///
/// | 路由 | 说明 |
/// | --- | --- |
/// | `/proxy` | 转发目标地址并注入 header；支持 `GET`/`HEAD`/`POST` 与 `OPTIONS` 预检 |
/// | `/health` | 就绪探测（设置页与自检用） |
/// | `/` | 服务标识 |
/// | 其它 | 404（抛 ``HTTPUnhandledError``，由 FlyingFox 统一转 404） |
public struct LocalProxyHandler: HTTPHandler {
    /// 路由分类。
    public enum Route: Sendable, Equatable {
        case root
        case health
        case proxy
    }

    private let upstream: LocalProxyUpstreamClient
    private let timeout: TimeInterval

    public init(upstream: LocalProxyUpstreamClient, timeout: TimeInterval = 30) {
        self.upstream = upstream
        self.timeout = timeout
    }

    /// 路径 → 路由；nil 表示本服务不处理。
    public static func route(forPath path: String) -> Route? {
        if path.hasPrefix("/proxy") {
            return .proxy
        }
        if path.hasPrefix("/health") {
            return .health
        }
        if path == "/" || path.isEmpty {
            return .root
        }
        return nil
    }

    public func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let route = Self.route(forPath: request.path) else {
            throw HTTPUnhandledError()
        }
        if request.method == .OPTIONS {
            return Self.emptyResponse(status: .noContent)
        }
        switch route {
        case .root:
            return Self.textResponse(status: .ok, body: "YPlayer local service")
        case .health:
            return Self.textResponse(status: .ok, body: "ok")
        case .proxy:
            return await forward(request)
        }
    }

    /// `/proxy`：解析 → 取回 → 过滤响应 header → 回给客户端。
    private func forward(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let forward = try await LocalProxyRequestDecoder.decode(request, defaultTimeout: timeout) else {
                return Self.errorResponse(status: .badRequest, reason: "缺少或无法解析 url 参数")
            }
            let response = try await upstream.fetch(forward)
            let headers = ProxyForwardingPolicy.clientResponseHeaders(upstream: response.headers)
            let body = request.method == .HEAD ? Data() : response.body
            return HTTPResponse(
                statusCode: Self.statusCode(response.status),
                headers: Self.headers(headers),
                body: body
            )
        } catch let error as CatVodError {
            return Self.errorResponse(status: .badGateway, reason: error.errorDescription ?? "转发失败")
        } catch {
            return Self.errorResponse(status: .badGateway, reason: error.localizedDescription)
        }
    }

    /// 常见状态码映射；未知状态码照样透传（状态行短语用占位词）。
    static func statusCode(_ value: Int) -> HTTPStatusCode {
        let known: [Int: HTTPStatusCode] = [
            200: .ok,
            206: .partialContent,
            301: .movedPermanently,
            302: .found,
            304: .notModified,
            400: .badRequest,
            401: .unauthorized,
            403: .forbidden,
            404: .notFound,
            405: .methodNotAllowed,
            416: .rangeNotSatisfiable,
            500: .internalServerError,
            502: .badGateway,
            504: .gatewayTimeout,
        ]
        return known[value] ?? HTTPStatusCode(value, phrase: "Proxy Response")
    }

    static func headers(_ values: [String: String]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in values {
            headers[HTTPHeader(key)] = value
        }
        return headers
    }

    static func textResponse(status: HTTPStatusCode, body: String) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain; charset=utf-8"
        for (key, value) in ProxyForwardingPolicy.corsResponseHeaders {
            headers[HTTPHeader(key)] = value
        }
        return HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
    }

    static func errorResponse(status: HTTPStatusCode, reason: String) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "application/json; charset=utf-8"
        for (key, value) in ProxyForwardingPolicy.corsResponseHeaders {
            headers[HTTPHeader(key)] = value
        }
        let payload = ["error": reason]
        let body = (try? JSONEncoder().encode(payload)) ?? Data()
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    static func emptyResponse(status: HTTPStatusCode) -> HTTPResponse {
        var headers = HTTPHeaders()
        for (key, value) in ProxyForwardingPolicy.corsResponseHeaders {
            headers[HTTPHeader(key)] = value
        }
        return HTTPResponse(statusCode: status, headers: headers)
    }
}
