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
