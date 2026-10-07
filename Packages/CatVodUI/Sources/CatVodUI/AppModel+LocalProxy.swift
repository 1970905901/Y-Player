import CatVodCore
import CatVodNet
import CatVodPlayer
import Foundation

// 本地代理（M6）在 AppModel 上的接线：启停本机回环服务，并把播放资源改走 `/proxy`。
//
// 为什么必须走本机服务：AVPlayer 只给**主请求**带 header，HLS 的子清单、分片、密钥请求都带不上，
// 于是统一改走 `http://127.0.0.1:<port>/proxy?url=…&h=…`，由本机补 header 再取（M06a 已落地服务端）。

public extension AppModel {
    /// 启动本机服务（幂等）。
    ///
    /// 反复调用是安全的：iOS 在应用进入后台会断开监听 socket（FlyingFox 官方说明），
    /// 回到前台需要再 start 一次，而 ``LocalHTTPServer/start()`` 已在运行时会直接返回端口。
    func ensureLocalServer() async {
        guard isLocalProxyEnabled else {
            localProxyNotice = "本地代理已关闭：需要 header 的 HLS 源可能播不了（设置 → 播放 → 本地代理）。"
            return
        }
        if let port = localProxyPort {
            localProxyNotice = "本机服务运行中：127.0.0.1:\(port)"
            return
        }
        let server = localServer ?? makeLocalProxyServer()
        localServer = server
        do {
            let port = try await server.start()
            localProxyPort = port
            localProxyNotice = "本机服务运行中：127.0.0.1:\(port)"
        } catch {
            // 失败原因用统一错误文本（含端口范围与底层原因），不静默吞掉。
            localProxyPort = nil
            localProxyNotice = userFacingMessage(error)
        }
    }

    /// 停掉本机服务并复位说明。
    func stopLocalServer() async {
        guard let server = localServer else {
            return
        }
        await server.stop()
        localProxyPort = nil
        localProxyNotice = "本机服务已停止（需要 header 的 HLS 源可能播不了）。"
    }

    /// 播放资源：需要注入 header 且本机服务在跑时改走 `/proxy`。
    ///
    /// 走代理时把 header 从资源上摘掉——header 交给本机服务统一注入，
    /// 播放器再带一份只会重复，并可能在子请求上把注入值覆盖回去。
    func proxiedMediaResource(_ resource: MediaResource) -> MediaResource {
        guard isLocalProxyEnabled, !resource.headers.isEmpty else {
            return resource
        }
        guard let port = localProxyPort else {
            return resource
        }
        guard let url = LocalProxyURLBuilder(port: port).proxyURL(for: resource.url, headers: resource.headers) else {
            return resource
        }
        var copy = resource
        copy.url = url.absoluteString
        copy.headers = [:]
        return copy
    }

    /// 构造本机服务：转发侧复用与站点同一套传输层配置（默认 UA、`headers[]` 注入、`ads[]` 拦截）。
    private func makeLocalProxyServer() -> LocalHTTPServer {
        let config = state.loadedSource?.config
        let transport = config.map { URLSessionTransport(configuration: URLSessionTransport.Configuration(config: $0)) }
            ?? URLSessionTransport()
        return LocalHTTPServer(handler: LocalProxyHandler(upstream: LocalProxyUpstreamClient(transport: transport)))
    }
}
