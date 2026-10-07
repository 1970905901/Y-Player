import Foundation

/// 存储失败记录器。
///
/// 为什么需要它：``FavoriteStore`` / ``PlaybackProgressStore`` 的协议方法**不 throws**
/// （M2 定的契约，UI 不为「存储失败」到处写分支），但仓库价值观是「不许静默失败」。
/// 于是把失败原因集中记在这里：界面/诊断页可以显示「存储最近失败 N 次：…」，
/// 日志聚合也拿得到（见 `docs/任务记录/M08a-GRDB落库.md`）。
///
/// 线程安全：用 `NSLock` 而不是 actor —— 调用点在同步的数据库闭包里，
/// 不能 `await`；`@unchecked Sendable` 的成立条件是「所有可变状态都在锁内访问」。
public final class StorageFailureRecorder: @unchecked Sendable {
    /// 最多保留的失败条数（只用于诊断，不无限增长）。
    public static let capacity = 20

    private let lock = NSLock()
    private var messages: [String] = []

    public init() { }

    /// 记一条失败（超出容量时丢掉最旧的）。
    public func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
        if messages.count > Self.capacity {
            messages.removeFirst(messages.count - Self.capacity)
        }
    }

    /// 最近的失败（旧 → 新）。
    public var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    /// 最近一条失败；没有则为 nil。
    public var last: String? {
        recent.last
    }
}
