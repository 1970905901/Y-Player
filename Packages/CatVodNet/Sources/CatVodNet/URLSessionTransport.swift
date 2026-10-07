import CatVodCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 基于 `URLSession` 的传输实现。
///
/// 职责边界：只负责「把 `HTTPRequest` 发出去并返回 `HTTPResponse`」，
/// 并把配置层的横切规则落在这里：默认 header、按 host 注入 header（`headers[]`）、广告域名拦截（`ads[]`）。
/// DoH / hosts 覆盖 / SOCKS5 代理在 M6 通过自定义 `URLProtocol` 与本地代理服务补上。
public actor URLSessionTransport: HTTPTransport {
    /// 传输层配置。
    public struct Configuration: Sendable {
        /// 未显式指定超时时的默认值（秒）。
        public var defaultTimeout: TimeInterval
        /// 每个请求都会带上的 header。
        public var defaultHeaders: [String: String]
        /// 按 host 注入的 header：`host 匹配规则` → header。
        public var hostHeaders: [String: [String: String]]
        /// 广告域名/正则（上游 `ads`）；命中即拒绝请求。
        public var blockedHosts: [String]

        public init(
            defaultTimeout: TimeInterval = 15,
            defaultHeaders: [String: String] = [:],
            hostHeaders: [String: [String: String]] = [:],
            blockedHosts: [String] = []
        ) {
            self.defaultTimeout = defaultTimeout
            self.defaultHeaders = defaultHeaders
            self.hostHeaders = hostHeaders
            self.blockedHosts = blockedHosts
        }

        /// 默认配置：常见浏览器 UA（部分源对 UA 敏感）。
        public static let `default` = Configuration(
            defaultHeaders: [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            ]
        )

        /// 从配置模型构造（`headers` 与 `ads` 直接映射）。
        public init(config: SourceConfig) {
            var hostHeaders: [String: [String: String]] = [:]
            for rule in config.headers where !rule.host.isEmpty {
                hostHeaders[rule.host] = rule.header
            }
            self.init(
                defaultTimeout: 15,
                defaultHeaders: Configuration.default.defaultHeaders,
                hostHeaders: hostHeaders,
                blockedHosts: config.ads
            )
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(
        configuration: Configuration = .default,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration
        let session = URLSession(configuration: sessionConfiguration)
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = try prepare(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let http = response as? HTTPURLResponse
            let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    result[key] = value
                }
            } ?? [:]
            return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
        } catch let error as CatVodError {
            throw error
        } catch {
            throw CatVodError.network(status: nil, url: urlRequest.url?.absoluteString ?? "", reason: error.localizedDescription)
        }
    }

    /// 把 `HTTPRequest` 归一化为 `URLRequest`：执行广告拦截与 header 合并。
    ///
    /// 声明为 `nonisolated` 便于在测试中直接断言而不必跨 actor 等待。
    nonisolated public func prepare(_ request: HTTPRequest) throws -> URLRequest {
        guard let host = request.url.host, !host.isEmpty else {
            throw CatVodError.network(status: nil, url: request.url.absoluteString, reason: "URL 缺少 host")
        }
        if isBlocked(host: host) {
            throw CatVodError.network(status: nil, url: request.url.absoluteString, reason: "命中广告拦截规则：\(host)")
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout ?? configuration.defaultTimeout

        var headers = configuration.defaultHeaders
        for (pattern, injected) in configuration.hostHeaders where matches(pattern: pattern, host: host) {
            for (key, value) in injected {
                headers[key] = value
            }
        }
        for (key, value) in request.headers {
            headers[key] = value
        }
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }

    /// host 是否命中广告规则：支持精确匹配与 `*.example.com` / `example.com` 后缀匹配。
    nonisolated public func isBlocked(host: String) -> Bool {
        let lowered = host.lowercased()
        for pattern in configuration.blockedHosts {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else {
                continue
            }
            if trimmed == lowered {
                return true
            }
            let suffix = trimmed.hasPrefix("*.") ? String(trimmed.dropFirst(2)) : trimmed
            if lowered.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    /// 规则匹配：精确、后缀（含子域）或 `contains`（上游 host 规则支持包含匹配）。
    nonisolated public func matches(pattern: String, host: String) -> Bool {
        let rule = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowered = host.lowercased()
        guard !rule.isEmpty else {
            return false
        }
        if rule == lowered {
            return true
        }
        if rule.hasPrefix("*.") {
            return lowered.hasSuffix(String(rule.dropFirst(1)))
        }
        return lowered.hasSuffix("." + rule) || lowered.contains(rule)
    }
}
