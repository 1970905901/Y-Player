import Foundation

// 启动流程：进程创建（macOS）与就绪等待。

extension NodeRuntimeAdapter {
    /// 启动并等待就绪，返回 baseURL（`http://127.0.0.1:<port>`）。
    ///
    /// 失败一律抛出带原因的 ``NodeRuntimeError``：
    /// 平台无运行时 / 配置不满足契约 / 进程创建失败 / 就绪前退出 / 就绪超时。
    public func start() async throws -> URL {
        if isReady, let port = readyPort, let url = NodeReadiness.baseURL(port: port) {
            return url
        }
        guard configuration.satisfiesAutoStartContract else {
            throw NodeRuntimeError.invalidConfiguration(
                reason: "脚本文件名必须是 index.js（当前 \(configuration.scriptURL.lastPathComponent)），否则 bundle 不会自启动"
            )
        }

        #if os(macOS)
        // 重新启动前清理上一次尝试留下的状态。
        if !isRunning {
            output.removeAll()
            lastExitCode = nil
            isReady = false
            readyPort = nil
        }

        guard let executable = configuration.executableOverride ?? Self.locateNodeExecutable() else {
            throw NodeRuntimeError.runtimeUnavailable(
                reason: "未找到 node 可执行文件（随包 Resources/node/node、环境变量 YPLAYER_NODE 或系统路径）"
            )
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [configuration.scriptURL.path]
        process.environment = configuration.processEnvironment()
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { await self?.consume(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { await self?.handleTermination(code: code) }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw NodeRuntimeError.launchFailed(reason: error.localizedDescription)
        }

        self.process = process
        self.pipe = pipe
        isRunning = true

        return try await waitForReadiness()
        #else
        throw NodeRuntimeError.runtimeUnavailable(
            reason: "iOS 需要 nodejs-mobile 的 libnode 产物（M1.6 未接入），当前只实现了 macOS 的进程路径"
        )
        #endif
    }

    /// 等待就绪行。
    ///
    /// 超时用内部定时器结束等待（不用 `TaskGroup`：取消子任务会抛出 `CancellationError` 污染调用方）。
    func waitForReadiness() async throws -> URL {
        // 进程可能在挂上等待之前就已经退出（例如启动即报错），这里先判一次，避免白等到超时。
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
}
