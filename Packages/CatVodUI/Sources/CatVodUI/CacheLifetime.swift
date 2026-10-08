import Foundation

/// 缓存有效期（设置 → 数据 → 缓存管理里的「源缓存时间」「首页缓存时间」）。
///
/// 对应参考图上的可点值（「12小时」「7天」）：**这是真实生效的偏好**，不是说明文字 ——
/// - 源缓存时间：接口配置（JSON 文本 / js2p 的 bundle）在有效期内**直接读本地、不联网**；
/// - 首页缓存时间：首页/分类结果（``SpiderResult``）在有效期内直接读落盘缓存。
///
/// 持久化在 `UserDefaults`（键见 `AppModel.StorageKey`），与播放内核/展示方式同一套做法。
public enum CacheLifetime: String, Sendable, CaseIterable, Hashable {
    /// 12 小时（参考图里「源缓存时间」的默认值）。
    case hours12
    /// 1 天。
    case day1
    /// 3 天。
    case days3
    /// 7 天（参考图里「首页缓存时间」的默认值）。
    case days7
    /// 永不失效：只读缓存，除非用户手动「强制刷新」。
    case never

    /// 界面展示名（设置页与缓存判断共用，避免两处写不同文案）。
    public var displayName: String {
        switch self {
        case .hours12: "12小时"
        case .day1: "1天"
        case .days3: "3天"
        case .days7: "7天"
        case .never: "永不"
        }
    }

    /// 有效期秒数；`nil` 表示永不失效。
    public var timeInterval: TimeInterval? {
        switch self {
        case .hours12: 12 * 60 * 60
        case .day1: 24 * 60 * 60
        case .days3: 3 * 24 * 60 * 60
        case .days7: 7 * 24 * 60 * 60
        case .never: nil
        }
    }

    /// 给定写入时间判断是否仍然有效（`nil` 表示读不到时间：按失效处理，宁可重新拉一次）。
    public func isFresh(writtenAt date: Date?, now: Date = Date()) -> Bool {
        guard let date else {
            return false
        }
        guard let timeInterval else {
            return true
        }
        return now.timeIntervalSince(date) < timeInterval
    }
}
