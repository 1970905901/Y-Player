import Foundation

/// 统一错误模型。
///
/// 约定：所有面向 UI 的失败都必须落在这里的某个 case，便于日志聚合与用户提示；
/// 不允许把上游返回的 HTML 错误页当成成功结果（见 webhtv `docs/integration/player.md` 的接入要求）。
public enum CatVodError: Error, Sendable, Equatable {
    /// 配置文本无法解析为 JSON，或 `msg` 非空（上游把 `msg` 视为错误响应）。
    case config(reason: String)
    /// 配置中没有任何可用站点。
    case configHasNoUsableSite
    /// 网络层失败（超时、状态码非 2xx、被中断）。
    case network(status: Int?, url: String, reason: String)
    /// 站点不可用：类型不支持、Spider 缺失、初始化失败。
    case sourceUnavailable(siteKey: String, reason: String)
    /// 该能力在当前平台/构建中不可用（如 JAR/Python Spider、Widevine）。
    case unsupported(feature: String, reason: String)
    /// 解析（parse/jx）失败。
    case parseFailed(flag: String, reason: String)
    /// 播放失败。
    case playback(reason: String)
    /// 本机服务（M6 的本地 HTTP 服务/代理）不可用或转发失败。
    case localServer(reason: String)
    /// JSON 结构与协议不符。
    case decoding(path: String, reason: String)
}

extension CatVodError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .config(reason):
            "配置不可用：\(reason)"
        case .configHasNoUsableSite:
            "配置里没有可用站点"
        case let .network(status, url, reason):
            "网络失败\(status.map { "（HTTP \($0)）" } ?? "")：\(reason) @ \(url)"
        case let .sourceUnavailable(siteKey, reason):
            "站点 \(siteKey) 不可用：\(reason)"
        case let .unsupported(feature, reason):
            "当前不支持 \(feature)：\(reason)"
        case let .parseFailed(flag, reason):
            "解析失败（\(flag)）：\(reason)"
        case let .playback(reason):
            "播放失败：\(reason)"
        case let .localServer(reason):
            "本机服务不可用：\(reason)"
        case let .decoding(path, reason):
            "协议解析失败（\(path)）：\(reason)"
        }
    }
}

/// 统一日志分类（OSLog subsystem 固定为 bundle id）。
public enum CatVodLog {
    public static let subsystem = "com.YPlayer.cat"

    public enum Category: String, Sendable {
        case config
        case network
        case source
        case jsRuntime
        case parse
        case player
        case store
        case ui
    }
}
