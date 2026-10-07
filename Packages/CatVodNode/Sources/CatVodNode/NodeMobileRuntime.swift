#if canImport(NodeMobile)
import Foundation
import NodeMobile

/// iOS 内嵌 Node 运行时（nodejs-mobile 的 `NodeMobile.xcframework`）。
///
/// 与 macOS 的进程方式**共用同一个契约**（``NodeRuntimeLaunching``）和同一套就绪解析（``NodeReadiness``）：
///
/// | 环节 | 做法 | 依据 |
/// | --- | --- | --- |
/// | 启动 | 独立后台线程（2 MB 栈）里调 `node_start(argc, argv)` | 参考实现 `NodeJSRunner.mm` |
/// | 参数 | `argv = ["node", "<script>"]`；`DEV_HTTP_PORT`/`HOST`/`NODE_ENV` 走 `setenv` | ``NodeMobileLaunchPlan`` |
/// | 就绪 | 把 fd 1/2 重定向到管道，按行解析 `CatVodSpiderios listening on …` | `docs/js2p宿主契约.md` |
///
/// 硬约束（nodejs-mobile 的既定事实，不是我们的选择）：
/// - **每进程只能起一个 Node 实例**，`node_start` 不可重入；
/// - 没有 `child_process`；iOS 无 JIT；必须跑在独立线程上。
///
/// 因此 ``stop()`` 只能**断开日志采集**：Node 实例与它监听的本地服务仍在运行，
/// 再次 ``start()`` 会返回同一个 baseURL 而不会重复启动。要真正重启只能重启 App。
/// 这条限制写进返回值与文档，而不是假装「停掉了」。
public actor NodeMobileRuntime: NodeRuntimeLaunching {
    private let configuration: NodeRuntimeConfiguration

    // 与 NodeRuntimeAdapter 同构的状态机（模块内可见，便于同文件内的扩展读写）。
    var isRunning = false
    var isReady = false
    var readyPort: Int?
    var lastExitCode: Int32?
    var output: [String] = []
    var waiters: [CheckedContinuation<URL, Error>] = []
    var timeoutTask: Task<Void, Never>?

    /// Node 是否已经在跑（`node_start` 不可逆，因此这个标记一旦为真就不再回退）。
    private(set) var nodeStarted = false
    private var pipeReadFD: Int32 = -1
    private var savedStdoutFD: Int32 = -1
    private var savedStderrFD: Int32 = -1

    public init(configuration: NodeRuntimeConfiguration) {
        self.configuration = configuration
    }

    // MARK: - 启动与停止

    public func start() async throws -> URL {
        // 已经起过：Node 不会重复打印就绪行，直接返回已知地址（见类型注释里的 stop 语义）。
        if nodeStarted, let port = readyPort, let url = NodeReadiness.baseURL(port: port) {
            isReady = true
            return url
        }
        guard configuration.satisfiesAutoStartContract else {
            throw NodeRuntimeError.invalidConfiguration(
                reason: "脚本文件名必须是 index.js（当前 \(configuration.scriptURL.lastPathComponent)），否则 bundle 不会自启动"
            )
        }
        guard !nodeStarted else {
            throw NodeRuntimeError.launchFailed(
                reason: "nodejs-mobile 每进程只允许一个 Node 实例；当前实例已启动但尚未拿到就绪行，无法再次启动"
            )
        }

        try startStdoutCapture()

        let plan = NodeMobileLaunchPlan(configuration: configuration)
        for (key, value) in plan.environment {
            setenv(key, value, 1)
        }
        nodeStarted = true
        isRunning = true
        startNodeThread(plan: plan)

        return try await waitForReadiness()
    }

    /// 断开日志采集（**不是**停掉 Node —— 见类型注释）。
    public func stop() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        restoreStdoutCapture()
        isRunning = false
        isReady = false
        // 注意：readyPort 保留 —— Node 还在跑，重新 start() 要能拿回同一个地址。
        failWaiters(with: .stopped)
    }

    // MARK: - 输出与状态

    public func recentOutput(limit: Int = 40) -> [String] {
        Array(output.suffix(max(limit, 0)))
    }
}

extension NodeMobileRuntime {
    // MARK: - stdout / stderr 采集

    /// 把 fd 1/2 重定向到管道。
    ///
    /// 为什么不靠 nodejs-mobile 的 bridge：bridge 是 cordova 插件用 JS 预载实现的，
    /// 我们只需要 bundle 打印的那一行就绪日志 —— 直接抓 fd 更少依赖、也更接近 macOS 的进程方式。
    func startStdoutCapture() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw NodeRuntimeError.launchFailed(reason: "无法创建 stdout 管道（errno \(errno)）")
        }
        savedStdoutFD = dup(STDOUT_FILENO)
        savedStderrFD = dup(STDERR_FILENO)
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        pipeReadFD = fds[0]
        startReaderThread(fd: fds[0])
    }

    func restoreStdoutCapture() {
        if savedStdoutFD >= 0 {
            dup2(savedStdoutFD, STDOUT_FILENO)
            close(savedStdoutFD)
            savedStdoutFD = -1
        }
        if savedStderrFD >= 0 {
            dup2(savedStderrFD, STDERR_FILENO)
            close(savedStderrFD)
            savedStderrFD = -1
        }
        if pipeReadFD >= 0 {
            // 关掉读端让阻塞中的 read 返回，读线程自然退出。
            close(pipeReadFD)
            pipeReadFD = -1
        }
    }

    private func startReaderThread(fd: Int32) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                guard let text = String(bytes: buffer[0 ..< count], encoding: .utf8) else {
                    continue
                }
                Task { await self?.consume(text) }
            }
        }
        thread.name = "YPlayer.NodeMobile.reader"
        thread.start()
    }

    // MARK: - Node 线程

    private func startNodeThread(plan: NodeMobileLaunchPlan) {
        let thread = Thread { [weak self] in
            let code = plan.withCArguments { argc, argv in
                node_start(argc, argv)
            }
            Task { await self?.handleNodeExit(code: code) }
        }
        // 与参考实现一致：给 Node 线程 2 MB 栈（V8 在移动端更吃栈）。
        thread.stackSize = 2 * 1024 * 1024
        thread.name = "YPlayer.NodeMobile"
        thread.start()
    }

    // MARK: - 就绪状态机（与 NodeRuntimeAdapter 同一套规则）

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
            failWaiters(with: .invalidConfiguration(reason: "就绪行端口无法构造 URL：\(port)"))
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

    func handleNodeExit(code: Int32) {
        lastExitCode = code
        isRunning = false
        guard !isReady else {
            // 就绪之后退出：保留 readyPort 供诊断（与 adapter 的行为一致）。
            return
        }
        failWaiters(
            with: .exitedBeforeReady(code: code, output: recentOutput(limit: 20).joined(separator: "\n"))
        )
    }

    func waitForReadiness() async throws -> URL {
        if !isReady, let code = lastExitCode {
            throw NodeRuntimeError.exitedBeforeReady(
                code: code,
                output: recentOutput(limit: 20).joined(separator: "\n")
            )
        }
        let timeout = configuration.readinessTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            waiters.append(continuation)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                if Task.isCancelled {
                    return
                }
                await self?.failWaitersOnTimeout(seconds: timeout)
            }
        }
    }

    func failWaitersOnTimeout(seconds: TimeInterval) {
        failWaiters(
            with: .readinessTimeout(seconds: seconds, output: recentOutput(limit: 20).joined(separator: "\n"))
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
#endif
