import Foundation

/// js2p 宿主会话的错误。
///
/// 与 ``NodeRuntimeError``（在 `CatVodNode`）的分工：
/// - 后者管**进程/契约**层：找不到 node、就绪超时、脚本名不是 `index.js`……；
/// - 这里管**会话**层：起不来、探活不过、站点清单取不到。
///
/// 两者都实现 `LocalizedError`，界面直接把 `errorDescription` 展示出来即可，
/// 不需要自己拼提示（也就不会出现「站点为空」这种掩盖真实原因的文案）。
public enum JS2PHostError: Error, Equatable, LocalizedError, Sendable {
    /// 运行时不可用或启动失败（iOS 无 libnode、macOS 找不到 node、就绪超时等）。
    case runtimeUnavailable(String)
    /// 就绪行出现，但应用层探活（`GET /health`）未通过。
    case hostNotReady(String)
    /// 宿主可用，但站点清单取不到（上游配置未加载完、上游抖动等）。
    case sitesUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .runtimeUnavailable(reason):
            return "内嵌 Node 宿主不可用：\(reason)"
        case let .hostNotReady(reason):
            return "内嵌 Node 宿主未就绪：\(reason)"
        case let .sitesUnavailable(reason):
            return "宿主站点清单获取失败：\(reason)"
        }
    }
}
