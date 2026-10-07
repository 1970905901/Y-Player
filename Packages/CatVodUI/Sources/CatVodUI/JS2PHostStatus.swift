import Foundation

/// js2p 宿主的状态（界面展示用；具体文案由视图层决定）。
///
/// 为什么要有它：以前 JS 源在界面上只有一句占位文案（「等内嵌 Node 服务就绪」），
/// 用户无法区分「平台不支持」「找不到 node」「宿主起来了但站点没加载出来」。
public enum JS2PHostStatus: Sendable, Equatable {
    /// 当前接口不是 JS 源，不需要宿主。
    case idle
    /// 当前平台/构建没有 Node 运行时（iOS 需要 libnode）。
    case unavailable(reason: String)
    /// 正在启动并拉取站点。
    case starting
    /// 宿主可用。
    case running(baseURL: String, siteCount: Int, disabledSiteCount: Int)
    /// 启动或取站点失败。
    case failed(reason: String)

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    public var isBusy: Bool {
        if case .starting = self {
            return true
        }
        return false
    }

    /// 一句话状态（视图可直接用；细节（诊断输出）另走 `AppModel.hostDiagnostics()`）。
    public var summary: String {
        switch self {
        case .idle:
            return "当前接口不是 JS 源，无需宿主"
        case let .unavailable(reason):
            return "宿主不可用：\(reason)"
        case .starting:
            return "正在启动宿主并拉取站点…"
        case let .running(baseURL, siteCount, disabledSiteCount):
            let disabled = disabledSiteCount > 0 ? "，另有 \(disabledSiteCount) 个被宿主禁用" : ""
            return "宿主运行中：\(baseURL)，站点 \(siteCount) 个\(disabled)"
        case let .failed(reason):
            return "宿主失败：\(reason)"
        }
    }
}
