import Foundation

/// 内嵌 Node 运行时配置。
///
/// 每个字段都对应 `docs/js2p宿主契约.md` 里的**逐字实测**结论，不要凭印象改：
/// - 端口：`process.env.DEV_HTTP_PORT || process.env.PORT || 9988`；
/// - 监听地址：`process.env.HOST || "0.0.0.0"`（bundle 默认对外，宿主必须注入 `127.0.0.1`）；
/// - 日志：`logger: process.env.NODE_ENV !== "development"`（即 `NODE_ENV=development` 时才安静）；
/// - 自启动：未设 `CATVOD_DISABLE_AUTOSTART=1`、未注入 `catServerFactory`、且 `argv[1]` 以 `index.js` 结尾。
public struct NodeRuntimeConfiguration: Sendable, Equatable {
    /// bundle 脚本路径。**文件名必须是 `index.js`**，否则 bundle 不会自启动（见 `satisfiesAutoStartContract`）。
    public var scriptURL: URL
    /// 期望端口，写入 `DEV_HTTP_PORT`（契约里的最高优先级）。
    public var preferredPort: Int
    /// 监听地址，写入 `HOST`。
    public var host: String
    /// 额外注入的环境变量（会覆盖上面的固定项）。
    public var environment: [String: String]
    /// 就绪等待上限（秒）。
    public var readinessTimeout: TimeInterval
    /// 是否让 bundle 的 fastify 日志安静下来（`NODE_ENV=development`）。
    public var suppressBundleLogging: Bool
    /// 指定可执行文件（默认自动定位 node；测试或自定义 libnode 时用）。
    public var executableOverride: URL?
    /// 是否注入 ``NodePreloadScript``（内嵌运行时专用；macOS 的进程方式忽略它）。
    ///
    /// 默认为真：没有它，内嵌 node 的致命错误会把宿主 App 一起带走且不留证据。
    /// 之所以留开关：预载依赖 `-r` 被 libnode 的选项解析接受，
    /// 万一某个版本不接受，可以关掉它先恢复可用性（见 M16P4 记录）。
    public var prefersPreload: Bool

    public init(
        scriptURL: URL,
        preferredPort: Int = 9988,
        host: String = "127.0.0.1",
        environment: [String: String] = [:],
        readinessTimeout: TimeInterval = 30,
        suppressBundleLogging: Bool = true,
        executableOverride: URL? = nil,
        prefersPreload: Bool = true
    ) {
        self.scriptURL = scriptURL
        self.preferredPort = preferredPort
        self.host = host
        self.environment = environment
        self.readinessTimeout = readinessTimeout
        self.suppressBundleLogging = suppressBundleLogging
        self.executableOverride = executableOverride
        self.prefersPreload = prefersPreload
    }

    /// 契约里的自启动前置条件：`argv[1]` 以 `index.js` 结尾（JS 侧为正则且忽略大小写）。
    public var satisfiesAutoStartContract: Bool {
        scriptURL.lastPathComponent.lowercased() == "index.js"
    }

    /// 组装子进程环境变量。
    ///
    /// - Parameter base: 基础环境（默认继承当前进程；测试里传入固定字典以便断言）。
    public func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = base
        result["DEV_HTTP_PORT"] = String(preferredPort)
        result["HOST"] = host
        // 注意：契约里是 `logger: process.env.NODE_ENV !== "development"`，
        // 所以「安静」对应 NODE_ENV=development。
        result["NODE_ENV"] = suppressBundleLogging ? "development" : "production"
        // 明确不设置 CATVOD_DISABLE_AUTOSTART：一旦为 "1" 就不会自启动。
        result.removeValue(forKey: "CATVOD_DISABLE_AUTOSTART")
        for (key, value) in environment {
            result[key] = value
        }
        return result
    }
}
