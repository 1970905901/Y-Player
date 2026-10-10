import CatVodCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 基于 `URLSession` 的传输实现。
///
/// 职责边界：只负责「把 `HTTPRequest` 发出去并返回 `HTTPResponse`」，
/// 并把配置层的横切规则落在这里：默认 header、按 host 注入 header（`headers[]`）、广告域名拦截（`ads[]`）。
///
/// ⚠️ 已知平台缺口：`URLSession` **没有可用的 DNS 钩子**，所以配置里的 `hosts` 覆盖与 `doh`
/// **在本实现下不生效**（上游靠 OkHttp 的 `Dns` 接口做到，Apple 侧没有对应物）。
/// 这两项会在「接口管理 → 告警」里如实报给用户（见 `ConfigCoverage`），
/// 而不是静默忽略。真正要支持，得自建连接层（`Network.framework` + 按主机名校验证书），
/// 方案与代价见 `docs/任务记录/M06m-DNS方案与决策.md`。
public actor URLSessionTransport: HTTPDownloadingTransport, HTTPStreamingTransport {
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
        /// 按 host 选代理；返回 `nil` = 直连（默认）。
        ///
        /// 代理是**会话级**的（`URLSessionConfiguration.connectionProxyDictionary` 建完就不能改），
        /// 而选哪条代理取决于目标 host，所以这里给的是「问一次」的闭包，由传输层按端点缓存会话，见 ``URLSessionTransport``。
        public var proxyResolver: ProxyResolver?

        /// 按 host 选代理（`Core` 的 ``ProxyRuleResolver/selection(forHost:)`` 外面包一层即可）。
        public typealias ProxyResolver = @Sendable (_ host: String) -> ProxyEndpoint?

        public init(
            defaultTimeout: TimeInterval = 15,
            defaultHeaders: [String: String] = [:],
            hostHeaders: [String: [String: String]] = [:],
            blockedHosts: [String] = [],
            proxyResolver: ProxyResolver? = nil
        ) {
            self.defaultTimeout = defaultTimeout
            self.defaultHeaders = defaultHeaders
            self.hostHeaders = hostHeaders
            self.blockedHosts = blockedHosts
            self.proxyResolver = proxyResolver
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
    /// 建代理会话时的模板（直连会话也由它来，保证两边行为一致：超时、cookie 策略、缓存策略）。
    private let baseSessionConfiguration: URLSessionConfiguration
    private let directSession: URLSession
    /// 代理会话池：**按端点**缓存（同一个代理只建一次会话）。
    private var proxiedSessions: [ProxyEndpoint: URLSession] = [:]

    public init(
        configuration: Configuration = .default,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration
        baseSessionConfiguration = sessionConfiguration
        directSession = URLSession(configuration: sessionConfiguration)
    }

    /// 取这次请求该用的会话：按 host 问一次代理，命中就复用 / 新建对应的代理会话。
    ///
    /// 为什么要有池：代理只能建会话时指定，而选哪条代理是按 host 的 —— 没有池的话，
    /// 每个请求都要新建一个 `URLSession`（连接、cookie 策略、内存全部重建），代价很大。
    private func session(for url: URL) -> URLSession {
        guard let endpoint = proxyEndpoint(for: url) else {
            return directSession
        }
        if let existing = proxiedSessions[endpoint] {
            return existing
        }
        let sessionConfiguration = (baseSessionConfiguration.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = endpoint.connectionProxyDictionary
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: ProxyAuthDelegate(endpoint: endpoint),
            delegateQueue: nil
        )
        proxiedSessions[endpoint] = session
        return session
    }

    /// 问一次代理选择器（没有配置 / host 解析不出来都当直连）。
    private func proxyEndpoint(for url: URL) -> ProxyEndpoint? {
        guard let resolver = configuration.proxyResolver, let host = url.host, !host.isEmpty else {
            return nil
        }
        return resolver(host)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = try prepare(request)
        let session = session(for: urlRequest.url ?? request.url)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return HTTPResponse(status: httpStatus(response), headers: headers(from: response), body: data)
        } catch let error as CatVodError {
            throw error
        } catch {
            throw CatVodError.network(status: nil, url: urlRequest.url?.absoluteString ?? "", reason: error.localizedDescription)
        }
    }

    /// 大响应**落盘**取回（M06b 的流式转发）：`URLSession.download` 由系统把响应体写进临时文件，
    /// 内存里不堆整份；广告拦截与 header 注入跟 ``send(_:)`` 共用 ``prepare(_:)``，规则只有一处。
    public func download(_ request: HTTPRequest, to fileURL: URL) async throws -> HTTPDownloadedResponse {
        let urlRequest = try prepare(request)
        let session = session(for: urlRequest.url ?? request.url)
        do {
            let (temporaryURL, response) = try await session.download(for: urlRequest)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            return HTTPDownloadedResponse(
                status: httpStatus(response),
                headers: headers(from: response),
                fileURL: fileURL,
                byteCount: (attributes?[.size] as? NSNumber)?.intValue ?? 0
            )
        } catch let error as CatVodError {
            throw error
        } catch {
            throw CatVodError.network(status: nil, url: urlRequest.url?.absoluteString ?? "", reason: error.localizedDescription)
        }
    }

    /// 流式取回（M25P2）：`URLSession.bytes(for:)` 逐字节读、攒够 64KB 交一块。
    ///
    /// 为什么自己攒块而不是直接吐 `AsyncBytes`：直链下载要的是「块」（每块写一次盘、
    /// 报一次进度），`AsyncBytes` 的粒度是字节 —— 攒块的循环比逐字节交给上层省一堆调用。
    /// （`bytes(for:)` 的逐字节迭代在内存里是缓冲弹出的循环，不是每字节一次挂起。）
    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let urlRequest = try prepare(request)
        let session = session(for: urlRequest.url ?? request.url)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            let pump = StreamPump()
            return HTTPStream(
                status: httpStatus(response),
                headers: headers(from: response),
                chunks: pump.makeChunks(bytes: bytes),
                cancel: { pump.cancel() }
            )
        } catch let error as CatVodError {
            throw error
        } catch {
            throw CatVodError.network(status: nil, url: urlRequest.url?.absoluteString ?? "", reason: error.localizedDescription)
        }
    }

    private func httpStatus(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// 响应 header（`URLSession` 给的是 `[AnyHashable: Any]`，只留字符串对）。
    private func headers(from response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        return http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
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

/// 把 `AsyncBytes` 攒成 64KB 的块、并留一个「取消」把手（M25P2）。
///
/// 单独一个类是因为 `AsyncThrowingStream` 没有「停止生产」的接口，而下载器暂停 /
/// 放弃剩余时必须能把生产停掉 —— 否则取消之后生产者还会往无界缓冲里灌数据。
private final class StreamPump: @unchecked Sendable {
    private static let chunkBytes = 64 * 1024
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func makeChunks(bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    var buffer = Data(capacity: Self.chunkBytes)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= Self.chunkBytes {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            lock.lock()
            self.task = task
            lock.unlock()
            // 消费端提前停下（流被释放 / 被放弃）：把生产也停掉。
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    /// 取消生产：取消迭代任务 —— `AsyncBytes` 会随之收尾，`chunks` 以错误结束。
    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
