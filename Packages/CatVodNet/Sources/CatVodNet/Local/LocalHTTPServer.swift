import CatVodCore
import FlyingFox
import FlyingSocks
import Foundation

#if canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 本机回环 HTTP 服务。
///
/// 为什么需要它（对照上游 `Server.start()`：从 9978 起找第一个可用端口起 NanoHTTPD）：
/// 1. **播放**：AVPlayer/系统播放器只能给主请求设 header，HLS 的子清单、分片、密钥请求拿不到
///    `Referer`/`Cookie`，于是统一改走 `http://127.0.0.1:<port>/proxy?…`，由本机补 header 再取；
/// 2. **嗅探**（M5c）：Web 嗅探需要一个本机同源入口来抓取并改写请求。
///
/// 只监听 `127.0.0.1`：本服务会把站点 header 带出去，绝不能对局域网暴露
/// （上游为了投屏是监听全网卡的，本项目暂不需要，见 `docs/任务记录/M06a-…md`）。
public actor LocalHTTPServer {
    /// 启动配置。
    public struct Configuration: Sendable {
        /// 端口搜索范围（上游 `Server.start` 用 9978..9998）。
        public var portRange: ClosedRange<UInt16>
        /// 单请求处理超时（秒）。
        public var requestTimeout: TimeInterval
        /// 等待端口进入监听状态的最长秒数。
        public var listeningTimeout: TimeInterval

        public init(
            portRange: ClosedRange<UInt16> = 9978 ... 9998,
            requestTimeout: TimeInterval = 30,
            listeningTimeout: TimeInterval = 2
        ) {
            self.portRange = portRange
            self.requestTimeout = requestTimeout
            self.listeningTimeout = listeningTimeout
        }
    }

    /// 运行状态。
    public enum State: Sendable, Equatable {
        case stopped
        case running(port: UInt16)
    }

    private let configuration: Configuration
    private let handler: any HTTPHandler
    private var server: HTTPServer?
    private var runningTask: Task<Void, any Error>?
    private var currentState: State = .stopped

    public init(configuration: Configuration = Configuration(), handler: any HTTPHandler) {
        self.configuration = configuration
        self.handler = handler
    }

    /// 当前状态。
    public var state: State {
        currentState
    }

    /// 正在监听的端口；未运行时为 nil。
    public var port: UInt16? {
        guard case let .running(port) = currentState else {
            return nil
        }
        return port
    }

    /// 服务基地址；未运行时为 nil。
    public var baseURL: URL? {
        port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
    }

    /// 启动：从 `portRange` 里挑第一个可用端口。
    ///
    /// 已在运行则直接返回当前端口（幂等，便于 UI 反复调用）。
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port {
            return port
        }
        var lastError: (any Error)?
        for port in configuration.portRange {
            do {
                return try await start(onPort: port)
            } catch {
                lastError = error
            }
        }
        let range = "\(configuration.portRange.lowerBound)-\(configuration.portRange.upperBound)"
        throw CatVodError.localServer(
            reason: "端口 \(range) 均无法监听：\(lastError?.localizedDescription ?? "未知原因")"
        )
    }

    /// 停止服务（幂等）。
    public func stop() async {
        guard let server else {
            currentState = .stopped
            return
        }
        self.server = nil
        currentState = .stopped
        runningTask?.cancel()
        runningTask = nil
        await server.stop(timeout: 1)
    }

    /// 单端口启动。
    private func start(onPort port: UInt16) async throws -> UInt16 {
        if await isPortOccupied(port) {
            throw CatVodError.localServer(reason: "端口 \(port) 已被占用")
        }
        let address = try sockaddr_in.inet(ip4: "127.0.0.1", port: port)
        let server = HTTPServer(address: address, timeout: configuration.requestTimeout, handler: handler)
        let task = Task { try await server.run() }
        do {
            try await server.waitUntilListening(timeout: configuration.listeningTimeout)
        } catch {
            task.cancel()
            await server.stop(timeout: 0)
            throw CatVodError.localServer(reason: "端口 \(port) 启动失败：\(error.localizedDescription)")
        }
        self.server = server
        runningTask = task
        currentState = .running(port: port)
        return port
    }

    /// 端口占用探测。
    ///
    /// 为什么要先探测：FlyingFox 在 bind 失败时不会唤醒 `waitUntilListening()` 的等待者，
    /// 只能等超时；而本服务的端口搜索本来就是「扫一段端口」，先探测能把失败路径从「等 2 秒」降到「毫秒级」。
    private func isPortOccupied(_ port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 0.5
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost:
                return false
            default:
                // 连上了但协议/状态异常 —— 端口上有服务，算占用。
                return true
            }
        } catch {
            return false
        }
    }
}
