import CatVodCore
import Foundation

/// 本地代理的上游取回器。
///
/// 只做三件事：转发（走既有 ``HTTPTransport``，从而自动获得默认 UA、`headers[]` 注入与 `ads[]` 拦截）、
/// 体积保护、把失败统一成 ``CatVodCore/CatVodError``。
///
/// 两条出口（M06b）：
/// - ``fetch(_:)``：**缓冲式**（一次把上游响应读进内存）—— `/m3u8` 的清单 / 分片 / 密钥走它，
///   超过 `maximumBodyBytes` 明确报错而不是静默截断；
/// - ``fetchToFile(_:fileURL:)``：**落盘式**（`/proxy` 的媒体路径）—— 几十 GB 的文件不再撞上限，
///   响应体直接进临时文件，再由本机服务流给播放器。
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

    /// 落盘版响应（`/proxy` 的媒体路径用；M06b 的流式转发）。
    public struct FileResponse: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var fileURL: URL
        /// 实际写盘字节数。
        public var byteCount: Int

        public init(status: Int, headers: [String: String] = [:], fileURL: URL, byteCount: Int) {
            self.status = status
            self.headers = headers
            self.fileURL = fileURL
            self.byteCount = byteCount
        }
    }

    private let transport: any HTTPTransport
    /// 单次响应体上限（字节）。
    public let maximumBodyBytes: Int

    public init(transport: any HTTPTransport, maximumBodyBytes: Int = 32 * 1024 * 1024) {
        self.transport = transport
        self.maximumBodyBytes = maximumBodyBytes
    }

    /// 取回一次上游响应（**缓冲式**；`/m3u8` 与不支持落盘的传输实现走它）。
    public func fetch(_ request: LocalProxyForwardRequest) async throws -> Response {
        let response = try await transport.send(upstreamRequest(request))
        guard response.body.count <= maximumBodyBytes else {
            throw CatVodError.localServer(
                reason: "上游响应 \(response.body.count) 字节超过本地代理上限 \(maximumBodyBytes) 字节：\(request.url.absoluteString)"
            )
        }
        return Response(status: response.status, headers: response.headers, body: response.body)
    }

    /// 取回一次上游响应并**落盘**（`/proxy` 的媒体路径，M06b 的流式转发）。
    ///
    /// 传输层声明了 ``HTTPDownloadingTransport`` 就让它直接写盘（`URLSession.download`，
    /// 内存里不堆整份响应）；没声明的实现退回缓冲版 —— 仍然受 ``maximumBodyBytes`` 约束，
    /// 超了照实报错（测试替身与别的传输实现走这条路）。
    public func fetchToFile(_ request: LocalProxyForwardRequest, fileURL: URL) async throws -> FileResponse {
        if let downloading = transport as? any HTTPDownloadingTransport {
            let response = try await downloading.download(upstreamRequest(request), to: fileURL)
            return FileResponse(
                status: response.status,
                headers: response.headers,
                fileURL: response.fileURL,
                byteCount: response.byteCount
            )
        }
        let response = try await fetch(request)
        try response.body.write(to: fileURL)
        return FileResponse(
            status: response.status,
            headers: response.headers,
            fileURL: fileURL,
            byteCount: response.body.count
        )
    }

    /// 「边下边发」的结果（M06p）。
    public enum StreamedOutcome: Sendable {
        /// 2xx：响应体在 `buffer` 里（边收边写）——`Response.body` 是空的，交给客户端的是 `buffer.makeBody()`。
        case streamed(Response)
        /// 非 2xx：响应体已经在内存里，照普通响应回（调用方把 buffer 丢掉）。
        case buffered(Response)
    }

    /// 取回一次上游响应：**能边下边发就边下边发**（M06p）。
    ///
    /// - 传输层声明了 ``HTTPStreamingTransport``：响应头一到就回（`.streamed`），
    ///   响应体由 `buffer` 接管（后台分块写盘，写到哪发到哪）；
    /// - 没声明：退回 ``fetchToFile(_:fileURL:)``（M06b 的落盘转发），整份到位后再当 `.streamed` 回；
    /// - 状态码不是 2xx：响应体收进内存（受 ``maximumBodyBytes`` 约束）当 `.buffered` 回 ——
    ///   错误码与错误页要原样给客户端，不该被算成「媒体文件」走文件那条。
    ///
    /// 失败语义与 ``fetch(_:)`` 一致：一律抛 ``CatVodError``（此时 `buffer` 里可能已经有半个文件，
    /// 由调用方 ``LocalProxyFileBuffer/discard()`` 掉）。
    public func fetchStreamed(
        _ request: LocalProxyForwardRequest,
        buffer: LocalProxyFileBuffer
    ) async throws -> StreamedOutcome {
        if let streaming = transport as? any HTTPStreamingTransport {
            let stream = try await streaming.stream(upstreamRequest(request))
            guard (200 ..< 300).contains(stream.status) else {
                let body = try await collect(stream, for: request)
                return .buffered(Response(status: stream.status, headers: stream.headers, body: body))
            }
            buffer.attach(stream)
            return .streamed(Response(status: stream.status, headers: stream.headers))
        }
        let file = try await fetchToFile(request, fileURL: buffer.fileURL)
        guard (200 ..< 300).contains(file.status) else {
            return .buffered(Response(
                status: file.status,
                headers: file.headers,
                body: readPrefix(of: file.fileURL, limit: maximumBodyBytes)
            ))
        }
        buffer.adoptExistingFile(byteCount: file.byteCount)
        return .streamed(Response(status: file.status, headers: file.headers))
    }

    /// 把流里的响应体收进内存（只给非 2xx 用）：超过 ``maximumBodyBytes`` 与缓冲那条同口径
    /// 明确报错，不静默截断。
    private func collect(_ stream: HTTPStream, for request: LocalProxyForwardRequest) async throws -> Data {
        var body = Data()
        do {
            for try await chunk in stream.chunks {
                body.append(chunk)
                guard body.count <= maximumBodyBytes else {
                    stream.cancel()
                    throw CatVodError.localServer(
                        reason: "上游响应超过本地代理上限 \(maximumBodyBytes) 字节：\(request.url.absoluteString)"
                    )
                }
            }
        } catch let error as CatVodError {
            throw error
        } catch {
            throw CatVodError.network(
                status: nil,
                url: request.url.absoluteString,
                reason: error.localizedDescription
            )
        }
        return body
    }

    /// 读文件前 `limit` 个字节（非 2xx 的响应体原样回给客户端；超长的只取前缀，别把错误页撑爆内存）。
    private func readPrefix(of fileURL: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return Data()
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    /// 转发请求 → 传输层请求（两条出口共用，映射规则只有一处）。
    private func upstreamRequest(_ request: LocalProxyForwardRequest) -> HTTPRequest {
        HTTPRequest(
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: request.body,
            timeout: request.timeout
        )
    }
}
