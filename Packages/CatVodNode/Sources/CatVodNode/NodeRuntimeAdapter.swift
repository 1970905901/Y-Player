import Foundation

/// 内嵌 Node 运行时宿主适配（M1.6 宿主侧）。
///
/// 契约（`docs/js2p宿主契约.md`，对 6.29 MB 的 `index.js` 逐字实测）：
/// - 用真 Node 执行 `<cache>/index.js`：`argv[1]` 以 `index.js` 结尾 → bundle **自启动**服务，
///   无需注入 `catServerFactory`（也不要设 `CATVOD_DISABLE_AUTOSTART=1`）；
/// - 端口：注入 `DEV_HTTP_PORT`（其次 `PORT`）；`EADDRINUSE` 时 bundle 自行 +1 重试，
///   就绪行给的是**实际**端口，宿主不需要自己试端口；
/// - 监听地址：注入 `HOST=127.0.0.1`（bundle 默认 `0.0.0.0`）；
/// - 就绪：stdout 出现 `CatVodSpiderios listening on http://127.0.0.1:<port>`。
///
/// 平台现状（**如实说明，不假装可用**）：
/// - **macOS**：随包 `node` 可执行文件 + `Process`，已实现（见 `+Start.swift`）；
/// - **iOS**：需要 nodejs-mobile 的 libnode 产物（`NodeMobile.start`），本仓库尚未包含 →
///   `start()` 抛 `.runtimeUnavailable`，UI 应提示「M1.6 未完成」。
public actor NodeRuntimeAdapter {
    /// 运行时状态快照。
    public struct Status: Sendable, Equatable {
        public var isRunning: Bool
        public var isReady: Bool
        public var port: Int?
        public var baseURL: URL?

        public init(isRunning: Bool = false, isReady: Bool = false, port: Int? = nil, baseURL: URL? = nil) {
            self.isRunning = isRunning
            self.isReady = isReady
            self.port = port
            self.baseURL = baseURL
        }
    }

    let configuration: NodeRuntimeConfiguration

    // 说明：以下状态为模块内可见（非 private），因为启动流程放在 `NodeRuntimeAdapter+Start.swift`。
    var isRunning = false
    var isReady = false
    var readyPort: Int?
    var lastExitCode: Int32?
    var output: [String] = []
    var waiters: [CheckedContinuation<URL, Error>] = []
    var timeoutTask: Task<Void, Never>?

    #if os(macOS)
    var process: Process?
    var pipe: Pipe?
    #endif

    public init(configuration: NodeRuntimeConfiguration) {
        self.configuration = configuration
    }

    // MARK: - 平台能力

    /// 当前平台/构建是否具备 Node 运行时。
    nonisolated public static var isRuntimeAvailable: Bool {
        locateNodeExecutable() != nil
    }

    /// 定位 node 可执行文件。
    ///
    /// 顺序：环境变量 `YPLAYER_NODE`（调试）→ 随包 `Resources/node/node` → Homebrew / 系统路径。
    /// iOS 返回 nil（需要 libnode，M1.6 未接入）。
    nonisolated public static func locateNodeExecutable() -> URL? {
        #if os(macOS)
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["YPLAYER_NODE"], !override.isEmpty {
            candidates.append(override)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("node/node").path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ])
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        #else
        return nil
        #endif
    }

    // MARK: - 状态与输出

    /// 状态快照。
    public func status() -> Status {
        Status(
            isRunning: isRunning,
            isReady: isReady,
            port: readyPort,
            baseURL: readyPort.flatMap { NodeReadiness.baseURL(port: $0) }
        )
    }

    /// 最近输出（诊断用；最多保留 200 行）。
    public func recentOutput(limit: Int = 40) -> [String] {
        Array(output.suffix(max(limit, 0)))
    }

    /// 停止运行时（终止子进程并清理管道与等待者）。
    public func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil

        #if os(macOS)
        process?.terminationHandler = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        pipe = nil
        #endif

        isRunning = false
        isReady = false
        readyPort = nil
        failWaiters(with: NodeRuntimeError.stopped)
    }

    // MARK: - 内部（供 +Start.swift 使用）

    func consume(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            output.append(trimmed)
            if output.count > 200 {
                output.removeFirst(output.count - 200)
            }
            if let port = NodeReadiness.port(fromLine: trimmed) {
                markReady(port: port)
            }
        }
    }

    func markReady(port: Int) {
        guard !isReady else {
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let url = NodeReadiness.baseURL(port: port) else {
            failWaiters(with: NodeRuntimeError.invalidConfiguration(reason: "就绪行端口无法构造 URL：\(port)"))
            return
        }
        isReady = true
        readyPort = port
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(returning: url)
        }
    }

    func handleTermination(code: Int32) {
        isRunning = false
        lastExitCode = code
        guard !isReady else {
            // 就绪后退出：置回未就绪，避免后续请求打到已死的端口。
            isReady = false
            readyPort = nil
            return
        }
        failWaiters(
            with: NodeRuntimeError.exitedBeforeReady(
                code: code,
                output: recentOutput(limit: 20).joined(separator: "\n")
            )
        )
    }

    func failWaitersOnTimeout(seconds: TimeInterval) {
        failWaiters(
            with: NodeRuntimeError.readinessTimeout(
                seconds: seconds,
                output: recentOutput(limit: 20).joined(separator: "\n")
            )
        )
    }

    func failWaiters(with error: NodeRuntimeError) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }
}
