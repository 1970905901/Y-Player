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

    /// 记录当前接口的广告清理规则（M06d；本地开关 M06h）。
    ///
    /// 两个来源，都对齐参考实现的 `HlsRuleConfig.reload()`：
    /// 1. **`hlsRules`（规则包形态）**：基准是规则自己写的 `"enabled": true`（`compileExternal` 的判法），
    ///    但**本地开关可以覆盖它**（``HLSAdRuleState/resolveInterfaceEnabled(_:key:overrides:)``）——
    ///    接口说开的可以关掉，接口没开的也能自己开；
    /// 2. **解析规则的 `exclude`（legacy 兜底）**：那才是「广告地址特征」，见 `compileLegacyRules`。
    ///    它来自接口自己的解析规则（不是广告规则包），所以**不参与开关**。
    ///
    /// 配置每次加载后调一次；**本机服务不重启** —— `/m3u8` 每个请求从 ``HLSAdRuleStore`` 现读规则。
    /// 改开关时也调它（``AppModel/toggleHLSAdRule(_:)``），所以开关是**立刻生效**的。
    internal func refreshAdRules() {
        guard let config = state.loadedSource?.config else {
            adRuleStore.update([])
            return
        }
        let entries = HLSAdRuleState.interfaceEntries(
            config.hlsRules,
            origin: Self.hlsAdRuleOrigin,
            sourceID: hlsAdRuleSourceID,
            overrides: hlsAdRuleOverrides
        )
        let fromPackage = entries.filter(\.isEnabled).compactMap { try? $0.rule.compile() }
        let legacy = config.rules.compactMap { $0.compiledAdRule() }
        adRuleStore.update(fromPackage + legacy)
    }

    /// 设置页要列的接口广告规则：规则 + 状态键 + 当前是否生效。
    var hlsAdRuleEntries: [HLSAdRuleState.Entry] {
        HLSAdRuleState.interfaceEntries(
            state.loadedSource?.config.hlsRules ?? [],
            origin: Self.hlsAdRuleOrigin,
            sourceID: hlsAdRuleSourceID,
            overrides: hlsAdRuleOverrides
        )
    }

    /// 开 / 关一条广告规则；`nil` = 清掉本地开关，回到规则自己写的默认值。
    ///
    /// 写进 `hlsAdRuleOverrides` 就会触发 `didSet` 里的 `refreshAdRules()`，所以**立刻生效**。
    func setHLSAdRule(_ key: String, enabled: Bool?) {
        hlsAdRuleOverrides = HLSAdRuleBook.recording(enabled, for: key, in: hlsAdRuleOverrides)
    }

    /// 这条规则被本地改过没有（界面据此显示「已改」与「恢复默认」）。
    func hlsAdRuleOverride(_ key: String) -> Bool? {
        hlsAdRuleOverrides[key]
    }

    /// 接口规则的「来源」标记（进状态键，见 ``HLSAdRuleState/key(origin:sourceID:ruleID:)``）。
    static let hlsAdRuleOrigin = "hlsRules"

    /// 源标识：用接口地址（`key(...)` 内部会先摘要再进键，不落明文）；
    /// 内联配置没有地址，统一用 `inline` —— 也就是说**内联配置之间共用一套开关**（内联是贴一段 JSON 试用的路，可接受）。
    var hlsAdRuleSourceID: String {
        let trimmed = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("{") ? "inline" : trimmed
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
