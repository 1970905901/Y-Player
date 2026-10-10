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

    /// 停掉本机服务并复位说明（幂等）。
    ///
    /// 没有服务在跑时**也**要把说明复位：关掉开关后，设置页那行不该还留着上一次的失败文案 ——
    /// 那一行是对用户的承诺（M06o）。
    func stopLocalServer() async {
        if let server = localServer {
            await server.stop()
        }
        localProxyPort = nil
        localProxyNotice = "本机服务已停止（需要 header 的 HLS 源可能播不了）。"
    }

    /// 开关（以及冷启动 / 回前台）触发的一次对账：**以开关当前值为准** —— 开 → 起、关 → 停。
    ///
    /// 为什么要排队：起停都是异步的，而 ``LocalHTTPServer`` 这个 actor 在 `await` 处会重入 ——
    /// 两路并发（连点开关、或回前台撞上点开关）会各绑一次端口，先绑的那个就此成了没人管的监听。
    /// 这里让后一次等前一次跑完，并且**每次执行时才读开关**，所以不管排队里积了几次，
    /// 最终态都跟开关一致。
    ///
    /// 调用方：`AppModel.isLocalProxyEnabled` 的 `didSet`（经 ``applyProxySwitchToServer()``）、
    /// `RootView` 的冷启动与回前台。
    internal func syncLocalServerWithSwitch() async {
        let previous = localProxyLifecycle
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.reconcileLocalServer()
        }
        localProxyLifecycle = task
        await task.value
    }

    /// `didSet` 用的同步壳子（属性观察器不能是 async）：丢一个 Task 去做对账，理由见上。
    /// 与 ``applyLogPreferenceToHost()`` 同一套做法。
    internal func applyProxySwitchToServer() {
        Task { await syncLocalServerWithSwitch() }
    }

    /// 按开关当前的值起 / 停（两个原语就是上面那对，这里只做「选哪个」）；从队列里跑。
    private func reconcileLocalServer() async {
        if isLocalProxyEnabled {
            await ensureLocalServer()
        } else {
            await stopLocalServer()
        }
    }

    /// 播放资源的总入口：**已下载就播本地文件**（M10g），否则按需改走 `/proxy`。
    ///
    /// 名字原来是 `proxiedMediaResource` —— 那时它只做「要 header 就改走 `/proxy`」这一件事；
    /// 加了本地下载接管（M10g）之后，它的职责变成「播放资源的总入口」：详情页 / 选集页 /
    /// 解析页 / 直播页 / 下载列表都经过它，所以改名成 `playbackResource`。
    ///
    /// 本地文件既不需要 header、也不需要代理：把地址换成 `file://`，并把 header 清空
    /// （留着 header 会让播放器对本地地址也发一遍带鉴权的请求）。续播位置保留。
    func playbackResource(_ resource: MediaResource) -> MediaResource {
        if let local = localDownloadedFile(forRemoteURL: resource.url) {
            var copy = resource
            copy.url = local.absoluteString
            copy.headers = [:]
            return copy
        }
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

    /// 记录当前要用的广告清理规则（M06d；本地开关 M06h；内置规则包 M06i）。
    ///
    /// 三个来源，对齐参考实现的 `HlsRuleConfig.reload()`：
    /// 1. **内置规则包**（``HLSBuiltinRules``）：默认**关**，要用得在设置里显式打开；
    /// 2. **接口配置的 `hlsRules`**：基准是规则自己写的 `"enabled": true`，本地开关可以双向覆盖；
    /// 3. **解析规则的 `exclude`（legacy 兜底）**：那才是「广告地址特征」，见 `compileLegacyRules`。
    ///    它来自接口自己的解析规则（不是广告规则包），所以**不参与开关**。
    ///
    /// 配置每次加载后调一次；**本机服务不重启** —— `/m3u8` 每个请求从 ``HLSAdRuleStore`` 现读规则。
    /// 改开关时也调它（``AppModel/setHLSAdRule(_:enabled:)``），所以开关是**立刻生效**的。
    internal func refreshAdRules() {
        let builtin = hlsBuiltinRuleEntries.filter(\.isEnabled).compactMap { try? $0.rule.compile() }
        guard let config = state.loadedSource?.config else {
            // 没加载接口时内置规则照样有效（内联/无配置也可能播本机内容）
            adRuleStore.update(builtin)
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
        adRuleStore.update(builtin + fromPackage + legacy)
    }

    /// 内置规则包的条目：生效值走**包语义**（默认关，要显式打开），源标识是 `包 id@版本`。
    var hlsBuiltinRuleEntries: [HLSAdRuleState.Entry] {
        HLSAdRuleState.packageEntries(
            HLSBuiltinRules.rules,
            origin: Self.hlsBuiltinRuleOrigin,
            sourceID: HLSBuiltinRules.sourceID,
            overrides: hlsAdRuleOverrides
        )
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

    /// 内置规则包的「来源」标记：与接口规则分开，免得同 id 的两条规则共用一把开关。
    static let hlsBuiltinRuleOrigin = "builtin"

    /// 源标识：用接口地址（`key(...)` 内部会先摘要再进键，不落明文）；
    /// 内联配置没有地址，统一用 `inline` —— 也就是说**内联配置之间共用一套开关**（内联是贴一段 JSON 试用的路，可接受）。
    var hlsAdRuleSourceID: String {
        let trimmed = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("{") ? "inline" : trimmed
    }

    /// 构造本机服务：转发侧复用与站点同一套传输层配置（默认 UA、`headers[]` 注入、`ads[]` 拦截）。
    private func makeLocalProxyServer() -> LocalHTTPServer {
        let config = state.loadedSource?.config
        let transport = config.map { URLSessionTransport(configuration: Self.transportConfiguration(for: $0)) }
            ?? URLSessionTransport()
        // 规则提供者闭包**只捕获那个 Sendable 小盒子**，不捕获 AppModel：
        // 它会在线程池里被调用，碰到主线程状态就是数据竞争。
        let store = adRuleStore
        return LocalHTTPServer(handler: LocalProxyHandler(
            upstream: LocalProxyUpstreamClient(transport: transport),
            adRules: { store.current },
            adSkip: adSkipRecorder
        ))
    }

    /// 把后台上报的清理统计落到界面提示上（主线程）。
    func applyAdSkip(_ stats: AdSkipRecorder.Stats) {
        adSkipNotice = AdSkipNotice.text(for: stats)
    }

    /// 换片 / 重新开始播放时清掉提示与累计统计（否则「上一集跳了 3 段」会跟着下一集走）。
    func resetAdSkip() {
        adSkipRecorder.reset()
        adSkipNotice = ""
    }
}
