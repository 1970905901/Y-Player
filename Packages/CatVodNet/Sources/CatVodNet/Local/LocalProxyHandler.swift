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
/// | `/m3u8` | HLS 清单改写 + 分片/密钥原样转发（上游 `server/process/M3u8.java`） |
/// | `/health` | 就绪探测（设置页与自检用） |
/// | `/` | 服务标识 |
/// | 其它 | 404（抛 ``HTTPUnhandledError``，由 FlyingFox 统一转 404） |
///
/// ⚠️ 命名注意：FlyingFox 也有 `HTTPRequest`/`HTTPResponse`，与本包 `HTTPTransport.swift`
/// 里的同名类型冲突。本模块内的裸名会解析成**本包**的类型，因此服务端代码一律显式写
/// `FlyingFox.HTTPRequest` / `FlyingFox.HTTPResponse`（CI 抓过这个错）。
public struct LocalProxyHandler: HTTPHandler {
    /// 路由分类。
    public enum Route: Sendable, Equatable {
        case root
        case health
        case proxy
        case m3u8
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
        if path.hasPrefix("/m3u8") {
            return .m3u8
        }
        if path.hasPrefix("/health") {
            return .health
        }
        if path == "/" || path.isEmpty {
            return .root
        }
        return nil
    }

    public func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> FlyingFox.HTTPResponse {
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
        case .m3u8:
            return await servePlaylist(request)
        }
    }

    /// `/proxy`：解析 → 取回 → 过滤响应 header → 回给客户端。
    private func forward(_ request: FlyingFox.HTTPRequest) async -> FlyingFox.HTTPResponse {
        do {
            guard let plan = try await LocalProxyRequestDecoder.decode(request, defaultTimeout: timeout) else {
                return Self.errorResponse(status: .badRequest, reason: "缺少或无法解析 url 参数")
            }
            let response = try await upstream.fetch(plan)
            let responseHeaders = ProxyForwardingPolicy.clientResponseHeaders(upstream: response.headers)
            let body = request.method == .HEAD ? Data() : response.body
            return FlyingFox.HTTPResponse(
                statusCode: Self.statusCode(response.status),
                headers: Self.makeHeaders(responseHeaders),
                body: body
            )
        } catch let error as CatVodError {
            return Self.errorResponse(status: .badGateway, reason: error.errorDescription ?? "转发失败")
        } catch {
            return Self.errorResponse(status: .badGateway, reason: error.localizedDescription)
        }
    }

    // MARK: - /m3u8（HLS 清单改写）

    /// `/m3u8`：取上游 → **是清单就改写**（子清单/分片/`URI="…"` 全部指回本机），否则原样转发。
    ///
    /// 对照上游 `server/process/M3u8.java`：为「直播源/解析器里写死 `127.0.0.1:<port>/m3u8?url=…`」
    /// 这类写法兜底 —— 写死了本机地址时，本机必须真的能应答，并且把链路上的地址继续指向自己。
    ///
    /// 与上游的两处有意差别：
    /// - 代理地址用**客户端连过来的 Host**（端口是扫出来的，不能硬编码 9978）；
    /// - 把播放器带来的 `h`（注入 header）继续带到子清单/分片上 —— 上游那条路用的是写死的 UA/Referer，
    ///   而我们的 header 来自站点配置，逐跳丢失会导致分片 403。
    private func servePlaylist(_ request: FlyingFox.HTTPRequest) async -> FlyingFox.HTTPResponse {
        do {
            guard let plan = try await LocalProxyRequestDecoder.decode(request, defaultTimeout: timeout) else {
                return Self.errorResponse(status: .badRequest, reason: "缺少或无法解析 url 参数")
            }
            let response = try await upstream.fetch(plan)
            let target = plan.url.absoluteString
            let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            let text = String(data: response.body, encoding: .utf8) ?? ""
            guard response.status == 200,
                  HLSPlaylistRewriter.isPlaylist(url: target, contentType: contentType),
                  HLSPlaylistRewriter.looksLikePlaylist(text)
            else {
                // 分片 / 密钥 / 上游错误：原样回（播放器应当看到真实状态码与内容）。
                return passthrough(response, request: request)
            }
            let rewritten = HLSPlaylistRewriter.rewrite(text, baseURL: target) { nested in
                Self.childURL(nested, authority: Self.authority(from: request), injectedHeaders: request.query["h"] ?? "")
            }
            return Self.playlistResponse(response, body: rewritten)
        } catch let error as CatVodError {
            return Self.errorResponse(status: .badGateway, reason: error.errorDescription ?? "取上游清单失败")
        } catch {
            return Self.errorResponse(status: .badGateway, reason: error.localizedDescription)
        }
    }

    /// 非清单响应的转发（状态码与 header 照搬，`HEAD` 不带体）。
    private func passthrough(
        _ response: LocalProxyUpstreamClient.Response,
        request: FlyingFox.HTTPRequest
    ) -> FlyingFox.HTTPResponse {
        let responseHeaders = ProxyForwardingPolicy.clientResponseHeaders(upstream: response.headers)
        let body = request.method == .HEAD ? Data() : response.body
        return FlyingFox.HTTPResponse(
            statusCode: Self.statusCode(response.status),
            headers: Self.makeHeaders(responseHeaders),
            body: body
        )
    }

    /// 改写后的清单响应。
    ///
    /// 三件必须做的事：正文是重新拼的，所以要**重算 `Content-Length`**、**去掉 `Content-Encoding`**
    /// （上游的 gzip 已被 URLSession 解掉，留着会让播放器按压缩体解析），并且**不许缓存**
    /// （清单里有实时地址，缓存住会播到过期分片）。
    static func playlistResponse(
        _ response: LocalProxyUpstreamClient.Response,
        body: String
    ) -> FlyingFox.HTTPResponse {
        var headers = ProxyForwardingPolicy.clientResponseHeaders(upstream: response.headers)
        headers["Content-Type"] = "application/vnd.apple.mpegurl; charset=utf-8"
        headers["Content-Length"] = String(body.utf8.count)
        headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
        headers["Pragma"] = "no-cache"
        remove(&headers, named: "Content-Encoding")
        remove(&headers, named: "Transfer-Encoding")
        return FlyingFox.HTTPResponse(
            statusCode: statusCode(response.status),
            headers: makeHeaders(headers),
            body: Data(body.utf8)
        )
    }

    /// 子清单 / 分片的代理地址：指回**同一个**本机服务（`/m3u8` 才能在下一层继续改写）。
    static func childURL(_ target: String, authority: String, injectedHeaders: String) -> String {
        var url = "http://\(authority)/m3u8?url=\(percentEncoded(target))"
        if !injectedHeaders.isEmpty {
            url += "&h=" + injectedHeaders
        }
        return url
    }

    /// 客户端连过来的 authority（`Host` 头）；取不到时退回回环地址。
    static func authority(from request: FlyingFox.HTTPRequest) -> String {
        let host = request.headers[.host] ?? ""
        return host.isEmpty ? "127.0.0.1" : host
    }

    /// query 值编码：只保留 RFC 3986 的非保留字符，避免 `&`/`=`/`+` 破坏另一个参数。
    static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// header 名大小写不敏感地删除（先取键再删，避免边遍历边改字典）。
    static func remove(_ headers: inout [String: String], named name: String) {
        for key in headers.keys.filter({ $0.lowercased() == name.lowercased() }) {
            headers.removeValue(forKey: key)
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

    static func makeHeaders(_ values: [String: String]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in values {
            headers[HTTPHeader(key)] = value
        }
        return headers
    }

    static func textResponse(status: HTTPStatusCode, body: String) -> FlyingFox.HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain; charset=utf-8"
        for (key, value) in ProxyForwardingPolicy.corsResponseHeaders {
            headers[HTTPHeader(key)] = value
        }
        return FlyingFox.HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
    }

    static func errorResponse(status: HTTPStatusCode, reason: String) -> FlyingFox.HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "application/json; charset=utf-8"
        for (key, value) in ProxyForwardingPolicy.corsResponseHeaders {
            headers[HTTPHeader(key)] = value
        }
        let payload = ["error": reason]
        let body = (try? JSONEncoder().encode(payload)) ?? Data()
        return FlyingFox.HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    static func emptyResponse(status: HTTPStatusCode) -> FlyingFox.HTTPResponse {
        var headers = HTTPHeaders()
        for (key, value) in ProxyForwardingPolicy.corsResponseHeaders {
            headers[HTTPHeader(key)] = value
        }
        return FlyingFox.HTTPResponse(statusCode: status, headers: headers)
    }
}
