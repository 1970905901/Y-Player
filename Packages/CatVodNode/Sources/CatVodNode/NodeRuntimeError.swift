import Foundation

/// 内嵌 Node 运行时的错误。
///
/// 原则：**每种失败都要能对用户/日志说清是什么问题**，不允许用「启动失败」一笔带过。
public enum NodeRuntimeError: Error, Equatable, LocalizedError {
    /// 当前平台/构建没有 Node 运行时（iOS 需要随包 `NodeMobile.xcframework`，见 M16P4）。
    case runtimeUnavailable(reason: String)
    /// 进程无法创建（可执行文件不可执行、参数不合法等）。
    case launchFailed(reason: String)
    /// 就绪超时；附带最近输出，便于定位（bundle 报错通常就在里面）。
    case readinessTimeout(seconds: TimeInterval, output: String)
    /// 进程在就绪前退出。
    case exitedBeforeReady(code: Int32, output: String)
    /// 配置不满足契约（例如脚本文件名不是 `index.js`，bundle 不会自启动）。
    case invalidConfiguration(reason: String)
    /// 运行时已被 `stop()` 停止，等待就绪的调用应当失败退出。
    case stopped

    public var errorDescription: String? {
        switch self {
        case let .runtimeUnavailable(reason):
            return "内嵌 Node 运行时不可用：\(reason)"
        case let .launchFailed(reason):
            return "Node 进程启动失败：\(reason)"
        case let .readinessTimeout(seconds, output):
            return "等待 Node 服务就绪超时（\(Int(seconds)) 秒）。最近输出：\n\(output)"
        case let .exitedBeforeReady(code, output):
            return "Node 进程在服务就绪前退出（exit code \(code)）。最近输出：\n\(output)"
        case let .invalidConfiguration(reason):
            return "Node 运行配置不满足契约：\(reason)"
        case .stopped:
            return "Node 运行时已停止"
        }
    }
}
