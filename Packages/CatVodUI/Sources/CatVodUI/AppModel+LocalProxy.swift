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
        // 端点按媒体类型选：清单走 `/m3u8`（要改写子清单/分片/密钥，见 M06c），其余走 `/proxy`。
        let builder = LocalProxyURLBuilder(port: port, path: LocalProxyURLBuilder.path(forMediaURL: resource.url))
        guard let url = builder.proxyURL(for: resource.url, headers: resource.headers) else {
            return resource
        }
        var copy = resource
        copy.url = url.absoluteString
        copy.headers = [:]
        return copy
    }

    /// 记录当前接口的广告清理规则（M06d）。
    ///
    /// 配置每次加载后调一次；**本机服务不重启** —— `/m3u8` 每个请求从 ``HLSAdRuleStore`` 现读规则。
    /// 规则来自接口配置的 `hlsRules`（`hosts` 当清单作用域、`exclude` 当分片正则，见 `HlsRule+CleanerRule.swift`）。
    internal func refreshAdRules() {
        let rules = state.loadedSource?.config.hlsRules.compactMap { $0.compiledAdRule() } ?? []
        adRuleStore.update(rules)
    }

    /// 构造本机服务：转发侧复用与站点同一套传输层配置（默认 UA、`headers[]` 注入、`ads[]` 拦截）。
    private func makeLocalProxyServer() -> LocalHTTPServer {
        let config = state.loadedSource?.config
        let transport = config.map { URLSessionTransport(configuration: URLSessionTransport.Configuration(config: $0)) }
            ?? URLSessionTransport()
        // 规则提供者闭包**只捕获那个 Sendable 小盒子**，不捕获 AppModel：
        // 它会在线程池里被调用，碰到主线程状态就是数据竞争。
        let store = adRuleStore
        return LocalHTTPServer(handler: LocalProxyHandler(
            upstream: LocalProxyUpstreamClient(transport: transport),
            adRules: { store.current }
        ))
    }
}
