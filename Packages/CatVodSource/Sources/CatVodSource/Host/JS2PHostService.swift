import CatVodCore
import CatVodNet
import CatVodNode
import Foundation

/// js2p 宿主会话：把「本地 bundle」变成「可用的站点清单」。
///
/// 三步都对应实测结论（`docs/任务记录/M16P2-宿主站点清单实测.md`）：
/// 1. 本地已有 `index.js`（由 `SourceRepository` 下载并校验 MD5；**文件名必须是 `index.js`**，
///    否则 bundle 不自启动 —— 见 `NodeRuntimeConfiguration.satisfiesAutoStartContract`）；
/// 2. ``NodeRuntimeAdapter`` 起真 Node、注入 `HOST=127.0.0.1` 与 `DEV_HTTP_PORT`，
///    从 stdout 的就绪行拿到**实际**端口（端口被占用时 bundle 自己 +1 重试）；
/// 3. ``HostSiteCatalog`` 二次探活（`GET /health`）后取 `GET /full-config` 的 `video.sites`，
///    并把宿主给的**相对** `api`（`/spider/<spiderKey>/<type>`）补成全路径。
///
/// 为什么要「二次探活」：就绪行只说明 `listen` 成功。实测中 bundle 会先拉远端配置，
/// 期间服务已经在监听；`/health` 才是「应用层可用」的证据。
///
/// 平台现状（**如实说明**）：iOS 无 libnode 产物 → `start()` 抛 ``JS2PHostError/runtimeUnavailable``，
/// 界面应提示「仅 macOS 支持」而不是显示成「站点为空」。
public actor JS2PHostService {
    private let configuration: NodeRuntimeConfiguration
    private let catalog: HostSiteCatalog
    private let runtime: any NodeRuntimeLaunching
    private var startedBaseURL: URL?
    /// 当前平台/构建是否具备 Node 运行时（macOS 上取决于能否定位到 node 可执行文件）。
    nonisolated public static var isRuntimeAvailable: Bool {
        NodeRuntimeAdapter.isRuntimeAvailable
    }

    /// 运行时配置（界面展示脚本路径与期望端口用）。
    nonisolated public var runtimeConfiguration: NodeRuntimeConfiguration {
        configuration
    }

    /// - Parameters:
    ///   - transport: 用于 `GET /health` 与 `GET /full-config`。
    ///   - scriptURL: 本地 bundle 路径（文件名必须是 `index.js`）。
    ///   - runtime: 测试用替身；默认是真正的 ``NodeRuntimeAdapter``。
    public init(
        transport: HTTPTransport,
        scriptURL: URL,
        preferredPort: Int = 9988,
        readinessTimeout: TimeInterval = 30,
        runtime: (any NodeRuntimeLaunching)? = nil
    ) {
        let configuration = NodeRuntimeConfiguration(
            scriptURL: scriptURL,
            preferredPort: preferredPort,
            readinessTimeout: readinessTimeout
        )
        self.configuration = configuration
        catalog = HostSiteCatalog(transport: transport)
        self.runtime = runtime ?? NodeRuntimeAdapter(configuration: configuration)
    }

    /// 启动宿主（幂等）并返回 baseURL。
    ///
    /// - Parameter forceRestart: 先停掉再起（用户点「重启宿主」时用）。
    @discardableResult
    public func start(forceRestart: Bool = false) async throws -> URL {
        if forceRestart {
            await runtime.stop()
            startedBaseURL = nil
        }
        if let existing = startedBaseURL {
            return existing
        }

        let baseURL: URL
        do {
            baseURL = try await runtime.start()
        } catch {
            let diagnostics = await runtime.recentOutput(limit: 6)
            throw JS2PHostError.runtimeUnavailable(Self.describe(error, diagnostics: diagnostics))
        }

        guard await catalog.health(baseURL: baseURL) else {
            let diagnostics = await runtime.recentOutput(limit: 6)
            throw JS2PHostError.hostNotReady(
                "就绪行已出现（\(baseURL.absoluteString)），但 GET /health 未通过。"
                    + Self.diagnosticsSuffix(diagnostics)
            )
        }

        startedBaseURL = baseURL
        return baseURL
    }

    /// 取站点清单（必要时自动启动宿主）。
    public func sites(forceRestartHost: Bool = false) async throws -> HostConfigSnapshot {
        let baseURL = try await start(forceRestart: forceRestartHost)
        do {
            return try await catalog.config(baseURL: baseURL)
        } catch {
            let diagnostics = await runtime.recentOutput(limit: 6)
            throw JS2PHostError.sitesUnavailable(Self.describe(error, diagnostics: diagnostics))
        }
    }

    /// 已启动的 baseURL（未启动为 nil）。
    public func currentBaseURL() -> URL? {
        startedBaseURL
    }

    /// 再次探活（宿主就绪后进程可能崩掉，界面据此提示）。
    public func health() async -> Bool {
        guard let baseURL = startedBaseURL else {
            return false
        }
        return await catalog.health(baseURL: baseURL)
    }

    /// 宿主最近输出（诊断用）。
    public func recentOutput(limit: Int = 20) async -> [String] {
        await runtime.recentOutput(limit: limit)
    }

    /// 停止宿主。
    public func stop() async {
        await runtime.stop()
        startedBaseURL = nil
    }

    // MARK: - 诊断文本

    private static func describe(_ error: Error, diagnostics: [String]) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return reason + diagnosticsSuffix(diagnostics)
    }

    /// 宿主输出附在错误后面：bundle 的报错通常就在这里，不附等于让用户盲猜。
    private static func diagnosticsSuffix(_ diagnostics: [String]) -> String {
        guard !diagnostics.isEmpty else {
            return ""
        }
        return "\n宿主最近输出：\n" + diagnostics.suffix(6).joined(separator: "\n")
    }
}
