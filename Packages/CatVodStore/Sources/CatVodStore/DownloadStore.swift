import CatVodCore
import Foundation

/// 下载任务的存储契约（M10b）。
///
/// 与 ``PlaybackProgressStore`` / ``FavoriteStore`` 同一套约定：
/// - **不 throws**（M2 定的契约）：失败返回空值 / `false`，**并且必须留痕**
///   （`GRDBDatabase.failures`）—— 仓库不允许静默失败；
/// - 实现是 actor / 数据库队列，协议本身 `Sendable`，调用方随便从哪个上下文调。
///
/// 为什么整批写单独一个方法：详情页的「整部下载」一次加十几条，逐条 `save` 会有十几次写事务，
/// 还会留下「写了一半」的中间态。
public protocol DownloadTaskStore: Sendable {
    /// 全部任务，按 `createdAt` 升序 —— 队列顺序（``DownloadQueue/nextToStart(_:limit:)``）就是它。
    func all() async -> [DownloadTask]
    /// 写一条（按 ``DownloadTask/id`` 覆盖）。
    @discardableResult
    func save(_ task: DownloadTask) async -> Bool
    /// 整批写（一个事务里完成）。
    @discardableResult
    func save(_ tasks: [DownloadTask]) async -> Bool
    /// 删一条。
    func remove(id: String) async
    /// 清空记录（不删文件；文件归下载目录的清理管）。
    func clear() async
    /// 条数（测试与诊断用）。
    func count() async -> Int
}

/// 内存实现：单测用，也是落库不可用时的降级底座（与 ``InMemoryPlaybackProgressStore`` 同理）。
public actor InMemoryDownloadTaskStore: DownloadTaskStore {
    private var storage: [String: DownloadTask] = [:]

    public init() { }

    public func all() -> [DownloadTask] {
        storage.values.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func save(_ task: DownloadTask) -> Bool {
        storage[task.id] = task
        return true
    }

    @discardableResult
    public func save(_ tasks: [DownloadTask]) -> Bool {
        for task in tasks {
            storage[task.id] = task
        }
        return true
    }

    public func remove(id: String) {
        storage[id] = nil
    }

    public func clear() {
        storage.removeAll()
    }

    public func count() -> Int {
        storage.count
    }
}
