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
/// 平台现状（**如实说明**）：iOS 走随包内嵌的 libnode（`NodeMobile.xcframework`），
/// macOS 走独立进程；两者共用同一条就绪契约。某平台既无 node 也无 libnode 时，
/// `start()` 抛 ``JS2PHostError/runtimeUnavailable``，界面应提示原因而不是显示成「站点为空」。
public actor JS2PHostService {
    private let configuration: NodeRuntimeConfiguration
    private let catalog: HostSiteCatalog
    private let runtime: any NodeRuntimeLaunching
    private var startedBaseURL: URL?
    /// 当前平台/构建是否具备 Node 运行时（macOS：能否定位 node；iOS：是否随包链接了 NodeMobile）。
    nonisolated public static var isRuntimeAvailable: Bool {
        NodeRuntimeEnvironment.isRuntimeAvailable
    }

    /// 运行时不可用的具体原因（界面直接展示，避免各处各写一套文案）。
    nonisolated public static var runtimeUnavailableReason: String {
        NodeRuntimeEnvironment.unavailableReason
    }

    /// 运行时配置（界面展示脚本路径与期望端口用）。
    nonisolated public var runtimeConfiguration: NodeRuntimeConfiguration {
        configuration
    }

    /// - Parameters:
    ///   - transport: 用于 `GET /health` 与 `GET /full-config`。
    ///   - scriptURL: 本地 bundle 路径（文件名必须是 `index.js`）。
    ///   - persistsHostOutput: 初值 —— 宿主输出是否落盘（设置 → 数据 → 日志管理 → 日志开关）；
    ///     运行中可用 ``setLogPersistence(_:)`` 再切换。
    ///   - runtime: 测试用替身；默认是真正的 ``NodeRuntimeAdapter``。
    public init(
        transport: HTTPTransport,
        scriptURL: URL,
        preferredPort: Int = 9988,
        readinessTimeout: TimeInterval = 30,
        persistsHostOutput: Bool = false,
        runtime: (any NodeRuntimeLaunching)? = nil
    ) {
        var configuration = NodeRuntimeConfiguration(
            scriptURL: scriptURL,
            preferredPort: preferredPort,
            readinessTimeout: readinessTimeout
        )
        configuration.persistsHostOutput = persistsHostOutput
        self.configuration = configuration
        catalog = HostSiteCatalog(transport: transport)
        self.runtime = runtime ?? NodeRuntimeEnvironment.makeRuntime(configuration: configuration)
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
            let diagnostics = await hostDiagnostics()
            throw JS2PHostError.runtimeUnavailable(Self.describe(error, diagnostics: diagnostics))
        }

        guard await catalog.health(baseURL: baseURL) else {
            let diagnostics = await hostDiagnostics()
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
            let diagnostics = await hostDiagnostics()
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

    /// 宿主**落盘**日志路径（无落盘能力时为 nil）。
    ///
    /// 界面可以据此提供「查看/导出宿主日志」；内嵌 node 崩溃后，这是唯一还能读到的现场。
    public func hostLogPath() async -> URL? {
        await runtime.persistentLogPath()
    }

    /// 运行时切换「宿主输出是否落盘」（设置 → 数据 → 日志管理 → 日志开关）。
    ///
    /// 宿主一旦启动就常驻（内嵌 node 每进程只能起一个实例），所以开关只能在运行中改。
    public func setLogPersistence(_ enabled: Bool) async {
        await runtime.setPersistsHostOutput(enabled)
    }

    /// 停止宿主。
    public func stop() async {
        await runtime.stop()
        startedBaseURL = nil
    }

    // MARK: - 诊断文本

    /// 诊断行：内存里的最近输出 + **落盘日志尾部**。
    ///
    /// 内嵌 node 崩溃会把进程一起带走，内存输出随之消失，落盘日志是唯一还能读到的现场
    /// （见 ``NodePreloadScript``）。两者都附上，避免「宿主未就绪」变成无线索的提示。
    public func hostDiagnostics(limit: Int = 6) async -> [String] {
        var lines = await runtime.recentOutput(limit: limit)
        if let logURL = await runtime.persistentLogPath(),
           let tail = Self.readTail(of: logURL, lines: 12)
        {
            lines.append("--- 落盘日志尾部（\(logURL.path)）---")
            lines.append(contentsOf: tail)
        }
        return lines
    }

    /// 读文件尾部若干行；不存在或为空都返回 nil（缺日志不是错误，不该改变失败原因）。
    private static func readTail(of url: URL, lines: Int) -> [String]? {
        guard lines > 0,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty
        else {
            return nil
        }
        let all = text.split(whereSeparator: \.isNewline).map(String.init)
        return Array(all.suffix(lines))
    }

    private static func describe(_ error: Error, diagnostics: [String]) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return reason + diagnosticsSuffix(diagnostics)
    }

    /// 宿主输出附在错误后面：bundle 的报错通常就在这里，不附等于让用户盲猜。
    private static func diagnosticsSuffix(_ diagnostics: [String]) -> String {
        guard !diagnostics.isEmpty else {
            return ""
        }
        // 上限 24 行：够看清「模块缺失 / 致命错误 / 进程被谁带走」，又不至于淹没界面。
        return "\n宿主最近输出：\n" + diagnostics.suffix(24).joined(separator: "\n")
    }
}
