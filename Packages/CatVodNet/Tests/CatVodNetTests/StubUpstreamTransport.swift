import CatVodCore
@testable import CatVodNet
import Foundation

/// 测试用的假上游：记录收到的请求，返回可配置的响应（或抛出统一错误）。
///
/// 为什么不用 mock 框架：`HTTPTransport` 就是一个 `Sendable` 协议，
/// 用 `actor` 实现既满足并发要求，又能让测试断言「上游到底收到了什么」。
actor StubUpstreamTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []

    private let status: Int
    private let headers: [String: String]
    private let body: Data
    private let failure: CatVodError?

    init(
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/octet-stream", "Content-Encoding": "gzip"],
        body: Data = Data("segment".utf8),
        failure: CatVodError? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.failure = failure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let failure {
            throw failure
        }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    /// 最近一次上游请求。
    func lastRequest() -> HTTPRequest? {
        requests.last
    }

    /// 收到的请求数。
    var requestCount: Int {
        requests.count
    }
}

/// 测试用的假上游（**带落盘能力**那个）：把响应体写进目标文件，模拟 `URLSession.download`。
actor StubDownloadingTransport: HTTPDownloadingTransport {
    private(set) var requests: [HTTPRequest] = []

    private let status: Int
    private let headers: [String: String]
    private let body: Data
    private let failure: CatVodError?

    init(
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "video/mp4"],
        body: Data = Data("movie".utf8),
        failure: CatVodError? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.failure = failure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let failure {
            throw failure
        }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    func download(_ request: HTTPRequest, to fileURL: URL) async throws -> HTTPDownloadedResponse {
        requests.append(request)
        if let failure {
            throw failure
        }
        try body.write(to: fileURL)
        return HTTPDownloadedResponse(status: status, headers: headers, fileURL: fileURL, byteCount: body.count)
    }

    /// 收到的请求数。
    var requestCount: Int {
        requests.count
    }
}
