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

/// 「大响应直接落盘」的可选能力（本机 `/proxy` 搬媒体文件用；M06b 的流式转发）。
///
/// 为什么不塞进 ``HTTPTransport``：站点 / 解析链要的是内存里的 `Data`，
/// 只有 `/proxy` 这条「可能是几十 GB 的媒体文件」的路需要落盘 ——
/// 单独一个协议 + `as?` 探测，能落盘的实现才走这条路，别的实现与测试替身不受影响。
public protocol HTTPDownloadingTransport: HTTPTransport {
    /// 把响应体写进 `fileURL`（覆盖已存在的文件），返回元信息与**实际写盘字节数**。
    ///
    /// 失败语义与 ``HTTPTransport/send(_:)`` 一致：一律抛 ``CatVodError``。
    func download(_ request: HTTPRequest, to fileURL: URL) async throws -> HTTPDownloadedResponse
}

/// 落盘取回的结果：与 ``HTTPResponse`` 同构，只是 body 换成文件。
public struct HTTPDownloadedResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var fileURL: URL
    /// 实际写盘的字节数（上游没给 Content-Length 时也能如实说）。
    public var byteCount: Int

    public init(status: Int, headers: [String: String] = [:], fileURL: URL, byteCount: Int) {
        self.status = status
        self.headers = headers
        self.fileURL = fileURL
        self.byteCount = byteCount
    }

    /// 是否 2xx。
    public var isSuccess: Bool {
        (200 ..< 300).contains(status)
    }
}

/// 「响应体分块吐出来」的可选能力（M25P2 直链下载用）。
///
/// 与 ``HTTPDownloadingTransport`` 同一套做法（单独一个协议 + `as?` 探测）：
/// 站点 / 解析链要的仍是内存里的 `Data`，只有「可能是几十 GB 的直链下载」需要分块 ——
/// 分块才能「边下边写盘 / 边报进度 / 取消时把已经写下的字节留下」（续下的地基）。
public protocol HTTPStreamingTransport: HTTPTransport {
    /// 发出请求、拿到响应头；响应体以 ``HTTPStream/chunks`` 一块块交付。
    ///
    /// 失败语义与 ``HTTPTransport/send(_:)`` 一致：一律抛 ``CatVodError``。
    func stream(_ request: HTTPRequest) async throws -> HTTPStream
}

/// 流式取回的结果：与 ``HTTPResponse`` 同构，只是 body 换成按顺序吐出的块。
public struct HTTPStream: Sendable {
    public var status: Int
    public var headers: [String: String]
    /// 响应体分块（按顺序消费）。
    public var chunks: AsyncThrowingStream<Data, Error>
    /// 中止读取：让 `chunks` 以错误收尾、底层连接随之关掉。
    /// 消费端提前停下（暂停 / 放弃剩余）时**必须**调它 —— 不调的话生产者还在往回灌。
    public var cancel: @Sendable () -> Void

    public init(
        status: Int,
        headers: [String: String] = [:],
        chunks: AsyncThrowingStream<Data, Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
        self.cancel = cancel
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
