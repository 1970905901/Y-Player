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

/// 一次性「放行闸」：生产者 `await gate.wait()` 卡住，测试 `gate.open()` 放行。
///
/// 流式测试靠它证明「**边下边发**」：上游卡在闸门里时，客户端应当已经拿到第一块 ——
/// 要是服务端还在「落完盘才发」，这一等就会等到超时（测试用 `waitUntil` 限时，不会挂死）。
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }
}

/// 测试用的假上游（**带流式能力**那个，M25P2 的直链下载 / M06p 的边下边发）：
/// 响应体按脚本一块块吐，块与块之间可以等一个 ``AsyncGate``。
final class StubStreamingTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [HTTPRequest] = []

    private let status: Int
    private let headers: [String: String]
    private let pieces: [Data]
    private let gate: AsyncGate?
    private let failure: CatVodError?

    init(
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "video/mp4"],
        pieces: [Data] = [Data("movie".utf8)],
        gate: AsyncGate? = nil,
        failure: CatVodError? = nil
    ) {
        self.status = status
        self.headers = headers
        self.pieces = pieces
        self.gate = gate
        self.failure = failure
    }

    /// 这个替身只走流式那条；缓冲那条故意不给（走到了就是接线错了）。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw CatVodError.network(status: nil, url: request.url.absoluteString, reason: "这个替身只支持流式取回")
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        lock.lock()
        received.append(request)
        lock.unlock()
        if let failure {
            throw failure
        }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pieces = pieces
        let gate = gate
        Task {
            for (index, piece) in pieces.enumerated() {
                continuation.yield(piece)
                if index == 0, let gate {
                    await gate.wait()
                }
            }
            continuation.finish()
        }
        return HTTPStream(
            status: status,
            headers: headers,
            chunks: stream,
            cancel: { continuation.finish() }
        )
    }

    /// 收到的请求数。
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return received.count
    }
}
