import Foundation

/// 宿主运行时抽象。
///
/// 存在的唯一理由：让上层 ``JS2PHostService`` 能在单测里替换掉真正的进程启动
/// （否则「起 Node → 等就绪 → 探活」这条链路只能在真机上验证）。
///
/// 刻意只暴露上层**真正用到**的三件事，不搬运 ``NodeRuntimeAdapter/Status``：
/// 协议里出现具体类型会把测试替身也拖进实现细节。
public protocol NodeRuntimeLaunching: Sendable {
    /// 启动并等待就绪，返回 `http://127.0.0.1:<port>`（端口取自就绪行，是**实际**端口）。
    func start() async throws -> URL
    /// 停止并清理（等待就绪的调用会以 `NodeRuntimeError.stopped` 结束）。
    func stop() async
    /// 最近输出（诊断用，最多保留 200 行）。
    func recentOutput(limit: Int) async -> [String]
    /// 宿主**落盘**日志路径（进程消失后仍可读取）。没有落盘能力的实现返回 nil。
    ///
    /// 为什么进协议：内嵌 node 崩溃会带走整个进程，此时捕获在内存里的输出也一起消失，
    /// 落盘日志是唯一还能带回现场的来源（见 ``NodePreloadScript``）。
    func persistentLogPath() async -> URL?
}

public extension NodeRuntimeLaunching {
    /// 默认没有落盘日志（macOS 的进程方式由调用方自己重定向即可）。
    func persistentLogPath() async -> URL? {
        nil
    }
}

/// 真正的进程实现天然满足协议（`stop()` 虽是 actor 内同步方法，也能满足 `async` 要求）。
extension NodeRuntimeAdapter: NodeRuntimeLaunching { }
